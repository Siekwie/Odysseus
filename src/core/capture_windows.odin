package core

import d3d11 "vendor:directx/d3d11"
import dxgi  "vendor:directx/dxgi"
import win32 "core:sys/windows"
import "core:time"

CURSOR_SHOWING :: 0x00000001

Capture_DXGI :: struct {
	device:      ^d3d11.IDevice,
	immediate:   ^d3d11.IDeviceContext,
	duplication: ^dxgi.IOutputDuplication,
	staging:     ^d3d11.ITexture2D,
	cpu:         []byte,
	width:       int,
	height:      int,
	stride:      int,
	desktop_x:   int,
	desktop_y:   int,
	draw_cursor: bool,

	cursor_visible:    bool,
	cursor_x:          int,
	cursor_y:          int,
	cursor_hx:         int,
	cursor_hy:         int,
	cursor_shape:      []byte,
	cursor_info:       dxgi.OUTDUPL_POINTER_SHAPE_INFO,
	cursor_from_dxgi:  bool,
	cursor_win32:      win32.HCURSOR,
}

capture_open_dxgi :: proc(monitor: int, draw_cursor := true) -> (cap: Capture, err: Capture_Error) {
	factory: ^dxgi.IFactory1
	if win32.FAILED(dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory))) {
		return {}, .Failed
	}
	defer factory->Release()

	adapter: ^dxgi.IAdapter
	output: ^dxgi.IOutput
	if !dxgi_find_output(factory, monitor, &adapter, &output) {
		return {}, .No_Output
	}
	defer adapter->Release()
	defer output->Release()

	od: dxgi.OUTPUT_DESC
	output->GetDesc(&od)

	device: ^d3d11.IDevice
	immediate: ^d3d11.IDeviceContext
	hr := d3d11.CreateDevice(
		adapter,
		.UNKNOWN,
		nil,
		{},
		nil,
		0,
		d3d11.SDK_VERSION,
		&device,
		nil,
		&immediate,
	)
	if win32.FAILED(hr) {
		return {}, .Failed
	}

	output1: ^dxgi.IOutput1
	if win32.FAILED(output->QueryInterface(dxgi.IOutput1_UUID, (^rawptr)(&output1))) {
		device->Release()
		immediate->Release()
		return {}, .Failed
	}
	defer output1->Release()

	duplication: ^dxgi.IOutputDuplication
	if win32.FAILED(output1->DuplicateOutput((^dxgi.IUnknown)(device), &duplication)) {
		device->Release()
		immediate->Release()
		return {}, .Failed
	}

	desc: dxgi.OUTDUPL_DESC
	duplication->GetDesc(&desc)
	w := int(desc.ModeDesc.Width)
	h := int(desc.ModeDesc.Height)
	if w <= 0 || h <= 0 {
		duplication->Release()
		device->Release()
		immediate->Release()
		return {}, .Failed
	}

	staging_desc := d3d11.TEXTURE2D_DESC{
		Width          = u32(w),
		Height         = u32(h),
		MipLevels      = 1,
		ArraySize      = 1,
		Format         = .B8G8R8A8_UNORM,
		SampleDesc     = {Count = 1, Quality = 0},
		Usage          = .STAGING,
		CPUAccessFlags = {.READ},
	}
	staging: ^d3d11.ITexture2D
	if win32.FAILED(device->CreateTexture2D(&staging_desc, nil, &staging)) {
		duplication->Release()
		device->Release()
		immediate->Release()
		return {}, .Failed
	}

	impl := new(Capture_DXGI)
	impl.device = device
	impl.immediate = immediate
	impl.duplication = duplication
	impl.staging = staging
	impl.width = w
	impl.height = h
	impl.stride = w * 4
	impl.cpu = make([]byte, impl.stride * h)
	impl.desktop_x = int(od.DesktopCoordinates.left)
	impl.desktop_y = int(od.DesktopCoordinates.top)
	impl.draw_cursor = draw_cursor

	return Capture{width = w, height = h, monitor = monitor, impl = impl}, .None
}

