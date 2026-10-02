package network

import "core:fmt"
import "core:strings"
import "core:testing"

// Everything below only exists in `odin test` builds: the package directory is
// also built by a plain `odin build`, which must not compile (or break on) tests.
when ODIN_TEST {

// Unit tests for the SDP offer parser. Offers are written with plain "\n" in
// the source and converted to the CRLF line endings real browsers send.

@(private = "file")
crlf :: proc(s: string) -> string {
	// Strip any CR first so a CRLF source checkout does not produce "\r\r\n".
	plain, _ := strings.replace_all(s, "\r", "", context.temp_allocator)
	out, _ := strings.replace_all(plain, "\n", "\r\n", context.temp_allocator)
	return out
}

// Chrome: audio first (mid 0), then video (mid 1), then a data channel.
// Several H.264 payload types differ in profile-level-id and packetization-mode,
// interleaved with rtx, VP8, VP9 and AV1.
CHROME_OFFER :: `v=0
o=- 4611731400430051336 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0 1 2
a=extmap-allow-mixed
a=msid-semantic: WMS
m=audio 9 UDP/TLS/RTP/SAVPF 111 63 9 0 8 13 110 126
c=IN IP4 0.0.0.0
a=rtcp:9 IN IP4 0.0.0.0
a=ice-ufrag:abcd
a=ice-pwd:0123456789abcdef01234567
a=fingerprint:sha-256 AA:BB:CC
a=setup:actpass
a=mid:0
a=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level
a=recvonly
a=rtcp-mux
a=rtpmap:111 opus/48000/2
a=rtcp-fb:111 transport-cc
a=fmtp:111 minptime=10;useinbandfec=1
a=rtpmap:63 red/48000/2
a=fmtp:63 111/111
a=rtpmap:9 G722/8000
a=rtpmap:0 PCMU/8000
a=rtpmap:8 PCMA/8000
a=rtpmap:13 CN/8000
a=rtpmap:110 telephone-event/48000
a=rtpmap:126 telephone-event/8000
m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101 102 122 127 121 125 107 108 109 123 118 35 36 37
c=IN IP4 0.0.0.0
a=rtcp:9 IN IP4 0.0.0.0
a=ice-ufrag:abcd
a=ice-pwd:0123456789abcdef01234567
a=setup:actpass
a=mid:1
a=extmap:14 urn:ietf:params:rtp-hdrext:toffset
a=recvonly
a=rtcp-mux
a=rtcp-rsize
a=rtpmap:96 VP8/90000
a=rtcp-fb:96 goog-remb
a=rtpmap:97 rtx/90000
a=fmtp:97 apt=96
a=rtpmap:98 VP9/90000
a=fmtp:98 profile-id=0
a=rtpmap:99 rtx/90000
a=fmtp:99 apt=98
a=rtpmap:100 VP9/90000
a=fmtp:100 profile-id=2
a=rtpmap:101 rtx/90000
a=fmtp:101 apt=100
a=rtpmap:102 H264/90000
a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f
a=rtpmap:122 rtx/90000
a=fmtp:122 apt=102
a=rtpmap:127 H264/90000
a=fmtp:127 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42001f
a=rtpmap:121 rtx/90000
a=fmtp:121 apt=127
a=rtpmap:125 H264/90000
a=fmtp:125 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
a=rtpmap:107 rtx/90000
a=fmtp:107 apt=125
a=rtpmap:108 H264/90000
a=fmtp:108 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=42e01f
a=rtpmap:109 rtx/90000
a=fmtp:109 apt=108
a=rtpmap:123 H264/90000
a=fmtp:123 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=4d001f
a=rtpmap:118 H264/90000
a=fmtp:118 level-asymmetry-allowed=1;packetization-mode=0;profile-level-id=4d001f
a=rtpmap:35 AV1/90000
a=fmtp:35 level-idx=5;profile=0;tier=0
a=rtpmap:36 rtx/90000
a=fmtp:36 apt=35
a=rtpmap:37 red/90000
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=mid:2
a=sctp-port:5000
`

// Firefox: 126 is packetization-mode=1, 97 has no packetization-mode (= mode 0).
// Video first, audio second.
FIREFOX_OFFER :: `v=0
o=mozilla...THIS_IS_SDPARTA-123.0 1234567890123456789 0 IN IP4 0.0.0.0
s=-
t=0 0
a=fingerprint:sha-256 AA:BB:CC
a=group:BUNDLE 0 1
a=ice-options:trickle
a=msid-semantic:WMS *
m=video 9 UDP/TLS/RTP/SAVPF 120 124 121 125 126 127 97 98
c=IN IP4 0.0.0.0
a=recvonly
a=extmap:3 urn:ietf:params:rtp-hdrext:sdes:mid
a=fmtp:126 profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1
a=fmtp:97 profile-level-id=42e01f;level-asymmetry-allowed=1
a=fmtp:120 max-fs=12288;max-fr=60
a=fmtp:124 apt=120
a=fmtp:121 max-fs=12288;max-fr=60
a=fmtp:125 apt=121
a=fmtp:127 apt=126
a=fmtp:98 apt=97
a=ice-pwd:fedcba9876543210
a=ice-ufrag:wxyz
a=mid:0
a=rtcp-fb:120 nack
a=rtcp-mux
a=rtpmap:120 VP8/90000
a=rtpmap:124 rtx/90000
a=rtpmap:121 VP9/90000
a=rtpmap:125 rtx/90000
a=rtpmap:126 H264/90000
a=rtpmap:127 rtx/90000
a=rtpmap:97 H264/90000
a=rtpmap:98 rtx/90000
a=setup:actpass
m=audio 9 UDP/TLS/RTP/SAVPF 109 9 0 8 101
c=IN IP4 0.0.0.0
a=recvonly
a=fmtp:109 maxplaybackrate=48000;stereo=1;useinbandfec=1
a=fmtp:101 0-15
a=ice-pwd:fedcba9876543210
a=ice-ufrag:wxyz
a=mid:1
a=rtcp-mux
a=rtpmap:109 opus/48000/2
a=rtpmap:9 G722/8000/1
a=rtpmap:0 PCMU/8000
a=rtpmap:8 PCMA/8000
a=rtpmap:101 telephone-event/8000
a=setup:actpass
`

// Safari: H.264 first with High profile variants, constrained baseline later;
// also offers HEVC.
SAFARI_OFFER :: `v=0
o=- 8800102132311227344 2 IN IP4 127.0.0.1
s=-
t=0 0
a=group:BUNDLE 0 1
m=audio 9 UDP/TLS/RTP/SAVPF 111 103 104 9 0 8 106 105 13 110 112 113 126
c=IN IP4 0.0.0.0
a=mid:0
a=recvonly
a=rtpmap:111 opus/48000/2
a=fmtp:111 minptime=10;useinbandfec=1
a=rtpmap:103 ISAC/16000
a=rtpmap:104 ISAC/32000
m=video 9 UDP/TLS/RTP/SAVPF 96 97 98 99 100 101 127 103 104
c=IN IP4 0.0.0.0
a=mid:1
a=recvonly
a=rtpmap:96 H264/90000
a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=640c1f
a=rtpmap:97 rtx/90000
a=fmtp:97 apt=96
a=rtpmap:98 H264/90000
a=fmtp:98 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
a=rtpmap:99 rtx/90000
a=fmtp:99 apt=98
a=rtpmap:100 H265/90000
a=fmtp:100 level-id=93;profile-id=1;tier-flag=0;tx-mode=SRST
a=rtpmap:101 VP8/90000
a=rtpmap:127 VP9/90000
a=fmtp:127 profile-id=0
`

@(private = "file")
expect_media :: proc(t: ^testing.T, m: Offer_Media, found: bool, mid: string, pt: int, loc := #caller_location) {
	testing.expect_value(t, m.found, found, loc = loc)
	testing.expect_value(t, m.mid, mid, loc = loc)
	testing.expect_value(t, m.pt, pt, loc = loc)
}

@(test)
test_parse_chrome_offer :: proc(t: ^testing.T) {
	sdp := crlf(CHROME_OFFER)
	info := parse_offer(sdp)

	// 125 is the only payload with packetization-mode=1 AND profile-level-id=42e01f.
	expect_media(t, info.video, true, "1", 125)
	testing.expect_value(t, info.video.fmtp, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f")
	testing.expect_value(t, fmtp_param(info.video.fmtp, "packetization-mode"), "1")
	testing.expect_value(t, fmtp_param(info.video.fmtp, "profile-level-id"), "42e01f")

	// Audio m-line comes first and has mid 0; Opus is PT 111 (not red/63).
	expect_media(t, info.audio, true, "0", 111)
	testing.expect_value(t, info.audio.fmtp, "minptime=10;useinbandfec=1")
}

@(test)
test_parse_chrome_offer_strings_are_slices_of_input :: proc(t: ^testing.T) {
	sdp := crlf(CHROME_OFFER)
	info := parse_offer(sdp)
	base := uintptr(raw_data(sdp))
	end := base + uintptr(len(sdp))
	for s in ([]string{info.video.mid, info.video.fmtp, info.audio.mid, info.audio.fmtp}) {
		p := uintptr(raw_data(s))
		testing.expect(t, p >= base && p + uintptr(len(s)) <= end, "string must point into the offer")
		testing.expect(t, !strings.contains(s, "\r") && !strings.contains(s, "\n"), "no line ending may leak into a value")
	}
}

@(test)
test_parse_firefox_offer :: proc(t: ^testing.T) {
	info := parse_offer(crlf(FIREFOX_OFFER))
	// 126 has packetization-mode=1; 97 has none (mode 0).
	expect_media(t, info.video, true, "0", 126)
	testing.expect_value(t, info.video.fmtp, "profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1")
	// Video first: audio has mid 1.
	expect_media(t, info.audio, true, "1", 109)
	testing.expect_value(t, info.audio.fmtp, "maxplaybackrate=48000;stereo=1;useinbandfec=1")
}

@(test)
test_parse_safari_offer :: proc(t: ^testing.T) {
	info := parse_offer(crlf(SAFARI_OFFER))
	// 98 is constrained baseline (42e01f) with packetization-mode=1; 96 is High (640c1f).
	expect_media(t, info.video, true, "1", 98)
	testing.expect_value(t, fmtp_param(info.video.fmtp, "profile-level-id"), "42e01f")
	expect_media(t, info.audio, true, "0", 111)
}

@(test)
test_parse_bare_lf_line_endings :: proc(t: ^testing.T) {
	// The raw constants contain bare "\n" only (crlf() was not applied).
	plain, _ := strings.replace_all(CHROME_OFFER, "\r", "", context.temp_allocator)
	info := parse_offer(plain)
	expect_media(t, info.video, true, "1", 125)
	expect_media(t, info.audio, true, "0", 111)
	testing.expect_value(t, info.audio.fmtp, "minptime=10;useinbandfec=1")
	testing.expect_value(t, info.video.fmtp, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f")
}

@(test)
test_parse_mixed_line_endings :: proc(t: ^testing.T) {
	sdp := "v=0\r\nm=video 9 RTP/AVP 100\na=mid:v\r\na=rtpmap:100 H264/90000\na=fmtp:100 packetization-mode=1\r\n"
	info := parse_offer(sdp)
	expect_media(t, info.video, true, "v", 100)
	testing.expect_value(t, info.video.fmtp, "packetization-mode=1")
}

@(test)
test_parse_no_trailing_newline :: proc(t: ^testing.T) {
	info := parse_offer("m=video 9 RTP/AVP 100\r\na=mid:5\r\na=rtpmap:100 H264/90000\r\na=fmtp:100 packetization-mode=1")
	expect_media(t, info.video, true, "5", 100)
	testing.expect_value(t, info.video.fmtp, "packetization-mode=1")
}

@(test)
test_parse_video_only_offer :: proc(t: ^testing.T) {
	sdp := crlf(`v=0
s=-
t=0 0
a=group:BUNDLE 0
m=video 9 UDP/TLS/RTP/SAVPF 102
a=mid:0
a=recvonly
a=rtpmap:102 H264/90000
a=fmtp:102 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f
`)
	info := parse_offer(sdp)
	expect_media(t, info.video, true, "0", 102)
	testing.expect_value(t, info.audio.found, false)
	testing.expect_value(t, info.audio.pt, 0)
	testing.expect_value(t, info.audio.mid, "")
	testing.expect_value(t, info.audio.fmtp, "")
}

@(test)
test_parse_audio_only_offer :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`v=0
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=mid:0
a=rtpmap:111 opus/48000/2
`))
	testing.expect_value(t, info.video.found, false)
	expect_media(t, info.audio, true, "0", 111)
	testing.expect_value(t, info.audio.fmtp, "")
}

