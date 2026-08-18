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
	frame_tex:   ^d3d11.ITexture2D,
	cursor_box:  ^d3d11.ITexture2D,
	cpu:         []byte,
	width:       int,
	height:      int,
	stride:      int,
	desktop_x:   int,
	desktop_y:   int,
	draw_cursor: bool,
	gpu:         bool,

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

CURSOR_BOX_MAX :: 256

capture_open_dxgi :: proc(monitor: int, draw_cursor := true, prefer_gpu := true) -> (cap: Capture, err: Capture_Error) {
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
		{.VIDEO_SUPPORT},
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

	staging: ^d3d11.ITexture2D
	frame_tex: ^d3d11.ITexture2D
	cursor_box: ^d3d11.ITexture2D
	use_gpu := prefer_gpu

	if use_gpu {
		frame_desc := d3d11.TEXTURE2D_DESC{
			Width          = u32(w),
			Height         = u32(h),
			MipLevels      = 1,
			ArraySize      = 1,
			Format         = .B8G8R8A8_UNORM,
			SampleDesc     = {Count = 1, Quality = 0},
			Usage          = .DEFAULT,
			BindFlags      = {.SHADER_RESOURCE, .RENDER_TARGET},
		}
		if win32.FAILED(device->CreateTexture2D(&frame_desc, nil, &frame_tex)) {
			use_gpu = false
		} else {
			box_desc := frame_desc
			box_desc.Width = CURSOR_BOX_MAX
			box_desc.Height = CURSOR_BOX_MAX
			box_desc.Usage = .STAGING
			box_desc.BindFlags = {}
			box_desc.CPUAccessFlags = {.READ, .WRITE}
			if win32.FAILED(device->CreateTexture2D(&box_desc, nil, &cursor_box)) {
				frame_tex->Release()
				frame_tex = nil
				use_gpu = false
			}
		}
	}

	if !use_gpu {
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
		if win32.FAILED(device->CreateTexture2D(&staging_desc, nil, &staging)) {
			if frame_tex != nil { frame_tex->Release() }
			if cursor_box != nil { cursor_box->Release() }
			duplication->Release()
			device->Release()
			immediate->Release()
			return {}, .Failed
		}
	}

	impl := new(Capture_DXGI)
	impl.device = device
	impl.immediate = immediate
	impl.duplication = duplication
	impl.staging = staging
	impl.frame_tex = frame_tex
	impl.cursor_box = cursor_box
	impl.width = w
	impl.height = h
	impl.stride = w * 4
	if use_gpu {
		impl.gpu = true
	} else {
		impl.cpu = make([]byte, impl.stride * h)
	}
	impl.desktop_x = int(od.DesktopCoordinates.left)
	impl.desktop_y = int(od.DesktopCoordinates.top)
	impl.draw_cursor = draw_cursor

	return Capture{width = w, height = h, monitor = monitor, impl = impl, gpu = use_gpu}, .None
}

capture_close_dxgi :: proc(cap: ^Capture) {
	if cap.impl == nil {
		return
	}
	impl := (^Capture_DXGI)(cap.impl)
	if impl.staging != nil { impl.staging->Release() }
	if impl.frame_tex != nil { impl.frame_tex->Release() }
	if impl.cursor_box != nil { impl.cursor_box->Release() }
	if impl.duplication != nil { impl.duplication->Release() }
	if impl.immediate != nil { impl.immediate->Release() }
	if impl.device != nil { impl.device->Release() }
	delete(impl.cpu)
	delete(impl.cursor_shape)
	free(impl)
	cap.impl = nil
}

