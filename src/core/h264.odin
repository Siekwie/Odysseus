package core

import "core:encoding/base64"
import "core:strings"

// H.264 bitstream helpers. Encoders hand back either Annex-B (start codes) or
// AVCC (4-byte big-endian length prefixes); everything downstream of the
// encoder works on AVCC because libdatachannel's packetizer is configured for
// length-prefixed NAL units.

NAL_SLICE_IDR :: 5
NAL_SEI       :: 6
NAL_SPS       :: 7
NAL_PPS       :: 8
NAL_AUD       :: 9
NAL_FILLER    :: 12
NAL_STAP_A    :: 24

// Avcc_Iterator walks the NAL units of a length-prefixed buffer.
Avcc_Iterator :: struct {
	data:  []byte,
	pos:   int,
	valid: bool, // false once a malformed length was seen
}

avcc_iterator :: proc(data: []byte) -> Avcc_Iterator {
	return {data = data, valid = true}
}

avcc_next :: proc(it: ^Avcc_Iterator) -> (nal: []byte, ok: bool) {
	if it.pos + 4 > len(it.data) {
		return nil, false
	}
	d := it.data
	i := it.pos
	n := int(d[i]) << 24 | int(d[i + 1]) << 16 | int(d[i + 2]) << 8 | int(d[i + 3])
	i += 4
	if n <= 0 || i + n > len(d) {
		it.valid = false
		return nil, false
	}
	it.pos = i + n
	return d[i:i + n], true
}

nal_type :: proc(nal: []byte) -> u8 {
	return nal[0] & 0x1F
}

// True for NAL units that carry no picture data a WebRTC receiver needs.
@(private)
nal_is_droppable :: proc(t: u8) -> bool {
	return t == 0 || t == NAL_SEI || t == NAL_AUD || t == NAL_FILLER
}

@(private)
avcc_append :: proc(out: ^[dynamic]byte, nal: []byte) {
	n := len(nal)
	if n <= 0 {
		return
	}
	append(out, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	append(out, ..nal)
}

// Appends nal unless it is SEI / AUD / filler.
@(private)
avcc_append_filtered :: proc(out: ^[dynamic]byte, nal: []byte) {
	if len(nal) == 0 || nal_is_droppable(nal_type(nal)) {
		return
	}
	avcc_append(out, nal)
}

avcc_has_nal :: proc(data: []byte, type: u8) -> bool {
	it := avcc_iterator(data)
	for nal in avcc_next(&it) {
		if nal_type(nal) == type {
			return true
		}
	}
	return false
}

// avcc_is_valid reports whether data is a complete sequence of length-prefixed NAL units.
avcc_is_valid :: proc(data: []byte) -> bool {
	if len(data) < 5 {
		return false
	}
	it := avcc_iterator(data)
	for _ in avcc_next(&it) {}
	return it.valid && it.pos == len(data)
}

@(private)
start_code_len :: proc(data: []byte, i: int) -> int {
	if i + 4 <= len(data) && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
		return 4
	}
	if i + 3 <= len(data) && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
		return 3
	}
	return 0
}

// True when src begins with a start code, allowing the leading_zero_8bits
// that Annex B permits before it (so `00 00 00 00 01` counts).
@(private)
starts_with_annexb :: proc(src: []byte) -> bool {
	z := 0
	for z < len(src) && src[z] == 0 {
		z += 1
	}
	return z >= 2 && z < len(src) && src[z] == 1
}

@(private)
is_single_nal :: proc(src: []byte) -> bool {
	if len(src) < 1 {
		return false
	}
	t := nal_type(src)
	return t > 0 && t < NAL_STAP_A
}