@(test)
test_parse_audio_before_video_has_right_mids :: proc(t: ^testing.T) {
	// Deliberately unusual mids so a mix-up between the m-lines shows.
	info := parse_offer(crlf(`v=0
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=mid:aud
a=rtpmap:111 opus/48000/2
m=video 9 UDP/TLS/RTP/SAVPF 102
a=mid:vid
a=rtpmap:102 H264/90000
a=fmtp:102 packetization-mode=1
`))
	expect_media(t, info.video, true, "vid", 102)
	expect_media(t, info.audio, true, "aud", 111)

	// And the other way round.
	info = parse_offer(crlf(`v=0
m=video 9 UDP/TLS/RTP/SAVPF 102
a=mid:vid
a=rtpmap:102 H264/90000
a=fmtp:102 packetization-mode=1
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=mid:aud
a=rtpmap:111 opus/48000/2
`))
	expect_media(t, info.video, true, "vid", 102)
	expect_media(t, info.audio, true, "aud", 111)
}

@(test)
test_parse_no_h264 :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`v=0
m=audio 9 UDP/TLS/RTP/SAVPF 111
a=mid:0
a=rtpmap:111 opus/48000/2
m=video 9 UDP/TLS/RTP/SAVPF 96 97 98
a=mid:1
a=rtpmap:96 VP8/90000
a=rtpmap:97 rtx/90000
a=fmtp:97 apt=96
a=rtpmap:98 VP9/90000
a=fmtp:98 profile-id=0
`))
	testing.expect_value(t, info.video.found, false)
	testing.expect_value(t, info.video.pt, 0)
	testing.expect_value(t, info.video.fmtp, "")
	// Audio is unaffected.
	expect_media(t, info.audio, true, "0", 111)
}