capture_close_dxgi :: proc(cap: ^Capture) {
	if cap.impl == nil {
		return
	}
	impl := (^Capture_DXGI)(cap.impl)
	if impl.staging != nil { impl.staging->Release() }
	if impl.duplication != nil { impl.duplication->Release() }
	if impl.immediate != nil { impl.immediate->Release() }
	if impl.device != nil { impl.device->Release() }
	delete(impl.cpu)
	delete(impl.cursor_shape)
	free(impl)
	cap.impl = nil
}

capture_frame_dxgi :: proc(cap: ^Capture, out: ^Frame) -> Capture_Error {
	if cap.impl == nil {
		return .Failed
	}
	impl := (^Capture_DXGI)(cap.impl)

	info: dxgi.OUTDUPL_FRAME_INFO
	resource: ^dxgi.IResource
	hr := impl.duplication->AcquireNextFrame(100, &info, &resource)
	if hr == dxgi.ERROR_WAIT_TIMEOUT {
		return .Timeout
	}
	if hr == dxgi.ERROR_ACCESS_LOST {
		return .Device_Lost
	}
	if win32.FAILED(hr) {
		return .Failed
	}
	defer impl.duplication->ReleaseFrame()
	defer if resource != nil { resource->Release() }

	tex: ^d3d11.ITexture2D
	if win32.FAILED(resource->QueryInterface(d3d11.ITexture2D_UUID, (^rawptr)(&tex))) {
		return .Failed
	}
	defer tex->Release()

	impl.immediate->CopyResource((^d3d11.IResource)(impl.staging), (^d3d11.IResource)(tex))

	mapped: d3d11.MAPPED_SUBRESOURCE
	if win32.FAILED(impl.immediate->Map((^d3d11.IResource)(impl.staging), 0, .READ, {}, &mapped)) {
		return .Failed
	}
	defer impl.immediate->Unmap((^d3d11.IResource)(impl.staging), 0)

	src := ([^]byte)(mapped.pData)
	pitch := int(mapped.RowPitch)
	for y in 0 ..< impl.height {
		copy(impl.cpu[y * impl.stride:][:impl.stride], src[y * pitch:][:impl.stride])
	}

	if impl.draw_cursor {
		capture_update_cursor(impl, &info)
		if impl.cursor_visible {
			capture_blit_cursor(impl)
		}
	}

	out^ = Frame{
		width        = impl.width,
		height       = impl.height,
		stride       = impl.stride,
		format       = .BGRA,
		data         = impl.cpu,
		timestamp_ns = time.to_unix_nanoseconds(time.now()),
	}
	return .None
}

@(private)
capture_update_cursor :: proc(impl: ^Capture_DXGI, info: ^dxgi.OUTDUPL_FRAME_INFO) {
	if info.PointerShapeBufferSize > 0 {
		if capture_load_dxgi_cursor(impl, info.PointerShapeBufferSize) {
			impl.cursor_from_dxgi = true
			impl.cursor_hx = int(impl.cursor_info.HotSpot.x)
			impl.cursor_hy = int(impl.cursor_info.HotSpot.y)
		}
	}

	ci: win32.CURSORINFO
	ci.cbSize = u32(size_of(ci))
	if win32.GetCursorInfo(&ci) == win32.TRUE {
		impl.cursor_visible = (ci.flags & CURSOR_SHOWING) != 0
		if !impl.cursor_from_dxgi && ci.hCursor != impl.cursor_win32 {
			if capture_load_win32_cursor(impl, ci.hCursor) {
				impl.cursor_win32 = ci.hCursor
			}
		}
		impl.cursor_x = int(ci.ptScreenPos.x) - impl.desktop_x - impl.cursor_hx
		impl.cursor_y = int(ci.ptScreenPos.y) - impl.desktop_y - impl.cursor_hy
	} else if info.LastMouseUpdateTime != 0 {
		impl.cursor_visible = i32(info.PointerPosition.Visible) != 0
		impl.cursor_x = int(info.PointerPosition.Position.x)
		impl.cursor_y = int(info.PointerPosition.Position.y)
	}
}

