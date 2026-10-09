#+build !windows
package core

// GPU-fed encoding exists on Windows (D3D11) only; elsewhere frames always go through the CPU path.
encoder_open_zero_copy :: proc(requested: string, cap: ^Capture, opts: Encoder_Options, skip: []string = nil) -> (enc: ^Encoder, err: Encoder_Error) {
	return nil, .Codec_Not_Found
}