@(test)
test_parse_h264_lookalikes_are_not_h264 :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=video 9 RTP/AVP 96 97 98
a=mid:0
a=rtpmap:96 H264-SVC/90000
a=rtpmap:97 H265/90000
a=rtpmap:98 H2640/90000
`))
	testing.expect_value(t, info.video.found, false)
}

@(test)
test_parse_codec_names_are_case_insensitive :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=audio 9 RTP/AVP 111
a=rtpmap:111 OPUS/48000/2
m=video 9 RTP/AVP 100
a=rtpmap:100 h264/90000
a=fmtp:100 packetization-mode=1
`))
	testing.expect_value(t, info.video.found, true)
	testing.expect_value(t, info.video.pt, 100)
	testing.expect_value(t, info.audio.found, true)
	testing.expect_value(t, info.audio.pt, 111)

	// An rtpmap without clock rate is still recognized.
	info = parse_offer("m=video 9 RTP/AVP 100\r\na=rtpmap:100 H264\r\n")
	testing.expect_value(t, info.video.found, true)
}

@(test)
test_parse_second_video_mline_ignored :: proc(t: ^testing.T) {
	// H.264 only in the second video m-line: not found.
	info := parse_offer(crlf(`m=video 9 RTP/AVP 96
a=mid:0
a=rtpmap:96 VP8/90000
m=video 9 RTP/AVP 100
a=mid:1
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=42e01f
`))
	testing.expect_value(t, info.video.found, false) // H.264 in the second video m-line is ignored

	// H.264 in both: the first one wins, including its mid.
	info = parse_offer(crlf(`m=video 9 RTP/AVP 100
a=mid:first
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=42e01f
m=video 9 RTP/AVP 101
a=mid:second
a=rtpmap:101 H264/90000
a=fmtp:101 packetization-mode=1;profile-level-id=42e01f
`))
	expect_media(t, info.video, true, "first", 100)
}