@(private)
capture_load_dxgi_cursor :: proc(impl: ^Capture_DXGI, size: u32) -> bool {
	if int(size) > len(impl.cursor_shape) {
		delete(impl.cursor_shape)
		impl.cursor_shape = make([]byte, size)
	}
	required: u32
	hr := impl.duplication->GetFramePointerShape(
		u32(len(impl.cursor_shape)),
		raw_data(impl.cursor_shape),
		&required,
		&impl.cursor_info,
	)
	if hr == dxgi.ERROR_MORE_DATA && required > 0 {
		delete(impl.cursor_shape)
		impl.cursor_shape = make([]byte, required)
		hr = impl.duplication->GetFramePointerShape(
			required,
			raw_data(impl.cursor_shape),
			&required,
			&impl.cursor_info,
		)
	}
	return !win32.FAILED(hr)
}

@(private)
capture_load_win32_cursor :: proc(impl: ^Capture_DXGI, hcursor: win32.HCURSOR) -> bool {
	if hcursor == {} {
		return false
	}
	ii: win32.ICONINFOEXW
	ii.cbSize = u32(size_of(ii))
	if win32.GetIconInfoExW(win32.HICON(uintptr(hcursor)), &ii) != win32.TRUE {
		return false
	}
	defer if ii.hbmMask != {} {
		win32.DeleteObject(win32.HGDIOBJ(uintptr(ii.hbmMask)))
	}
	defer if ii.hbmColor != {} {
		win32.DeleteObject(win32.HGDIOBJ(uintptr(ii.hbmColor)))
	}

	hdc := win32.CreateCompatibleDC({})
	if hdc == {} {
		return false
	}
	defer win32.DeleteDC(hdc)

	ok: bool
	if ii.hbmColor != {} {
		ok = cursor_bits_from_bitmap(impl, hdc, ii.hbmColor, .COLOR)
	} else if ii.hbmMask != {} {
		ok = cursor_bits_from_bitmap(impl, hdc, ii.hbmMask, .MONOCHROME)
	}
	if !ok {
		return false
	}
	impl.cursor_info.HotSpot = {x = i32(ii.xHotspot), y = i32(ii.yHotspot)}
	impl.cursor_hx = int(ii.xHotspot)
	impl.cursor_hy = int(ii.yHotspot)
	return true
}

@(private)
cursor_bits_from_bitmap :: proc(
	impl: ^Capture_DXGI,
	hdc: win32.HDC,
	hbm: win32.HBITMAP,
	kind: dxgi.OUTDUPL_POINTER_SHAPE_TYPE,
) -> bool {
	bm: win32.BITMAP
	if win32.GetObjectW(win32.HANDLE(uintptr(hbm)), i32(size_of(bm)), &bm) == 0 {
		return false
	}
	w := int(bm.bmWidth)
	h := int(bm.bmHeight)
	if w <= 0 || h <= 0 {
		return false
	}

	bpp: u16 = 32
	pitch := w * 4
	if kind == .MONOCHROME {
		bpp = 1
		pitch = int(bm.bmWidthBytes)
		if pitch <= 0 {
			pitch = ((w + 31) / 32) * 4
		}
	}

	needed := pitch * h
	if needed > len(impl.cursor_shape) {
		delete(impl.cursor_shape)
		impl.cursor_shape = make([]byte, needed)
	}

	bmi: win32.BITMAPINFO
	bmi.bmiHeader.biSize = size_of(win32.BITMAPINFOHEADER)
	bmi.bmiHeader.biWidth = i32(w)
	bmi.bmiHeader.biHeight = -i32(h)
	bmi.bmiHeader.biPlanes = 1
	bmi.bmiHeader.biBitCount = bpp
	bmi.bmiHeader.biCompression = win32.BI_RGB

	got := win32.GetDIBits(
		hdc,
		hbm,
		0,
		u32(h),
		raw_data(impl.cursor_shape),
		&bmi,
		win32.DIB_RGB_COLORS,
	)
	if got == 0 {
		return false
	}
	impl.cursor_info = {
		Type   = kind,
		Width  = u32(w),
		Height = u32(h),
		Pitch  = u32(pitch),
	}
	return true
}

@(private)
capture_blit_cursor :: proc(impl: ^Capture_DXGI) {
	if impl.cursor_info.Width == 0 || impl.cursor_info.Height == 0 || len(impl.cursor_shape) == 0 {
		return
	}
	switch impl.cursor_info.Type {
	case .COLOR:
		blit_cursor_color(impl, false)
	case .MASKED_COLOR:
		blit_cursor_color(impl, true)
	case .MONOCHROME:
		blit_cursor_mono(impl)
	case:
	}
}

