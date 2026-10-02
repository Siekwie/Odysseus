package network

import "core:strconv"
import "core:strings"

// Just enough SDP parsing to answer a browser offer: which m-lines exist,
// their mids, and which payload types the browser bound to H.264 and Opus.

Offer_Media :: struct {
	found: bool,
	mid:   string,
	pt:    int,
	fmtp:  string,
}

Offer_Info :: struct {
	video: Offer_Media, // best H.264 payload of the first video m-line
	audio: Offer_Media, // Opus payload of the first audio m-line
}

@(private)
MAX_H264_PAYLOADS :: 64 // browsers offer around ten; payload types are 7 bits

// parse_offer extracts the media Odysseus can answer. The returned strings are slices of sdp.
//
// For video it prefers packetization-mode=1 and profile-level-id=42e01f so the
// answer uses the payload type the browser actually associated with
// constrained-baseline H.264 (PT 96 is usually VP8).
parse_offer :: proc(sdp: string) -> (info: Offer_Info) {
	Section :: enum { Other, Video, Audio }
	h264_pts: [MAX_H264_PAYLOADS]int
	h264_fmtps: [MAX_H264_PAYLOADS]string
	h264_count := 0
	opus_pt := -1

	// Two passes: attribute order within a media section is not significant
	// and Firefox emits a=fmtp before a=rtpmap. Pass 0 collects the payload
	// types (rtpmap) and mids, pass 1 attaches the fmtp lines to them.
	for pass in 0 ..< 2 {
		section := Section.Other
		video_seen, audio_seen := false, false
		it := sdp
		for raw in strings.split_lines_iterator(&it) {
			line := strings.trim_right(raw, "\r")
			switch {
			case strings.has_prefix(line, "m=video"):
				section = .Other if video_seen else .Video
				video_seen = true
			case strings.has_prefix(line, "m=audio"):
				section = .Other if audio_seen else .Audio
				audio_seen = true
			case strings.has_prefix(line, "m="):
				section = .Other
			case strings.has_prefix(line, "a=mid:"):
				if pass != 0 {
					continue
				}
				mid := line[len("a=mid:"):]
				#partial switch section {
				case .Video: info.video.mid = mid
				case .Audio: info.audio.mid = mid
				}
			case strings.has_prefix(line, "a=rtpmap:"):
				if pass != 0 {
					continue
				}
				pt, codec, ok := parse_pt_attribute(line, "a=rtpmap:")
				if !ok {
					continue
				}
				#partial switch section {
				case .Video:
					if h264_count < MAX_H264_PAYLOADS && codec_is(codec, "h264") {
						h264_pts[h264_count] = pt
						h264_count += 1
					}
				case .Audio:
					if opus_pt < 0 && codec_is(codec, "opus") {
						opus_pt = pt
					}
				}
			case strings.has_prefix(line, "a=fmtp:"):
				if pass != 1 {
					continue
				}
				pt, params, ok := parse_pt_attribute(line, "a=fmtp:")
				if !ok {
					continue
				}
				#partial switch section {
				case .Video:
					for i in 0 ..< h264_count {
						if h264_pts[i] == pt && h264_fmtps[i] == "" {
							h264_fmtps[i] = params
							break
						}
					}
				case .Audio:
					if pt == opus_pt {
						info.audio.fmtp = params
					}
				}
			}
		}
	}

	if h264_count > 0 {
		best, best_score := 0, 0
		for i in 0 ..< h264_count {
			if score := h264_fmtp_score(h264_fmtps[i]); score > best_score {
				best, best_score = i, score
			}
		}
		// Only packetization-mode 1 is usable: the stream is sent as STAP-A / FU-A,
		// which a mode-0 receiver cannot depacketize.
		if best_score > 0 {
			info.video.found = true
			info.video.pt = h264_pts[best]
			info.video.fmtp = h264_fmtps[best]
			if info.video.mid == "" {
				info.video.mid = "0"
			}
		}
	}
	if opus_pt >= 0 {
		info.audio.found = true
		info.audio.pt = opus_pt
		if info.audio.mid == "" {
			info.audio.mid = "1"
		}
	}
	return
}

// Parses "<prefix><pt> <rest>".
@(private)
parse_pt_attribute :: proc(line, prefix: string) -> (pt: int, rest: string, ok: bool) {
	body := line[len(prefix):]
	sp := strings.index_byte(body, ' ')
	if sp <= 0 {
		return
	}
	pt, ok = strconv.parse_int(body[:sp], 10)
	if !ok {
		return 0, "", false
	}
	return pt, body[sp + 1:], true
}

// True when an rtpmap encoding ("H264/90000", "opus/48000/2") names the codec.
@(private)
codec_is :: proc(encoding, name: string) -> bool {
	if len(encoding) < len(name) || !ascii_eq_ci(encoding[:len(name)], name) {
		return false
	}
	return len(encoding) == len(name) || encoding[len(name)] == '/'
}

@(private)
h264_fmtp_score :: proc(fmtp: string) -> int {
	// 0 means unusable. An explicit mode 0 cannot take STAP-A / FU-A. A payload
	// that does not say (RFC 6184 default: mode 0) is kept as a last resort,
	// since some clients simply omit the parameter.
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

// fmtp_param returns the value of key in a "k=v;k=v" parameter list, "" if absent.
fmtp_param :: proc(fmtp, key: string) -> string {
	rest := fmtp
	for item in strings.split_iterator(&rest, ";") {
		kv := strings.trim_space(item)
		eq := strings.index_byte(kv, '=')
		if eq > 0 && kv[:eq] == key {
			return kv[eq + 1:]
		}
	}
	return ""
}

// Compares s with a lower-case ASCII string, ignoring the case of s.
@(private)
ascii_eq_ci :: proc(s, lower: string) -> bool {
	if len(s) != len(lower) {
		return false
	}
	for i in 0 ..< len(s) {
		a := s[i]
		if a >= 'A' && a <= 'Z' {
			a += 32
		}
		if a != lower[i] {
			return false
		}
	}
	return true
}

@(private)
ascii_has_prefix_ci :: proc(s, lower_prefix: string) -> bool {
	return len(s) >= len(lower_prefix) && ascii_eq_ci(s[:len(lower_prefix)], lower_prefix)
}
