package core

import d3d11 "vendor:directx/d3d11"
import dxgi  "vendor:directx/dxgi"
import win32 "core:sys/windows"

import ffmpeg "../../vendor/ffmpeg"
import "../utils"

// Desktop Duplication capture. In GPU mode the desktop image stays in a D3D11
// texture (handed to NVENC without a readback); in CPU mode it is copied to a
// staging texture and read into system memory as BGRA.

CURSOR_SHOWING :: 0x00000001
CURSOR_BOX_MAX :: 256

// DXGI adapter vendor IDs (DXGI_ADAPTER_DESC.VendorId).
GPU_VENDOR_NVIDIA :: u32(0x10DE)
GPU_VENDOR_INTEL  :: u32(0x8086)
GPU_VENDOR_AMD    :: u32(0x1002)

Capture_DXGI :: struct {
	device:      ^d3d11.IDevice,
	immediate:   ^d3d11.IDeviceContext,
	vendor:      u32, // GPU the captured monitor is attached to
	duplication: ^dxgi.IOutputDuplication,
	staging:     ^d3d11.ITexture2D, // CPU mode: readback target
	frame_tex:   ^d3d11.ITexture2D, // GPU mode: desktop copy with the cursor drawn in
	cursor_box:  ^d3d11.ITexture2D, // GPU mode: small staging texture for cursor blending
	cpu:         []byte,
	bgra:        ffmpeg.Pixel_Format,
	width:       int,
	height:      int,
	stride:      int,
	desktop_x:   int,
	desktop_y:   int,
	draw_cursor: bool,
	gpu:         bool,
	have_frame:  bool,

	cursor_visible:   bool,
	cursor_x:         int,
	cursor_y:         int,
	cursor_hx:        int,
	cursor_hy:        int,
	cursor_shape:     []byte,
	cursor_info:      dxgi.OUTDUPL_POINTER_SHAPE_INFO,
	cursor_from_dxgi: bool,
	cursor_win32:     win32.HCURSOR,
}

// Pixel rectangle the cursor is blended into.
@(private)
Cursor_Target :: struct {
	pixels: [^]u8,
	stride: int,
	width:  int,
	height: int,
}

capture_open_dxgi :: proc(opts: Capture_Options) -> (cap: Capture, err: Capture_Error) {
	factory: ^dxgi.IFactory1
	if win32.FAILED(dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory))) {
		return {}, .Failed
	}
	defer factory->Release()

	adapter: ^dxgi.IAdapter
	output: ^dxgi.IOutput
	if !dxgi_find_output(factory, opts.monitor, &adapter, &output) {
		return {}, .No_Output
	}
	defer adapter->Release()
	defer output->Release()

	od: dxgi.OUTPUT_DESC
	output->GetDesc(&od)
	adapter_desc: dxgi.ADAPTER_DESC
	adapter->GetDesc(&adapter_desc)

	impl := new(Capture_DXGI)
	impl.vendor = adapter_desc.VendorId
	ok := false
	defer if !ok {
		capture_dxgi_destroy(impl)
	}

	hr := d3d11.CreateDevice(
		adapter,
		.UNKNOWN,
		nil,
		{.VIDEO_SUPPORT},
		nil,
		0,
		d3d11.SDK_VERSION,
		&impl.device,
		nil,
		&impl.immediate,
	)
	if win32.FAILED(hr) {
		return {}, .Failed
	}

	output1: ^dxgi.IOutput1
	if win32.FAILED(output->QueryInterface(dxgi.IOutput1_UUID, (^rawptr)(&output1))) {
		return {}, .Not_Supported
	}
	defer output1->Release()

	hr = output1->DuplicateOutput((^dxgi.IUnknown)(impl.device), &impl.duplication)
	if win32.FAILED(hr) {
		// E_ACCESSDENIED while the secure desktop (UAC, lock screen) is up, and
		// NOT_CURRENTLY_AVAILABLE when too many duplications exist: both clear up later.
		if hr == dxgi.ERROR_UNSUPPORTED || hr == dxgi.ERROR_SESSION_DISCONNECTED {
			return {}, .Not_Supported
		}
		return {}, .Device_Lost
	}

	desc: dxgi.OUTDUPL_DESC
	impl.duplication->GetDesc(&desc)
	if desc.Rotation != .IDENTITY && desc.Rotation != .UNSPECIFIED {
		// The duplicated surface is unrotated; let GDI deliver the desktop as displayed.
		utils.log_info("monitor %d is rotated; Desktop Duplication skipped", opts.monitor)
		return {}, .Not_Supported
	}
	w := int(desc.ModeDesc.Width)
	h := int(desc.ModeDesc.Height)
	if w <= 0 || h <= 0 {
		return {}, .Failed
	}

	use_gpu := opts.prefer_gpu
	if use_gpu {
		frame_desc := d3d11.TEXTURE2D_DESC{
			Width      = u32(w),
			Height     = u32(h),
			MipLevels  = 1,
			ArraySize  = 1,
			Format     = .B8G8R8A8_UNORM,
			SampleDesc = {Count = 1, Quality = 0},
			Usage      = .DEFAULT,
			BindFlags  = {.SHADER_RESOURCE, .RENDER_TARGET},
		}
		box_desc := frame_desc
		box_desc.Width = CURSOR_BOX_MAX
		box_desc.Height = CURSOR_BOX_MAX
		box_desc.Usage = .STAGING
		box_desc.BindFlags = {}
		box_desc.CPUAccessFlags = {.READ, .WRITE}
		if win32.FAILED(impl.device->CreateTexture2D(&frame_desc, nil, &impl.frame_tex)) ||
		   win32.FAILED(impl.device->CreateTexture2D(&box_desc, nil, &impl.cursor_box)) {
			use_gpu = false
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
		if win32.FAILED(impl.device->CreateTexture2D(&staging_desc, nil, &impl.staging)) {
			return {}, .Failed
		}
		impl.cpu = make([]byte, w * 4 * h)
	}

	impl.width = w
	impl.height = h
	impl.stride = w * 4
	impl.gpu = use_gpu
	impl.bgra = ffmpeg.pix_fmt("bgra")
	impl.desktop_x = int(od.DesktopCoordinates.left)
	impl.desktop_y = int(od.DesktopCoordinates.top)
	impl.draw_cursor = opts.cursor

	ok = true
	return Capture{
		width      = w,
		height     = h,
		gpu        = use_gpu,
		impl       = impl,
		frame_proc = capture_frame_dxgi,
		close_proc = capture_close_dxgi,
	}, .None
}