capture_d3d11_dxgi :: proc(cap: ^Capture) -> (device: ^d3d11.IDevice, imm: ^d3d11.IDeviceContext, ok: bool) {
	if cap.impl == nil || !cap.gpu {
		return nil, nil, false
	}
	impl := (^Capture_DXGI)(cap.impl)
	return impl.device, impl.immediate, true
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

	if impl.gpu && impl.frame_tex != nil {
		impl.immediate->CopyResource((^d3d11.IResource)(impl.frame_tex), (^d3d11.IResource)(tex))
		if impl.draw_cursor {
			capture_update_cursor(impl, &info)
			if impl.cursor_visible {
				capture_blit_cursor_gpu(impl)
			}
		}
		out^ = Frame{
			width        = impl.width,
			height       = impl.height,
			format       = .BGRA,
			timestamp_ns = time.to_unix_nanoseconds(time.now()),
			gpu          = true,
			texture      = impl.frame_tex,
		}
		return .None
	}

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
capture_blit_cursor_gpu :: proc(impl: ^Capture_DXGI) {
	if impl.cursor_info.Width == 0 || impl.cursor_info.Height == 0 || len(impl.cursor_shape) == 0 {
		return
	}
	if impl.frame_tex == nil || impl.cursor_box == nil {
		return
	}

	cw := int(impl.cursor_info.Width)
	ch := int(impl.cursor_info.Height)
	if impl.cursor_info.Type == .MONOCHROME {
		ch /= 2
	}
	x0 := max(0, impl.cursor_x)
	y0 := max(0, impl.cursor_y)
	x1 := min(impl.width, impl.cursor_x + cw)
	y1 := min(impl.height, impl.cursor_y + ch)
	bw := x1 - x0
	bh := y1 - y0
	if bw <= 0 || bh <= 0 || bw > CURSOR_BOX_MAX || bh > CURSOR_BOX_MAX {
		return
	}

	src_box := d3d11.BOX{
		left   = u32(x0),
		top    = u32(y0),
		front  = 0,
		right  = u32(x1),
		bottom = u32(y1),
		back   = 1,
	}
	impl.immediate->CopySubresourceRegion(
		(^d3d11.IResource)(impl.cursor_box),
		0, 0, 0, 0,
		(^d3d11.IResource)(impl.frame_tex),
		0,
		&src_box,
	)

	mapped: d3d11.MAPPED_SUBRESOURCE
	if win32.FAILED(impl.immediate->Map((^d3d11.IResource)(impl.cursor_box), 0, .READ_WRITE, {}, &mapped)) {
		return
	}
	box_stride := int(mapped.RowPitch)
	pixel_stride := bw * 4
	box_pixels := make([]byte, pixel_stride * bh)
	defer delete(box_pixels)
	for y in 0 ..< bh {
		src_off := y * box_stride
		dst_off := y * pixel_stride
		copy(box_pixels[dst_off:dst_off + pixel_stride], ([^]byte)(mapped.pData)[src_off:src_off + pixel_stride])
	}

	old_stride := impl.stride
	old_cpu := impl.cpu
	old_w := impl.width
	old_h := impl.height
	impl.stride = pixel_stride
	impl.cpu = box_pixels
	impl.width = bw
	impl.height = bh
	ox, oy := impl.cursor_x, impl.cursor_y
	impl.cursor_x -= x0
	impl.cursor_y -= y0
	capture_blit_cursor(impl)
	impl.cursor_x = ox
	impl.cursor_y = oy
	impl.stride = old_stride
	impl.cpu = old_cpu
	impl.width = old_w
	impl.height = old_h

	for y in 0 ..< bh {
		src_off := y * pixel_stride
		dst_off := y * box_stride
		copy(([^]byte)(mapped.pData)[dst_off:dst_off + pixel_stride], box_pixels[src_off:src_off + pixel_stride])
	}
	impl.immediate->Unmap((^d3d11.IResource)(impl.cursor_box), 0)

	cursor_box := d3d11.BOX{
		left   = 0,
		top    = 0,
		front  = 0,
		right  = u32(bw),
		bottom = u32(bh),
		back   = 1,
	}
	impl.immediate->CopySubresourceRegion(
		(^d3d11.IResource)(impl.frame_tex),
		0, u32(x0), u32(y0), 0,
		(^d3d11.IResource)(impl.cursor_box),
		0,
		&cursor_box,
	)
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
