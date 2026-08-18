package network

import "core:fmt"
import "core:strconv"
import "core:strings"
import rtc "../../vendor/libdatachannel"

// Pick an H.264 payload type from a browser offer. Prefer packetization-mode=1
// and profile-level-id=42e01f so the answer PT is the codec Chrome actually
// associated with that number (PT 96 is often VP8).
h264_select_from_offer :: proc(sdp: string) -> (pt: int, fmtp: string, ok: bool) {
	pts: [16]int
	fmtps: [16]string
	n := 0

	it := sdp
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_right(line, "\r")
		if pt_val, codec, found := parse_rtpmap(l); found {
			if n < len(pts) && is_h264_codec(codec) {
				pts[n] = pt_val
				n += 1
			}
			continue
		}
		if pt_val, params, found := parse_fmtp(l); found {
			for i in 0 ..< n {
				if pts[i] == pt_val && fmtps[i] == "" {
					fmtps[i] = params
					break
				}
			}
		}
	}
	if n == 0 {
		return 0, "", false
	}

	best := 0
	best_score := -1
	for i in 0 ..< n {
		s := h264_fmtp_score(fmtps[i])
		if s > best_score {
			best_score = s
			best = i
		}
	}
	return pts[best], fmtps[best], true
}

h264_answer_profile :: proc(offer_fmtp, encoder_profile: string) -> string {
	// Encoder fmtp carries the correct profile-level-id and cached SPS/PPS.
	if encoder_profile != "" {
		return encoder_profile
	}
	base := offer_fmtp
	if base == "" {
		base = rtc.H264_WEBRTC_PROFILE
	}
	return base
}

@(private)
parse_rtpmap :: proc(line: string) -> (pt: int, codec: string, ok: bool) {
	prefix := "a=rtpmap:"
	if !strings.has_prefix(line, prefix) {
		return
	}
	rest := line[len(prefix):]
	sp := strings.index_byte(rest, ' ')
	if sp <= 0 {
		return
	}
	pt, ok = strconv.parse_int(rest[:sp])
	if !ok {
		return 0, "", false
	}
	return pt, rest[sp + 1:], true
}

@(private)
parse_fmtp :: proc(line: string) -> (pt: int, params: string, ok: bool) {
	prefix := "a=fmtp:"
	if !strings.has_prefix(line, prefix) {
		return
	}
	rest := line[len(prefix):]
	sp := strings.index_byte(rest, ' ')
	if sp <= 0 {
		return
	}
	pt, ok = strconv.parse_int(rest[:sp])
	if !ok {
		return 0, "", false
	}
	return pt, rest[sp + 1:], true
}

@(private)
is_h264_codec :: proc(codec: string) -> bool {
	if len(codec) < 4 {
		return false
	}
	a := codec[0] | 0x20
	b := codec[1]
	c := codec[2]
	d := codec[3] | 0x20
	if a != 'h' || b != '2' || c != '6' || d != '4' {
		return false
	}
	return len(codec) == 4 || codec[4] == '/'
}

@(private)
h264_fmtp_score :: proc(fmtp: string) -> int {
	pm := fmtp_param(fmtp, "packetization-mode")
	if pm == "0" {
		return 0
	}
	score := 1
	if pm == "1" {
		score += 100
	}
	plid := fmtp_param(fmtp, "profile-level-id")
	if ascii_eq_ci(plid, "42e01f") {
		score += 50
	} else if ascii_has_prefix_ci(plid, "42e0") {
		score += 40
	} else if ascii_has_prefix_ci(plid, "42") {
		score += 20
	}
	return score
}

@(private)
fmtp_param :: proc(fmtp, key: string) -> string {
	start := 0
	for start < len(fmtp) {
		rest := fmtp[start:]
		idx := strings.index(rest, key)
		if idx < 0 {
			return ""
		}
		abs := start + idx
		if abs > 0 {
			prev := fmtp[abs - 1]
			if prev != ';' && prev != ' ' {
				start = abs + 1
				continue
			}
		}
		after := abs + len(key)
		if after >= len(fmtp) || fmtp[after] != '=' {
			start = abs + 1
			continue
		}
		after += 1
		end := after
		for end < len(fmtp) && fmtp[end] != ';' {
			end += 1
		}
		return fmtp[after:end]
	}
	return ""
}

@(private)
sprop_from_profile :: proc(profile: string) -> string {
	key := "sprop-parameter-sets="
	idx := strings.index(profile, key)
	if idx < 0 {
		return ""
	}
	rest := profile[idx + len(key):]
	end := strings.index_byte(rest, ';')
	if end < 0 {
		return rest
	}
	return rest[:end]
}

@(private)
ascii_eq_ci :: proc(s, want: string) -> bool {
	if len(s) != len(want) {
		return false
	}
	for i in 0 ..< len(s) {
		a := s[i]
		if a >= 'A' && a <= 'Z' {
			a += 32
		}
		if a != want[i] {
			return false
		}
	}
	return true
}

@(private)
ascii_has_prefix_ci :: proc(s, prefix: string) -> bool {
	if len(s) < len(prefix) {
		return false
	}
	return ascii_eq_ci(s[:len(prefix)], prefix)
}