@(private)
capture_dxgi_destroy :: proc(impl: ^Capture_DXGI) {
	if impl.staging != nil { impl.staging->Release() }
	if impl.frame_tex != nil { impl.frame_tex->Release() }
	if impl.cursor_box != nil { impl.cursor_box->Release() }
	if impl.duplication != nil { impl.duplication->Release() }
	if impl.immediate != nil { impl.immediate->Release() }
	if impl.device != nil { impl.device->Release() }
	delete(impl.cpu)
	delete(impl.cursor_shape)
	free(impl)
}

@(private)
capture_close_dxgi :: proc(cap: ^Capture) {
	capture_dxgi_destroy((^Capture_DXGI)(cap.impl))
	cap.impl = nil
}

// capture_adapter_vendor returns the vendor of the GPU driving the captured
// monitor (GPU_VENDOR_*), 0 when unknown. On hybrid-graphics laptops this is
// usually the integrated GPU even when a discrete one is present.
capture_adapter_vendor :: proc(cap: ^Capture) -> u32 {
	if cap.impl == nil || cap.backend != .DXGI {
		return 0
	}
	return (^Capture_DXGI)(cap.impl).vendor
}

// capture_d3d11 exposes the capture's D3D11 device so an encoder can share it.
capture_d3d11 :: proc(cap: ^Capture) -> (device: ^d3d11.IDevice, imm: ^d3d11.IDeviceContext, ok: bool) {
	if cap.impl == nil || cap.backend != .DXGI || !cap.gpu {
		return nil, nil, false
	}
	impl := (^Capture_DXGI)(cap.impl)
	return impl.device, impl.immediate, true
}