@(private)
blit_cursor_color :: proc(impl: ^Capture_DXGI, masked: bool) {
	w := int(impl.cursor_info.Width)
	h := int(impl.cursor_info.Height)
	pitch := int(impl.cursor_info.Pitch)
	shape := impl.cursor_shape
	for y in 0 ..< h {
		dy := impl.cursor_y + y
		if dy < 0 || dy >= impl.height {
			continue
		}
		row := y * pitch
		if row + w * 4 > len(shape) {
			break
		}
		dst_row := dy * impl.stride
		for x in 0 ..< w {
			dx := impl.cursor_x + x
			if dx < 0 || dx >= impl.width {
				continue
			}
			s := row + x * 4
			b := shape[s]
			g := shape[s + 1]
			r := shape[s + 2]
			a := shape[s + 3]
			di := dst_row + dx * 4
			if masked && a == 0 {
				impl.cpu[di] ~= b
				impl.cpu[di + 1] ~= g
				impl.cpu[di + 2] ~= r
				continue
			}
			if a == 0 {
				continue
			}
			if a == 255 {
				impl.cpu[di] = b
				impl.cpu[di + 1] = g
				impl.cpu[di + 2] = r
				impl.cpu[di + 3] = 255
				continue
			}
			ia := 255 - int(a)
			impl.cpu[di] = u8((int(b) * int(a) + int(impl.cpu[di]) * ia) / 255)
			impl.cpu[di + 1] = u8((int(g) * int(a) + int(impl.cpu[di + 1]) * ia) / 255)
			impl.cpu[di + 2] = u8((int(r) * int(a) + int(impl.cpu[di + 2]) * ia) / 255)
		}
	}
}

@(private)
blit_cursor_mono :: proc(impl: ^Capture_DXGI) {
	w := int(impl.cursor_info.Width)
	full_h := int(impl.cursor_info.Height)
	h := full_h / 2
	if h <= 0 {
		return
	}
	pitch := int(impl.cursor_info.Pitch)
	shape := impl.cursor_shape
	for y in 0 ..< h {
		dy := impl.cursor_y + y
		if dy < 0 || dy >= impl.height {
			continue
		}
		and_row := y * pitch
		xor_row := (y + h) * pitch
		if xor_row + (w + 7) / 8 > len(shape) {
			break
		}
		dst_row := dy * impl.stride
		for x in 0 ..< w {
			dx := impl.cursor_x + x
			if dx < 0 || dx >= impl.width {
				continue
			}
			bit := u8(0x80) >> u8(x & 7)
			and_on := (shape[and_row + x / 8] & bit) != 0
			xor_on := (shape[xor_row + x / 8] & bit) != 0
			di := dst_row + dx * 4
			if and_on && !xor_on {
				continue
			}
			if !and_on && !xor_on {
				impl.cpu[di] = 0
				impl.cpu[di + 1] = 0
				impl.cpu[di + 2] = 0
			} else if !and_on && xor_on {
				impl.cpu[di] = 255
				impl.cpu[di + 1] = 255
				impl.cpu[di + 2] = 255
			} else {
				impl.cpu[di] ~= 255
				impl.cpu[di + 1] ~= 255
				impl.cpu[di + 2] ~= 255
			}
		}
	}
}

@(private)
dxgi_find_output :: proc(
	factory: ^dxgi.IFactory1,
	monitor: int,
	out_adapter: ^^dxgi.IAdapter,
	out_output: ^^dxgi.IOutput,
) -> bool {
	index := 0
	for a: u32 = 0;; a += 1 {
		adapter: ^dxgi.IAdapter
		if win32.FAILED(factory->EnumAdapters(a, &adapter)) {
			break
		}
		found := false
		for o: u32 = 0;; o += 1 {
			output: ^dxgi.IOutput
			if win32.FAILED(adapter->EnumOutputs(o, &output)) {
				break
			}
			if index == monitor {
				out_adapter^ = adapter
				out_output^ = output
				found = true
				break
			}
			index += 1
			output->Release()
		}
		if found {
			return true
		}
		adapter->Release()
	}
	return false
}