@(test)
test_parse_second_audio_mline_ignored :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=audio 9 RTP/AVP 111
a=mid:a1
a=rtpmap:111 opus/48000/2
a=fmtp:111 useinbandfec=1
m=audio 9 RTP/AVP 112
a=mid:a2
a=rtpmap:112 opus/48000/2
a=fmtp:112 stereo=1
`))
	expect_media(t, info.audio, true, "a1", 111)
	testing.expect_value(t, info.audio.fmtp, "useinbandfec=1")
}

@(test)
test_parse_other_sections_do_not_leak_into_media :: proc(t: ^testing.T) {
	// The mid and rtpmap lines of an application m-line (and session-level
	// attributes before the first m-line) must not land on video/audio.
	info := parse_offer(crlf(`v=0
a=mid:session
a=rtpmap:100 H264/90000
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
a=mid:data
a=rtpmap:101 H264/90000
m=video 9 RTP/AVP 102
a=rtpmap:102 H264/90000
a=fmtp:102 packetization-mode=1
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
a=mid:data2
a=rtpmap:103 H264/90000
`))
	testing.expect_value(t, info.video.found, true)
	testing.expect_value(t, info.video.pt, 102)
	// No a=mid in the video section: default is "0".
	testing.expect_value(t, info.video.mid, "0")
}

@(test)
test_parse_missing_mid_defaults :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=audio 9 RTP/AVP 111
a=rtpmap:111 opus/48000/2
m=video 9 RTP/AVP 100
a=rtpmap:100 H264/90000
`))
	testing.expect_value(t, info.video.mid, "0")
	testing.expect_value(t, info.audio.mid, "1")
}