@(private)
capture_frame_dxgi :: proc(cap: ^Capture, out: ^Frame) -> Capture_Error {
	impl := (^Capture_DXGI)(cap.impl)

	info: dxgi.OUTDUPL_FRAME_INFO
	resource: ^dxgi.IResource
	hr := impl.duplication->AcquireNextFrame(100, &info, &resource)
	if hr == dxgi.ERROR_WAIT_TIMEOUT {
		if impl.have_frame {
			capture_dxgi_fill(impl, out)
		}
		return .Timeout
	}
	if hr == dxgi.ERROR_ACCESS_LOST || hr == dxgi.ERROR_DEVICE_REMOVED || hr == dxgi.ERROR_INVALID_CALL {
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

	if impl.draw_cursor {
		capture_update_cursor(impl, &info)
	}

	if impl.gpu {
		impl.immediate->CopyResource((^d3d11.IResource)(impl.frame_tex), (^d3d11.IResource)(tex))
		if impl.draw_cursor && impl.cursor_visible {
			capture_blit_cursor_gpu(impl)
		}
	} else {
		impl.immediate->CopyResource((^d3d11.IResource)(impl.staging), (^d3d11.IResource)(tex))

		mapped: d3d11.MAPPED_SUBRESOURCE
		if win32.FAILED(impl.immediate->Map((^d3d11.IResource)(impl.staging), 0, .READ, {}, &mapped)) {
			return .Failed
		}
		src := ([^]byte)(mapped.pData)
		pitch := int(mapped.RowPitch)
		for y in 0 ..< impl.height {
			copy(impl.cpu[y * impl.stride:][:impl.stride], src[y * pitch:][:impl.stride])
		}
		impl.immediate->Unmap((^d3d11.IResource)(impl.staging), 0)

		if impl.draw_cursor && impl.cursor_visible {
			capture_blit_cursor(impl, {raw_data(impl.cpu), impl.stride, impl.width, impl.height}, impl.cursor_x, impl.cursor_y)
		}
	}

	impl.have_frame = true
	capture_dxgi_fill(impl, out)
	return .None
}

@(private)
capture_dxgi_fill :: proc(impl: ^Capture_DXGI, out: ^Frame) {
	out^ = Frame{
		width        = impl.width,
		height       = impl.height,
		format       = impl.bgra,
		timestamp_ns = now_ns(),
	}
	if impl.gpu {
		out.texture = impl.frame_tex
	} else {
		out.planes[0] = raw_data(impl.cpu)
		out.strides[0] = i32(impl.stride)
	}
}

// Reads the pixels under the cursor back from the GPU frame, blends the
// cursor in on the CPU and writes that small box back.
@(private)
capture_blit_cursor_gpu :: proc(impl: ^Capture_DXGI) {
	if impl.cursor_info.Width == 0 || impl.cursor_info.Height == 0 || len(impl.cursor_shape) == 0 {
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
	target := Cursor_Target{([^]u8)(mapped.pData), int(mapped.RowPitch), bw, bh}
	capture_blit_cursor(impl, target, impl.cursor_x - x0, impl.cursor_y - y0)
	impl.immediate->Unmap((^d3d11.IResource)(impl.cursor_box), 0)

	dst_box := d3d11.BOX{
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
		&dst_box,
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

// Blends the cached cursor shape into target with its top-left corner at (cx, cy).
@(private)
capture_blit_cursor :: proc(impl: ^Capture_DXGI, target: Cursor_Target, cx, cy: int) {
	if impl.cursor_info.Width == 0 || impl.cursor_info.Height == 0 || len(impl.cursor_shape) == 0 {
		return
	}
	switch impl.cursor_info.Type {
	case .COLOR:
		blit_cursor_color(impl, target, cx, cy, false)
	case .MASKED_COLOR:
		blit_cursor_color(impl, target, cx, cy, true)
	case .MONOCHROME:
		blit_cursor_mono(impl, target, cx, cy)
	case:
	}
}

@(private)
blit_cursor_color :: proc(impl: ^Capture_DXGI, target: Cursor_Target, cx, cy: int, masked: bool) {
	w := int(impl.cursor_info.Width)
	h := int(impl.cursor_info.Height)
	pitch := int(impl.cursor_info.Pitch)
	shape := impl.cursor_shape
	px := target.pixels
	for y in 0 ..< h {
		dy := cy + y
		if dy < 0 || dy >= target.height {
			continue
		}
		row := y * pitch
		if row + w * 4 > len(shape) {
			break
		}
		dst_row := dy * target.stride
		for x in 0 ..< w {
			dx := cx + x
			if dx < 0 || dx >= target.width {
				continue
			}
			s := row + x * 4
			b := shape[s]
			g := shape[s + 1]
			r := shape[s + 2]
			a := shape[s + 3]
			di := dst_row + dx * 4
			if masked {
				// Masked color: alpha 0 replaces the pixel, alpha 0xFF XORs it.
				if a == 0 {
					px[di] = b
					px[di + 1] = g
					px[di + 2] = r
				} else {
					px[di] ~= b
					px[di + 1] ~= g
					px[di + 2] ~= r
				}
				continue
			}
			if a == 0 {
				continue
			}
			if a == 255 {
				px[di] = b
				px[di + 1] = g
				px[di + 2] = r
				px[di + 3] = 255
				continue
			}
			ia := 255 - int(a)
			px[di] = u8((int(b) * int(a) + int(px[di]) * ia) / 255)
			px[di + 1] = u8((int(g) * int(a) + int(px[di + 1]) * ia) / 255)
			px[di + 2] = u8((int(r) * int(a) + int(px[di + 2]) * ia) / 255)
		}
	}
}

@(private)
blit_cursor_mono :: proc(impl: ^Capture_DXGI, target: Cursor_Target, cx, cy: int) {
	w := int(impl.cursor_info.Width)
	h := int(impl.cursor_info.Height) / 2
	if h <= 0 {
		return
	}
	pitch := int(impl.cursor_info.Pitch)
	shape := impl.cursor_shape
	px := target.pixels
	for y in 0 ..< h {
		dy := cy + y
		if dy < 0 || dy >= target.height {
			continue
		}
		and_row := y * pitch
		xor_row := (y + h) * pitch
		if xor_row + (w + 7) / 8 > len(shape) {
			break
		}
		dst_row := dy * target.stride
		for x in 0 ..< w {
			dx := cx + x
			if dx < 0 || dx >= target.width {
				continue
			}
			bit := u8(0x80) >> u8(x & 7)
			and_on := (shape[and_row + x / 8] & bit) != 0
			xor_on := (shape[xor_row + x / 8] & bit) != 0
			di := dst_row + dx * 4
			switch {
			case and_on && !xor_on:
				// transparent
			case !and_on && !xor_on:
				px[di] = 0
				px[di + 1] = 0
				px[di + 2] = 0
			case !and_on && xor_on:
				px[di] = 255
				px[di + 1] = 255
				px[di + 2] = 255
			case:
				px[di] ~= 255
				px[di + 1] ~= 255
				px[di + 2] ~= 255
			}
		}
	}
}

// Visits every desktop output in DXGI order (adapter by adapter). The visitor
// returns false to stop; it must AddRef whatever it keeps.
@(private)
dxgi_each_output :: proc(
	factory: ^dxgi.IFactory1,
	user: rawptr,
	visit: proc(user: rawptr, index: int, adapter: ^dxgi.IAdapter, output: ^dxgi.IOutput) -> bool,
) {
	index := 0
	for a: u32 = 0;; a += 1 {
		adapter: ^dxgi.IAdapter
		if win32.FAILED(factory->EnumAdapters(a, &adapter)) {
			break
		}
		defer adapter->Release()
		for o: u32 = 0;; o += 1 {
			output: ^dxgi.IOutput
			if win32.FAILED(adapter->EnumOutputs(o, &output)) {
				break
			}
			keep_going := visit(user, index, adapter, output)
			output->Release()
			if !keep_going {
				return
			}
			index += 1
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
	Search :: struct {
		monitor: int,
		adapter: ^dxgi.IAdapter,
		output:  ^dxgi.IOutput,
	}
	search := Search{monitor = monitor}
	dxgi_each_output(factory, &search, proc(user: rawptr, index: int, adapter: ^dxgi.IAdapter, output: ^dxgi.IOutput) -> bool {
		s := (^Search)(user)
		if index != s.monitor {
			return true
		}
		adapter->AddRef()
		output->AddRef()
		s.adapter = adapter
		s.output = output
		return false
	})
	if search.output == nil {
		return false
	}
	out_adapter^ = search.adapter
	out_output^ = search.output
	return true
}

// Monitors in the same order capture_open_dxgi indexes them.
@(private)
list_monitors_dxgi :: proc() -> []Monitor_Info {
	factory: ^dxgi.IFactory1
	if win32.FAILED(dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, (^rawptr)(&factory))) {
		return nil
	}
	defer factory->Release()

	list := make([dynamic]Monitor_Info)
	dxgi_each_output(factory, &list, proc(user: rawptr, index: int, adapter: ^dxgi.IAdapter, output: ^dxgi.IOutput) -> bool {
		list := (^[dynamic]Monitor_Info)(user)
		od: dxgi.OUTPUT_DESC
		output->GetDesc(&od)
		r := od.DesktopCoordinates
		name, _ := win32.wstring_to_utf8(cstring16(raw_data(od.DeviceName[:])), -1, context.allocator)
		append(list, Monitor_Info{
			index   = index,
			name    = name,
			x       = int(r.left),
			y       = int(r.top),
			width   = int(r.right - r.left),
			height  = int(r.bottom - r.top),
			primary = r.left == 0 && r.top == 0,
		})
		return true
	})
	return list[:]
}