// h264_to_avcc normalizes an encoder packet to AVCC, dropping SEI/AUD/filler.
// Valid AVCC is classified first: a 256..65535-byte length prefix is
// 00 00 01 xx and would otherwise be mistaken for an Annex-B start code.
// The result is owned by the caller; nil means the packet was not H.264.
h264_to_avcc :: proc(src: []byte, allocator := context.allocator) -> []byte {
	if len(src) == 0 {
		return nil
	}
	out := make([dynamic]byte, 0, len(src) + 16, allocator)
	switch {
	case avcc_is_valid(src):
		it := avcc_iterator(src)
		for nal in avcc_next(&it) {
			avcc_append_filtered(&out, nal)
		}
	case starts_with_annexb(src):
		annexb_to_avcc(&out, src)
	case is_single_nal(src):
		avcc_append_filtered(&out, src)
	}
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

@(private)
annexb_to_avcc :: proc(out: ^[dynamic]byte, src: []byte) {
	i := 0
	for i < len(src) {
		sc := start_code_len(src, i)
		if sc == 0 {
			i += 1
			continue
		}
		begin := i + sc
		end := len(src)
		for j := begin; j < len(src); j += 1 {
			if start_code_len(src, j) > 0 {
				end = j
				break
			}
		}
		// Annex B allows trailing_zero_8bits after a NAL; a NAL itself never ends in 0x00.
		nal_end := end
		for nal_end > begin && src[nal_end - 1] == 0 {
			nal_end -= 1
		}
		if begin < nal_end {
			avcc_append_filtered(out, src[begin:nal_end])
		}
		i = end
	}
}

// h264_param_sets returns the first SPS and PPS of an AVCC buffer as slices into it.
h264_param_sets :: proc(avcc: []byte) -> (sps, pps: []byte) {
	it := avcc_iterator(avcc)
	for nal in avcc_next(&it) {
		switch nal_type(nal) {
		case NAL_SPS:
			if sps == nil { sps = nal }
		case NAL_PPS:
			if pps == nil { pps = nal }
		}
	}
	return
}

// h264_extract_param_sets copies the SPS/PPS NAL units of an AVCC buffer; nil if there are none.
h264_extract_param_sets :: proc(avcc: []byte, allocator := context.allocator) -> []byte {
	out := make([dynamic]byte, allocator)
	it := avcc_iterator(avcc)
	for nal in avcc_next(&it) {
		t := nal_type(nal)
		if t == NAL_SPS || t == NAL_PPS {
			avcc_append(&out, nal)
		}
	}
	if len(out) == 0 {
		delete(out)
		return nil
	}
	return out[:]
}

// h264_prepare_for_webrtc repacks an AVCC access unit for RTP: on keyframes
// SPS and PPS are merged into one RFC 6184 STAP-A NAL ahead of the IDR
// (Chrome drops parameter sets that arrive as isolated RTP packets), and only
// slice NAL units are kept otherwise. `headers` supplies SPS/PPS when the
// keyframe itself does not repeat them. The result is owned by the caller.
h264_prepare_for_webrtc :: proc(avcc: []byte, headers: []byte, allocator := context.allocator) -> (out: []byte, is_keyframe: bool) {
	if len(avcc) == 0 {
		return nil, false
	}
	is_keyframe = avcc_has_nal(avcc, NAL_SLICE_IDR)

	buf := make([dynamic]byte, 0, len(avcc) + len(headers) + 16, allocator)
	if is_keyframe {
		sps, pps := h264_param_sets(avcc)
		if sps == nil || pps == nil {
			sps, pps = h264_param_sets(headers)
		}
		if sps != nil && pps != nil {
			n := 1 + 2 + len(sps) + 2 + len(pps)
			append(&buf, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
			append(&buf, 0x78) // F=0, NRI=3, type=24 (STAP-A)
			append(&buf, u8(len(sps) >> 8), u8(len(sps)))
			append(&buf, ..sps)
			append(&buf, u8(len(pps) >> 8), u8(len(pps)))
			append(&buf, ..pps)
		}
	}

	it := avcc_iterator(avcc)
	for nal in avcc_next(&it) {
		t := nal_type(nal)
		if t == NAL_SPS || t == NAL_PPS || nal_is_droppable(t) {
			continue
		}
		avcc_append(&buf, nal)
	}
	if len(buf) == 0 {
		delete(buf)
		return nil, false
	}
	return buf[:], is_keyframe
}

// h264_sprop_parameter_sets formats SPS/PPS for the SDP fmtp line; "" when unavailable.
h264_sprop_parameter_sets :: proc(headers: []byte, allocator := context.allocator) -> string {
	sps, pps := h264_param_sets(headers)
	if len(sps) == 0 || len(pps) == 0 {
		return ""
	}
	sps_b64, _ := base64.encode(sps, allocator = context.temp_allocator)
	pps_b64, _ := base64.encode(pps, allocator = context.temp_allocator)
	return strings.concatenate({sps_b64, ",", pps_b64}, allocator)
}

// H.264 level for a resolution and frame rate (ITU-T H.264 Table A-1, MaxFS / MaxMBPS).
H264_Level :: struct {
	name: cstring, // FFmpeg "level" option value
	idc:  u8,
}

h264_pick_level :: proc(w, h, fps: int) -> H264_Level {
	rate := fps if fps > 0 else 30
	mb := ((w + 15) / 16) * ((h + 15) / 16)
	mbps := mb * rate
	switch {
	case mb <= 3600 && mbps <= 108000:
		return {"3.1", 31}
	case mb <= 8192 && mbps <= 245760:
		return {"4.1", 41}
	case mb <= 8704 && mbps <= 522240:
		return {"4.2", 42}
	case mb <= 22080 && mbps <= 589824:
		return {"5.0", 50}
	case mb <= 36864 && mbps <= 983040:
		return {"5.1", 51}
	}
	return {"5.2", 52}
}

// Constrained-baseline profile-level-id for the WebRTC fmtp line (42e0 + level_idc).
h264_profile_level_id :: proc(w, h, fps: int) -> [6]u8 {
	HEX := "0123456789abcdef"
	idc := h264_pick_level(w, h, fps).idc
	return {'4', '2', 'e', '0', HEX[idc >> 4], HEX[idc & 0xF]}
}

// h264_fmtp builds the fmtp parameters of the SDP answer.
h264_fmtp :: proc(w, h, fps: int, headers: []byte, allocator := context.allocator) -> string {
	plid := h264_profile_level_id(w, h, fps)
	base := strings.concatenate(
		{"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=", string(plid[:])},
		context.temp_allocator,
	)
	if sprop := h264_sprop_parameter_sets(headers, context.temp_allocator); sprop != "" {
		return strings.concatenate({base, ";sprop-parameter-sets=", sprop}, allocator)
	}
	return strings.clone(base, allocator)
}