@(test)
test_parse_h264_without_fmtp :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100
a=mid:0
a=rtpmap:100 H264/90000
`))
	expect_media(t, info.video, true, "0", 100)
	testing.expect_value(t, info.video.fmtp, "")
}

@(test)
test_parse_prefers_packetization_mode_1 :: proc(t: ^testing.T) {
	// mode 0 first, mode 1 later: mode 1 wins even with a worse profile.
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100 101
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=0;profile-level-id=42e01f
a=rtpmap:101 H264/90000
a=fmtp:101 packetization-mode=1;profile-level-id=640c1f
`))
	testing.expect_value(t, info.video.pt, 101)
}

@(test)
test_parse_profile_preference_order :: proc(t: ^testing.T) {
	// Same packetization-mode: 42e01f > 42e0xx > 42xxxx > everything else.
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100 101 102 103
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=640c1f
a=rtpmap:101 H264/90000
a=fmtp:101 packetization-mode=1;profile-level-id=42001f
a=rtpmap:102 H264/90000
a=fmtp:102 packetization-mode=1;profile-level-id=42e028
a=rtpmap:103 H264/90000
a=fmtp:103 packetization-mode=1;profile-level-id=42E01F
`))
	testing.expect_value(t, info.video.pt, 103) // upper-case hex still counts as 42e01f

	info = parse_offer(crlf(`m=video 9 RTP/AVP 100 101 102
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=640c1f
a=rtpmap:101 H264/90000
a=fmtp:101 packetization-mode=1;profile-level-id=42001f
a=rtpmap:102 H264/90000
a=fmtp:102 packetization-mode=1;profile-level-id=42e028
`))
	testing.expect_value(t, info.video.pt, 102)

	info = parse_offer(crlf(`m=video 9 RTP/AVP 100 101
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=640c1f
a=rtpmap:101 H264/90000
a=fmtp:101 packetization-mode=1;profile-level-id=42001f
`))
	testing.expect_value(t, info.video.pt, 101)
}

@(test)
test_parse_tie_keeps_first :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100 101
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=42e01f
a=rtpmap:101 H264/90000
a=fmtp:101 packetization-mode=1;profile-level-id=42e01f
`))
	testing.expect_value(t, info.video.pt, 100)
}

@(test)
test_parse_only_packetization_mode_0_offered :: proc(t: ^testing.T) {
	// The stream is sent as STAP-A / FU-A, which needs packetization-mode 1;
	// an offer with only mode-0 H.264 cannot be answered.
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=0;profile-level-id=42e01f
`))
	testing.expect_value(t, info.video.found, false)
}

@(test)
test_parse_missing_packetization_mode_equals_mode_0 :: proc(t: ^testing.T) {
	// RFC 6184: packetization-mode defaults to 0 when absent, so an explicit
	// mode=0 payload and one without the parameter are equivalent and neither
	// may beat a real mode=1 payload.
	info := parse_offer(crlf(`m=video 9 RTP/AVP 97 126
a=mid:0
a=rtpmap:97 H264/90000
a=fmtp:97 profile-id=42e01f;level-asymmetry-allowed=1
a=rtpmap:126 H264/90000
a=fmtp:126 profile-level-id=42e01f;packetization-mode=1
`))
	testing.expect_value(t, info.video.pt, 126)
}

@(test)
test_parse_explicit_mode_0_is_skipped_for_an_unspecified_one :: proc(t: ^testing.T) {
	// Explicit mode 0 is unusable; a payload that does not state its mode is the fallback.
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100 101
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=0;profile-level-id=42e01f
a=rtpmap:101 H264/90000
a=fmtp:101 profile-level-id=640c1f
`))
	testing.expect_value(t, info.video.found, true)
	testing.expect_value(t, info.video.pt, 101)
}

@(test)
test_parse_fmtp_for_h264_pt_without_rtpmap_is_ignored :: proc(t: ^testing.T) {
	// An fmtp whose PT is not an H.264 rtpmap (rtx apt, VP9 profile-id) must not attach to H.264.
	info := parse_offer(crlf(`m=video 9 RTP/AVP 98 99 100
a=mid:0
a=rtpmap:98 VP9/90000
a=fmtp:98 packetization-mode=1;profile-level-id=42e01f
a=rtpmap:99 rtx/90000
a=fmtp:99 apt=100
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=42e01f
`))
	expect_media(t, info.video, true, "0", 100)
}

@(test)
test_parse_more_than_16_h264_payloads :: proc(t: ^testing.T) {
	// 20 H.264 payload types: must not crash or overflow, and the first
	// MAX_H264_PAYLOADS are considered. The best one is the 3rd.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "m=video 9 RTP/AVP")
	for i in 0 ..< 20 {
		fmt.sbprintf(&b, " %d", 100 + i)
	}
	strings.write_string(&b, "\na=mid:0\n")
	for i in 0 ..< 20 {
		pt := 100 + i
		pm := 1 if i == 2 else 0
		plid := "42e01f" if i == 2 else "640c1f"
		fmt.sbprintf(&b, "a=rtpmap:%d H264/90000\na=fmtp:%d packetization-mode=%d;profile-level-id=%s\n", pt, pt, pm, plid)
	}
	info := parse_offer(strings.to_string(b))
	expect_media(t, info.video, true, "0", 102)
	testing.expect_value(t, fmtp_param(info.video.fmtp, "packetization-mode"), "1")
}

@(test)
test_parse_many_h264_payloads_best_one_late :: proc(t: ^testing.T) {
	// The only usable (mode-1) payload is the 18th of 20: it must still be found.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "m=video 9 RTP/AVP")
	for i in 0 ..< 20 {
		fmt.sbprintf(&b, " %d", 100 + i)
	}
	strings.write_string(&b, "\na=mid:0\n")
	for i in 0 ..< 20 {
		pt := 100 + i
		pm := 1 if i == 17 else 0
		plid := "42e01f" if i == 17 else "640c1f"
		fmt.sbprintf(&b, "a=rtpmap:%d H264/90000\na=fmtp:%d packetization-mode=%d;profile-level-id=%s\n", pt, pt, pm, plid)
	}
	info := parse_offer(strings.to_string(b))
	expect_media(t, info.video, true, "0", 117)
	testing.expect_value(t, fmtp_param(info.video.fmtp, "profile-level-id"), "42e01f")
}

@(test)
test_parse_exactly_16_h264_payloads :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "m=video 9 RTP/AVP\na=mid:0\n")
	for i in 0 ..< MAX_H264_PAYLOADS {
		pt := 100 + i
		pm := 1 if i == MAX_H264_PAYLOADS - 1 else 0
		fmt.sbprintf(&b, "a=rtpmap:%d H264/90000\na=fmtp:%d packetization-mode=%d;profile-level-id=42e01f\n", pt, pt, pm)
	}
	info := parse_offer(strings.to_string(b))
	// The last of the 16 is the only mode-1 payload.
	expect_media(t, info.video, true, "0", 100 + MAX_H264_PAYLOADS - 1)
}

@(test)
test_parse_malformed_lines_are_skipped :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100
a=mid:0
a=rtpmap:
a=rtpmap:abc H264/90000
a=rtpmap:100
a=rtpmap: H264/90000
a=rtpmap:-3 H264/90000
a=fmtp:
a=fmtp:100
a=fmtp:x packetization-mode=1
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=42e01f
`))
	testing.expect_value(t, info.video.found, true)
	testing.expect_value(t, info.video.pt, 100)
	testing.expect_value(t, info.video.fmtp, "packetization-mode=1;profile-level-id=42e01f")
}

@(test)
test_parse_empty_and_garbage :: proc(t: ^testing.T) {
	info := parse_offer("")
	testing.expect(t, !info.video.found && !info.audio.found)
	info = parse_offer("\r\n\r\n\r\n")
	testing.expect(t, !info.video.found && !info.audio.found)
	info = parse_offer("this is not sdp\n\x00\xff\xfe\nm=\nm=video\nm=audio\n")
	testing.expect(t, !info.video.found && !info.audio.found)
}

@(test)
test_parse_duplicate_fmtp_keeps_first :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1;profile-level-id=42e01f
a=fmtp:100 packetization-mode=0;profile-level-id=640c1f
`))
	testing.expect_value(t, info.video.fmtp, "packetization-mode=1;profile-level-id=42e01f")
}

@(test)
test_parse_audio_only_opus_counts :: proc(t: ^testing.T) {
	// No Opus in the audio m-line: audio not found, video untouched.
	info := parse_offer(crlf(`m=audio 9 RTP/AVP 0 8
a=mid:0
a=rtpmap:0 PCMU/8000
a=rtpmap:8 PCMA/8000
m=video 9 RTP/AVP 100
a=mid:1
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1
`))
	testing.expect_value(t, info.audio.found, false)
	testing.expect_value(t, info.video.found, true)
}

@(test)
test_parse_opus_in_video_section_ignored :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=video 9 RTP/AVP 100 101
a=mid:0
a=rtpmap:100 H264/90000
a=fmtp:100 packetization-mode=1
a=rtpmap:101 opus/48000/2
`))
	testing.expect_value(t, info.audio.found, false)
}

@(test)
test_parse_opus_fmtp_only_for_opus_pt :: proc(t: ^testing.T) {
	info := parse_offer(crlf(`m=audio 9 RTP/AVP 63 111
a=mid:0
a=rtpmap:111 opus/48000/2
a=rtpmap:63 red/48000/2
a=fmtp:63 111/111
a=fmtp:111 minptime=10;useinbandfec=1
`))
	expect_media(t, info.audio, true, "0", 111)
	testing.expect_value(t, info.audio.fmtp, "minptime=10;useinbandfec=1")
}

// ---------------------------------------------------------------------------
// fmtp_param
// ---------------------------------------------------------------------------

@(test)
test_fmtp_param_positions :: proc(t: ^testing.T) {
	f := "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f"
	testing.expect_value(t, fmtp_param(f, "level-asymmetry-allowed"), "1")  // first
	testing.expect_value(t, fmtp_param(f, "packetization-mode"), "1")      // middle
	testing.expect_value(t, fmtp_param(f, "profile-level-id"), "42e01f")   // last
	testing.expect_value(t, fmtp_param(f, "missing"), "")
	testing.expect_value(t, fmtp_param("", "x"), "")
	testing.expect_value(t, fmtp_param("x=1", "x"), "1")
}

@(test)
test_fmtp_param_key_suffix_and_prefix :: proc(t: ^testing.T) {
	// A key that is a suffix / prefix of another key must not match.
	testing.expect_value(t, fmtp_param("x-packetization-mode=0;packetization-mode=1", "packetization-mode"), "1")
	testing.expect_value(t, fmtp_param("x-packetization-mode=0", "packetization-mode"), "")
	testing.expect_value(t, fmtp_param("packetization-mode-x=0", "packetization-mode"), "")
	testing.expect_value(t, fmtp_param("packetization-mode=1", "packetization-mode-x"), "")
	testing.expect_value(t, fmtp_param("a=1;ab=2", "b"), "")
	testing.expect_value(t, fmtp_param("ab=2;a=1", "a"), "1")
}

@(test)
test_fmtp_param_whitespace :: proc(t: ^testing.T) {
	testing.expect_value(t, fmtp_param("a=1; b=2; c=3", "b"), "2")
	testing.expect_value(t, fmtp_param("a=1;  b=2 ;c=3", "b"), "2")
	testing.expect_value(t, fmtp_param(" a=1 ", "a"), "1")
	testing.expect_value(t, fmtp_param("a=1;\tb=2", "b"), "2")
}

@(test)
test_fmtp_param_odd_values :: proc(t: ^testing.T) {
	// Empty value, value containing '=' (base64 padding), valueless parameter.
	testing.expect_value(t, fmtp_param("a=;b=2", "a"), "")
	testing.expect_value(t, fmtp_param("sprop-parameter-sets=Z0Lg,aM4=;packetization-mode=1", "sprop-parameter-sets"), "Z0Lg,aM4=")
	testing.expect_value(t, fmtp_param("a=1;novalue;b=2", "novalue"), "")
	testing.expect_value(t, fmtp_param("a=1;novalue;b=2", "b"), "2")
	testing.expect_value(t, fmtp_param("=5;a=1", ""), "") // empty key never matches
	// Trailing / doubled separators.
	testing.expect_value(t, fmtp_param("a=1;;b=2;", "b"), "2")
	// First occurrence wins.
	testing.expect_value(t, fmtp_param("a=1;a=2", "a"), "1")
}

@(test)
test_fmtp_param_is_case_sensitive_on_key :: proc(t: ^testing.T) {
	// Pins current behaviour (exact key match). Browsers emit lower-case keys.
	testing.expect_value(t, fmtp_param("Packetization-Mode=1", "packetization-mode"), "")
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

@(test)
test_codec_is :: proc(t: ^testing.T) {
	testing.expect(t, codec_is("H264/90000", "h264"))
	testing.expect(t, codec_is("h264/90000", "h264"))
	testing.expect(t, codec_is("H264", "h264"))
	testing.expect(t, codec_is("opus/48000/2", "opus"))
	testing.expect(t, !codec_is("H264-SVC/90000", "h264"))
	testing.expect(t, !codec_is("H2644/90000", "h264"))
	testing.expect(t, !codec_is("H26", "h264"))
	testing.expect(t, !codec_is("", "h264"))
	testing.expect(t, !codec_is("xH264/90000", "h264"))
}

@(test)
test_h264_fmtp_score_ordering :: proc(t: ^testing.T) {
	s_best := h264_fmtp_score("packetization-mode=1;profile-level-id=42e01f")
	s_cbp := h264_fmtp_score("packetization-mode=1;profile-level-id=42e028")
	s_bp := h264_fmtp_score("packetization-mode=1;profile-level-id=42001f")
	s_high := h264_fmtp_score("packetization-mode=1;profile-level-id=640c1f")
	s_mode0 := h264_fmtp_score("packetization-mode=0;profile-level-id=42e01f")
	testing.expect(t, s_best > s_cbp && s_cbp > s_bp && s_bp > s_high && s_high > s_mode0)
}

@(test)
test_parse_fmtp_before_rtpmap :: proc(t: ^testing.T) {
	// Firefox lists attributes alphabetically, so a=fmtp comes before
	// a=rtpmap. The mode-0 payload (97) is declared first in the rtpmaps, so
	// without the fmtp lines the parser could not tell them apart and would
	// pick it.
	info := parse_offer(crlf(`m=video 9 RTP/AVP 97 126
a=fmtp:97 profile-level-id=42e01f;level-asymmetry-allowed=1
a=fmtp:126 profile-level-id=42e01f;level-asymmetry-allowed=1;packetization-mode=1
a=mid:0
a=rtpmap:97 H264/90000
a=rtpmap:126 H264/90000
m=audio 9 RTP/AVP 109
a=fmtp:109 maxplaybackrate=48000;stereo=1;useinbandfec=1
a=mid:1
a=rtpmap:109 opus/48000/2
`))
	expect_media(t, info.video, true, "0", 126)
	testing.expect_value(t, fmtp_param(info.video.fmtp, "packetization-mode"), "1")
	expect_media(t, info.audio, true, "1", 109)
	testing.expect_value(t, info.audio.fmtp, "maxplaybackrate=48000;stereo=1;useinbandfec=1")
}

} // when ODIN_TEST
