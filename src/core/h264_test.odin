package core

import "core:fmt"
import "core:slice"
import "core:testing"

// Everything below only exists in `odin test` builds: the package directory is
// also built by a plain `odin build`, which must not compile (or break on) tests.
when ODIN_TEST {

// Unit tests for the H.264 bitstream helpers. Run with tests/run.sh.
//
// Scaffolding (test inputs) is built on context.temp_allocator, which the
// test runner clears after each test. Everything the functions under test
// return is freed explicitly so the runner's leak tracker stays quiet.

// Hand-written NAL units. Byte 0 is the NAL header: forbidden_zero_bit(1) NRI(2) type(5).
// No payload byte below ever forms 00 00 0x, so none of them needs emulation prevention.
SPS_NAL    :: []byte{0x67, 0x42, 0xe0, 0x1f, 0xaa, 0xbb} // type 7
PPS_NAL    :: []byte{0x68, 0xce, 0x3c, 0x80}             // type 8
IDR_NAL    :: []byte{0x65, 0x88, 0x84, 0x00, 0x33}       // type 5 (ends in non-zero)
IDR2_NAL   :: []byte{0x65, 0x11, 0x22}                   // type 5
SLICE_NAL  :: []byte{0x41, 0x9a, 0x00, 0x11}             // type 1 (non-IDR)
SLICE2_NAL :: []byte{0x41, 0x9b, 0x22}                   // type 1
SEI_NAL    :: []byte{0x06, 0x05, 0x01, 0x02}             // type 6
AUD_NAL    :: []byte{0x09, 0xf0}                         // type 9
FILLER_NAL :: []byte{0x0c, 0xff, 0xff}                   // type 12

SC4 :: []byte{0, 0, 0, 1}
SC3 :: []byte{0, 0, 1}

@(private = "file")
cat :: proc(parts: ..[]byte) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	for p in parts {
		append(&out, ..p)
	}
	return out[:]
}

// Builds an AVCC buffer (4-byte big-endian lengths) from NAL units.
@(private = "file")
avcc_of :: proc(nals: ..[]byte) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	for n in nals {
		append(&out, u8(len(n) >> 24), u8(len(n) >> 16), u8(len(n) >> 8), u8(len(n)))
		append(&out, ..n)
	}
	return out[:]
}

// NAL of the given total size (including header byte) with a non-zero filler payload.
@(private = "file")
big_nal :: proc(header: u8, size: int) -> []byte {
	n := make([]byte, size, context.temp_allocator)
	n[0] = header
	for i in 1 ..< size {
		n[i] = 0x11 + u8(i % 7) // never zero: no accidental start codes
	}
	return n
}

@(private = "file")
expect_bytes :: proc(t: ^testing.T, got, want: []byte, what := "", loc := #caller_location) -> bool {
	ok := slice.equal(got, want)
	testing.expectf(t, ok, "%s\n  got  (%d): % x\n  want (%d): % x", what, len(got), got, len(want), want, loc = loc)
	return ok
}

// ---------------------------------------------------------------------------
// AVCC iterator / validation
// ---------------------------------------------------------------------------

@(test)
test_avcc_iterator_walks_all_nals :: proc(t: ^testing.T) {
	data := avcc_of(SPS_NAL, PPS_NAL, IDR_NAL)
	it := avcc_iterator(data)
	want := [][]byte{SPS_NAL, PPS_NAL, IDR_NAL}
	i := 0
	for nal in avcc_next(&it) {
		if !testing.expect(t, i < len(want), "iterator yielded too many NALs") {
			return
		}
		expect_bytes(t, nal, want[i])
		i += 1
	}
	testing.expect_value(t, i, 3)
	testing.expect(t, it.valid)
	testing.expect_value(t, it.pos, len(data))
}

@(test)
test_avcc_iterator_flags_bad_lengths :: proc(t: ^testing.T) {
	// Length running past the end.
	{
		data := []byte{0, 0, 0, 9, 0x65, 0x88}
		it := avcc_iterator(data)
		_, ok := avcc_next(&it)
		testing.expect(t, !ok)
		testing.expect(t, !it.valid, "overlong length must mark iterator invalid")
	}
	// Zero length.
	{
		data := []byte{0, 0, 0, 0, 0x65, 0x88}
		it := avcc_iterator(data)
		_, ok := avcc_next(&it)
		testing.expect(t, !ok)
		testing.expect(t, !it.valid, "zero length must mark iterator invalid")
	}
	// Length with the top bit set (would be negative if read as i32).
	{
		data := []byte{0xff, 0xff, 0xff, 0xff, 0x65, 0x88}
		it := avcc_iterator(data)
		_, ok := avcc_next(&it)
		testing.expect(t, !ok)
		testing.expect(t, !it.valid)
	}
	// Fewer than 4 bytes left: ends, but is not a "bad length".
	{
		data := []byte{0, 0, 1}
		it := avcc_iterator(data)
		_, ok := avcc_next(&it)
		testing.expect(t, !ok)
	}
	// Empty / nil input.
	{
		it := avcc_iterator(nil)
		_, ok := avcc_next(&it)
		testing.expect(t, !ok)
		testing.expect(t, it.valid)
	}
}

@(test)
test_avcc_is_valid :: proc(t: ^testing.T) {
	testing.expect(t, avcc_is_valid(avcc_of(IDR_NAL)))
	testing.expect(t, avcc_is_valid(avcc_of(SPS_NAL, PPS_NAL, IDR_NAL)))
	// Minimum valid buffer: 4-byte length + 1 byte NAL.
	testing.expect(t, avcc_is_valid([]byte{0, 0, 0, 1, 0x41}))

	testing.expect(t, !avcc_is_valid(nil))
	testing.expect(t, !avcc_is_valid([]byte{}))
	testing.expect(t, !avcc_is_valid([]byte{0, 0, 0, 1}), "length without NAL byte")
	testing.expect(t, !avcc_is_valid([]byte{0, 0, 0, 0, 0x41}), "zero length")
	testing.expect(t, !avcc_is_valid([]byte{0, 0, 0, 5, 0x41, 1, 2, 3}), "truncated NAL")

	// Trailing bytes (1..3) after a complete NAL make it invalid.
	good := avcc_of(IDR_NAL)
	testing.expect(t, !avcc_is_valid(cat(good, []byte{0})))
	testing.expect(t, !avcc_is_valid(cat(good, []byte{0, 0, 0})))
	// ... and so does a second NAL that is truncated.
	testing.expect(t, !avcc_is_valid(cat(good, []byte{0, 0, 0, 7, 0x41})))
	// A zero-length NAL after a valid one.
	testing.expect(t, !avcc_is_valid(cat(good, []byte{0, 0, 0, 0})))

	// Annex-B data must not validate as AVCC.
	testing.expect(t, !avcc_is_valid(cat(SC4, IDR_NAL)))
}

@(test)
test_avcc_has_nal :: proc(t: ^testing.T) {
	data := avcc_of(SPS_NAL, PPS_NAL, IDR_NAL)
	testing.expect(t, avcc_has_nal(data, NAL_SPS))
	testing.expect(t, avcc_has_nal(data, NAL_PPS))
	testing.expect(t, avcc_has_nal(data, NAL_SLICE_IDR))
	testing.expect(t, !avcc_has_nal(data, 1))
	testing.expect(t, !avcc_has_nal(data, NAL_SEI))

	testing.expect(t, !avcc_has_nal(nil, NAL_SLICE_IDR))
	testing.expect(t, !avcc_has_nal([]byte{0, 0}, NAL_SLICE_IDR))

	// Truncated tail: NALs before it are still found, the broken one is not.
	trunc := cat(avcc_of(SPS_NAL), []byte{0, 0, 0, 50, 0x65, 1, 2})
	testing.expect(t, avcc_has_nal(trunc, NAL_SPS))
	testing.expect(t, !avcc_has_nal(trunc, NAL_SLICE_IDR), "NAL running past the end must not count")
	// Zero length stops iteration.
	zero := cat([]byte{0, 0, 0, 0}, avcc_of(IDR_NAL))
	testing.expect(t, !avcc_has_nal(zero, NAL_SLICE_IDR))
}

// ---------------------------------------------------------------------------
// h264_to_avcc
// ---------------------------------------------------------------------------

@(test)
test_to_avcc_annexb_mixed_start_codes :: proc(t: ^testing.T) {
	// 4-byte, 3-byte, 4-byte, 3-byte start codes.
	src := cat(SC4, SPS_NAL, SC3, PPS_NAL, SC4, IDR_NAL, SC3, IDR2_NAL)
	out := h264_to_avcc(src)
	defer delete(out)
	expect_bytes(t, out, avcc_of(SPS_NAL, PPS_NAL, IDR_NAL, IDR2_NAL))
}

@(test)
test_to_avcc_annexb_three_byte_only :: proc(t: ^testing.T) {
	src := cat(SC3, SPS_NAL, SC3, PPS_NAL)
	out := h264_to_avcc(src)
	defer delete(out)
	expect_bytes(t, out, avcc_of(SPS_NAL, PPS_NAL))
}

@(test)
test_to_avcc_annexb_trailing_zeros :: proc(t: ^testing.T) {
	// trailing_zero_8bits at the end of the stream ...
	{
		src := cat(SC4, IDR_NAL, []byte{0, 0, 0, 0})
		out := h264_to_avcc(src)
		defer delete(out)
		expect_bytes(t, out, avcc_of(IDR_NAL), "trailing zeros at end")
	}
	// ... and before the next start code (4-byte start code preceded by extra zeros).
	{
		src := cat(SC4, SPS_NAL, []byte{0, 0, 0}, SC4, PPS_NAL, []byte{0}, SC3, IDR_NAL)
		out := h264_to_avcc(src)
		defer delete(out)
		expect_bytes(t, out, avcc_of(SPS_NAL, PPS_NAL, IDR_NAL), "trailing zeros between NALs")
	}
}

@(test)
test_to_avcc_annexb_empty_nals_skipped :: proc(t: ^testing.T) {
	// Back-to-back start codes yield no NAL; a start code at the very end neither.
	src := cat(SC4, SC3, IDR_NAL, SC4)
	out := h264_to_avcc(src)
	defer delete(out)
	expect_bytes(t, out, avcc_of(IDR_NAL))
}

@(test)
test_to_avcc_annexb_leading_zero_bytes :: proc(t: ^testing.T) {
	// Annex B allows leading_zero_8bits before the first start code, so this
	// is `00 00 00 00 00 01 <NAL>`: five zeros then 01.
	src := cat([]byte{0, 0}, SC4, SPS_NAL, SC4, IDR_NAL)
	out := h264_to_avcc(src)
	defer delete(out)
	expect_bytes(t, out, avcc_of(SPS_NAL, IDR_NAL))
}

@(test)
test_to_avcc_annexb_leading_garbage :: proc(t: ^testing.T) {
	// annexb_to_avcc skips bytes until it finds a start code, but h264_to_avcc
	// only takes that path when the packet begins with a start code (possibly
	// after leading zero bytes). Non-zero junk first -> the packet is treated
	// as non-H.264 and dropped. Pinned as current behaviour (safe, and no
	// encoder emits this); see report.
	src := cat([]byte{0xff, 0xff}, SC4, IDR_NAL)
	out := h264_to_avcc(src)
	defer delete(out)
	testing.expect(t, out == nil, "non-zero garbage before the first start code is dropped")
}

@(test)
test_to_avcc_passthrough_valid_avcc :: proc(t: ^testing.T) {
	src := avcc_of(SPS_NAL, PPS_NAL, IDR_NAL)
	out := h264_to_avcc(src)
	defer delete(out)
	expect_bytes(t, out, src)
	testing.expect(t, raw_data(out) != raw_data(src), "result must be a copy owned by the caller")
}

@(test)
test_to_avcc_first_length_looks_like_start_code :: proc(t: ^testing.T) {
	// A NAL of 256..511 bytes has the prefix 00 00 01 xx, which looks like a
	// 3-byte start code. Valid AVCC has to win.
	sizes := [?]int{256, 257, 300, 511, 512, 1000, 65535, 65536, 70000}
	for size in sizes {
		nal := big_nal(0x65, size)
		src := avcc_of(nal)
		out := h264_to_avcc(src)
		expect_bytes(t, out, src, fmt.tprintf("single NAL of %d bytes", size))
		delete(out)
	}
	// Large first NAL followed by more NALs.
	{
		src := avcc_of(big_nal(0x65, 300), PPS_NAL, SLICE_NAL)
		out := h264_to_avcc(src)
		defer delete(out)
		expect_bytes(t, out, src, "256..511 byte NAL then small ones")
	}
	// Exactly 65536 + a prefix 00 01 00 00 is no start code either, but 00 00 01 00 (=256) is.
	{
		src := avcc_of(SPS_NAL, big_nal(0x65, 256))
		out := h264_to_avcc(src)
		defer delete(out)
		expect_bytes(t, out, src)
	}
}

@(test)
test_to_avcc_avcc_one_byte_nal :: proc(t: ^testing.T) {
	// 00 00 00 01 41 is both a (degenerate) AVCC unit and Annex-B 4-byte start
	// code + a 1 byte NAL. Both readings give the same output.
	out := h264_to_avcc([]byte{0, 0, 0, 1, 0x41})
	defer delete(out)
	expect_bytes(t, out, []byte{0, 0, 0, 1, 0x41})
}

@(test)
test_to_avcc_bare_nal :: proc(t: ^testing.T) {
	// A bare slice NAL with no start code and no length prefix.
	{
		out := h264_to_avcc(IDR_NAL)
		defer delete(out)
		expect_bytes(t, out, avcc_of(IDR_NAL))
	}
	{
		out := h264_to_avcc(SLICE_NAL)
		defer delete(out)
		expect_bytes(t, out, avcc_of(SLICE_NAL))
	}
	// Bare parameter sets are kept ...
	{
		out := h264_to_avcc(SPS_NAL)
		defer delete(out)
		expect_bytes(t, out, avcc_of(SPS_NAL))
	}
	// ... bare SEI/AUD/filler are dropped.
	testing.expect(t, h264_to_avcc(SEI_NAL) == nil)
	testing.expect(t, h264_to_avcc(AUD_NAL) == nil)
	testing.expect(t, h264_to_avcc(FILLER_NAL) == nil)
	// Not a single NAL: type 0, type >= 24 (aggregation/fragmentation types).
	testing.expect(t, h264_to_avcc([]byte{0x00, 0x01, 0x02}) == nil)
	testing.expect(t, h264_to_avcc([]byte{0x78, 0x00, 0x01, 0x02}) == nil)
	testing.expect(t, h264_to_avcc([]byte{0xff, 0xff, 0xff, 0xff, 0xff}) == nil)
}

@(test)
test_to_avcc_drops_sei_aud_filler :: proc(t: ^testing.T) {
	// AVCC input
	{
		src := avcc_of(AUD_NAL, SEI_NAL, SPS_NAL, PPS_NAL, FILLER_NAL, IDR_NAL)
		out := h264_to_avcc(src)
		defer delete(out)
		expect_bytes(t, out, avcc_of(SPS_NAL, PPS_NAL, IDR_NAL), "avcc input")
	}
	// Annex-B input
	{
		src := cat(SC4, AUD_NAL, SC4, SEI_NAL, SC3, SPS_NAL, SC3, PPS_NAL, SC4, FILLER_NAL, SC3, IDR_NAL)
		out := h264_to_avcc(src)
		defer delete(out)
		expect_bytes(t, out, avcc_of(SPS_NAL, PPS_NAL, IDR_NAL), "annex-b input")
	}
	// Type 0 (unspecified) NALs are dropped as well.
	{
		src := avcc_of([]byte{0x00, 0x01}, SLICE_NAL)
		out := h264_to_avcc(src)
		defer delete(out)
		expect_bytes(t, out, avcc_of(SLICE_NAL))
	}
}

@(test)
test_to_avcc_nothing_left_is_nil :: proc(t: ^testing.T) {
	testing.expect(t, h264_to_avcc(nil) == nil)
	testing.expect(t, h264_to_avcc([]byte{}) == nil)
	testing.expect(t, h264_to_avcc(avcc_of(AUD_NAL, SEI_NAL)) == nil, "avcc with only droppable NALs")
	testing.expect(t, h264_to_avcc(cat(SC4, AUD_NAL, SC3, SEI_NAL)) == nil, "annex-b with only droppable NALs")
	testing.expect(t, h264_to_avcc([]byte{0, 0, 0, 0, 0, 0}) == nil, "zeros")
	testing.expect(t, h264_to_avcc(SC4) == nil, "start code alone")
	testing.expect(t, h264_to_avcc(SC3) == nil, "start code alone")
	{
		out := h264_to_avcc([]byte{0x65})
		defer delete(out)
		testing.expect(t, out != nil, "one byte IDR NAL is still a NAL")
	}
}

@(test)
test_to_avcc_malformed_avcc_is_not_passed_through :: proc(t: ^testing.T) {
	// A length running past the end is neither valid AVCC nor Annex-B nor a bare NAL.
	src := []byte{0, 0, 0, 200, 0x65, 0x88, 0x84, 0x00, 0x33}
	out := h264_to_avcc(src)
	defer delete(out)
	testing.expect(t, out == nil, "truncated AVCC must not be forwarded")
}

@(test)
test_to_avcc_uses_given_allocator :: proc(t: ^testing.T) {
	out := h264_to_avcc(cat(SC4, IDR_NAL), context.temp_allocator)
	expect_bytes(t, out, avcc_of(IDR_NAL))
}

// ---------------------------------------------------------------------------
// Parameter sets
// ---------------------------------------------------------------------------

@(test)
test_param_sets_first_of_each :: proc(t: ^testing.T) {
	sps2 := []byte{0x67, 0x64, 0x00, 0x28}
	pps2 := []byte{0x68, 0xee, 0x06}
	data := avcc_of(AUD_NAL, SPS_NAL, PPS_NAL, sps2, pps2, IDR_NAL)
	sps, pps := h264_param_sets(data)
	expect_bytes(t, sps, SPS_NAL, "first SPS")
	expect_bytes(t, pps, PPS_NAL, "first PPS")
	// Slices point into the input.
	base := uintptr(raw_data(data))
	testing.expect(t, uintptr(raw_data(sps)) >= base && uintptr(raw_data(sps)) < base + uintptr(len(data)))
}

@(test)
test_param_sets_missing :: proc(t: ^testing.T) {
	sps, pps := h264_param_sets(avcc_of(SLICE_NAL))
	testing.expect(t, sps == nil && pps == nil)

	sps, pps = h264_param_sets(avcc_of(SPS_NAL, SLICE_NAL))
	expect_bytes(t, sps, SPS_NAL)
	testing.expect(t, pps == nil)

	sps, pps = h264_param_sets(avcc_of(PPS_NAL))
	testing.expect(t, sps == nil)
	expect_bytes(t, pps, PPS_NAL)

	sps, pps = h264_param_sets(nil)
	testing.expect(t, sps == nil && pps == nil)

	// Parameter sets after a malformed length are not seen.
	sps, pps = h264_param_sets(cat([]byte{0, 0, 0, 99, 0x41}, avcc_of(SPS_NAL, PPS_NAL)))
	testing.expect(t, sps == nil && pps == nil)
}

@(test)
test_extract_param_sets :: proc(t: ^testing.T) {
	{
		data := avcc_of(AUD_NAL, SPS_NAL, SEI_NAL, PPS_NAL, IDR_NAL)
		out := h264_extract_param_sets(data)
		defer delete(out)
		expect_bytes(t, out, avcc_of(SPS_NAL, PPS_NAL))
		testing.expect(t, raw_data(out) != raw_data(data))
	}
	// Every SPS/PPS is kept, in order (not just the first).
	{
		sps2 := []byte{0x67, 0x64, 0x00}
		out := h264_extract_param_sets(avcc_of(SPS_NAL, PPS_NAL, SLICE_NAL, sps2))
		defer delete(out)
		expect_bytes(t, out, avcc_of(SPS_NAL, PPS_NAL, sps2))
	}
	// No parameter sets / nothing at all -> nil.
	testing.expect(t, h264_extract_param_sets(avcc_of(IDR_NAL, SLICE_NAL)) == nil)
	testing.expect(t, h264_extract_param_sets(nil) == nil)
	testing.expect(t, h264_extract_param_sets([]byte{1, 2, 3}) == nil)
	// Only one of them is still returned.
	{
		out := h264_extract_param_sets(avcc_of(SPS_NAL, IDR_NAL))
		defer delete(out)
		expect_bytes(t, out, avcc_of(SPS_NAL))
	}
}

// ---------------------------------------------------------------------------
// h264_prepare_for_webrtc
// ---------------------------------------------------------------------------

// The STAP-A NAL RFC 6184 5.7.1 wants for SPS + PPS, wrapped in a 4-byte AVCC length.
@(private = "file")
stap_a_avcc :: proc(sps, pps: []byte) -> []byte {
	body := make([dynamic]byte, context.temp_allocator)
	append(&body, 0x78)
	append(&body, u8(len(sps) >> 8), u8(len(sps)))
	append(&body, ..sps)
	append(&body, u8(len(pps) >> 8), u8(len(pps)))
	append(&body, ..pps)
	return avcc_of(body[:])
}

@(test)
test_prepare_keyframe_with_inband_param_sets :: proc(t: ^testing.T) {
	au := avcc_of(SPS_NAL, PPS_NAL, IDR_NAL)
	out, key := h264_prepare_for_webrtc(au, nil)
	defer delete(out)
	testing.expect(t, key, "IDR access unit is a keyframe")
	expect_bytes(t, out, cat(stap_a_avcc(SPS_NAL, PPS_NAL), avcc_of(IDR_NAL)))

	// Explicitly check the STAP-A framing.
	it := avcc_iterator(out)
	first, ok := avcc_next(&it)
	testing.expect(t, ok)
	testing.expect_value(t, first[0], u8(0x78))
	testing.expect_value(t, nal_type(first), u8(NAL_STAP_A))
	testing.expect_value(t, len(first), 1 + 2 + len(SPS_NAL) + 2 + len(PPS_NAL))
	testing.expect_value(t, int(first[1]) << 8 | int(first[2]), len(SPS_NAL))
	testing.expect_value(t, int(first[3 + len(SPS_NAL)]) << 8 | int(first[4 + len(SPS_NAL)]), len(PPS_NAL))
	// Exactly two NALs: STAP-A and IDR.
	_, ok = avcc_next(&it)
	testing.expect(t, ok)
	_, ok = avcc_next(&it)
	testing.expect(t, !ok)
	testing.expect(t, avcc_is_valid(out))
}

@(test)
test_prepare_keyframe_param_sets_not_duplicated :: proc(t: ^testing.T) {
	// The in-band SPS/PPS only appear inside the STAP-A, never as separate NALs.
	au := avcc_of(AUD_NAL, SEI_NAL, SPS_NAL, PPS_NAL, IDR_NAL)
	out, key := h264_prepare_for_webrtc(au, nil)
	defer delete(out)
	testing.expect(t, key)
	count_sps, count_pps, count_stap, count_other := 0, 0, 0, 0
	it := avcc_iterator(out)
	for nal in avcc_next(&it) {
		switch nal_type(nal) {
		case NAL_SPS:     count_sps += 1
		case NAL_PPS:     count_pps += 1
		case NAL_STAP_A:  count_stap += 1
		case NAL_SLICE_IDR:
		case:             count_other += 1
		}
	}
	testing.expect_value(t, count_sps, 0)
	testing.expect_value(t, count_pps, 0)
	testing.expect_value(t, count_stap, 1)
	testing.expect_value(t, count_other, 0)
}

@(test)
test_prepare_keyframe_uses_headers :: proc(t: ^testing.T) {
	hdr_sps := []byte{0x67, 0x64, 0x00, 0x28, 0xac}
	hdr_pps := []byte{0x68, 0xee, 0x3c}
	headers := avcc_of(hdr_sps, hdr_pps)
	out, key := h264_prepare_for_webrtc(avcc_of(IDR_NAL), headers)
	defer delete(out)
	testing.expect(t, key)
	expect_bytes(t, out, cat(stap_a_avcc(hdr_sps, hdr_pps), avcc_of(IDR_NAL)))
}

@(test)
test_prepare_keyframe_inband_wins_over_headers :: proc(t: ^testing.T) {
	headers := avcc_of([]byte{0x67, 0x64, 0x00, 0x28, 0xac}, []byte{0x68, 0xee, 0x3c})
	out, key := h264_prepare_for_webrtc(avcc_of(SPS_NAL, PPS_NAL, IDR_NAL), headers)
	defer delete(out)
	testing.expect(t, key)
	expect_bytes(t, out, cat(stap_a_avcc(SPS_NAL, PPS_NAL), avcc_of(IDR_NAL)))
}

@(test)
test_prepare_keyframe_partial_inband_falls_back_to_headers :: proc(t: ^testing.T) {
	// SPS in-band but no PPS: take both from the headers so they stay consistent.
	hdr_sps := []byte{0x67, 0x64, 0x00, 0x28, 0xac}
	hdr_pps := []byte{0x68, 0xee, 0x3c}
	out, key := h264_prepare_for_webrtc(avcc_of(SPS_NAL, IDR_NAL), avcc_of(hdr_sps, hdr_pps))
	defer delete(out)
	testing.expect(t, key)
	expect_bytes(t, out, cat(stap_a_avcc(hdr_sps, hdr_pps), avcc_of(IDR_NAL)))
}

@(test)
test_prepare_keyframe_without_any_param_sets :: proc(t: ^testing.T) {
	out, key := h264_prepare_for_webrtc(avcc_of(IDR_NAL), nil)
	defer delete(out)
	testing.expect(t, key)
	expect_bytes(t, out, avcc_of(IDR_NAL))

	// Headers without both SPS and PPS don't help either.
	out2, key2 := h264_prepare_for_webrtc(avcc_of(IDR_NAL), avcc_of(SPS_NAL))
	defer delete(out2)
	testing.expect(t, key2)
	expect_bytes(t, out2, avcc_of(IDR_NAL))
}

@(test)
test_prepare_non_keyframe_keeps_only_slices :: proc(t: ^testing.T) {
	au := avcc_of(AUD_NAL, SEI_NAL, SPS_NAL, PPS_NAL, FILLER_NAL, SLICE_NAL)
	headers := avcc_of(SPS_NAL, PPS_NAL)
	out, key := h264_prepare_for_webrtc(au, headers)
	defer delete(out)
	testing.expect(t, !key, "non-IDR slices are not keyframes")
	expect_bytes(t, out, avcc_of(SLICE_NAL), "no STAP-A on delta frames, SPS/PPS/SEI/AUD/filler dropped")
}

@(test)
test_prepare_keeps_multiple_slices_in_order :: proc(t: ^testing.T) {
	{
		out, key := h264_prepare_for_webrtc(avcc_of(SLICE_NAL, SLICE2_NAL, SLICE_NAL), nil)
		defer delete(out)
		testing.expect(t, !key)
		expect_bytes(t, out, avcc_of(SLICE_NAL, SLICE2_NAL, SLICE_NAL))
	}
	{
		au := avcc_of(SPS_NAL, PPS_NAL, IDR_NAL, IDR2_NAL, SEI_NAL, IDR_NAL)
		out, key := h264_prepare_for_webrtc(au, nil)
		defer delete(out)
		testing.expect(t, key)
		expect_bytes(t, out, cat(stap_a_avcc(SPS_NAL, PPS_NAL), avcc_of(IDR_NAL, IDR2_NAL, IDR_NAL)))
	}
}

@(test)
test_prepare_is_keyframe_only_for_idr :: proc(t: ^testing.T) {
	for typ in u8(1) ..= 23 {
		nal := []byte{typ | 0x60, 0x80, 0x01}
		if typ == NAL_SPS || typ == NAL_PPS || typ == NAL_SEI || typ == NAL_AUD || typ == NAL_FILLER {
			continue // those are dropped, nothing to report
		}
		out, key := h264_prepare_for_webrtc(avcc_of(nal), nil)
		testing.expectf(t, key == (typ == NAL_SLICE_IDR), "NAL type %d: is_keyframe=%v", typ, key)
		testing.expectf(t, out != nil, "NAL type %d must be forwarded", typ)
		delete(out)
	}
}

@(test)
test_prepare_empty_and_droppable_only :: proc(t: ^testing.T) {
	out, key := h264_prepare_for_webrtc(nil, nil)
	testing.expect(t, out == nil && !key)

	out, key = h264_prepare_for_webrtc(avcc_of(AUD_NAL, SEI_NAL), nil)
	testing.expect(t, out == nil && !key)

	// Only parameter sets: nothing to send.
	out, key = h264_prepare_for_webrtc(avcc_of(SPS_NAL, PPS_NAL), nil)
	testing.expect(t, out == nil && !key)

	// Garbage that is not AVCC.
	out, key = h264_prepare_for_webrtc([]byte{0, 0, 0, 0, 1, 2, 3}, nil)
	testing.expect(t, out == nil && !key)
}

@(test)
test_prepare_large_nal :: proc(t: ^testing.T) {
	big := big_nal(0x65, 70000)
	out, key := h264_prepare_for_webrtc(avcc_of(SPS_NAL, PPS_NAL, big), nil)
	defer delete(out)
	testing.expect(t, key)
	expect_bytes(t, out, cat(stap_a_avcc(SPS_NAL, PPS_NAL), avcc_of(big)))
}

// ---------------------------------------------------------------------------
// sprop-parameter-sets, levels, fmtp
// ---------------------------------------------------------------------------

@(test)
test_sprop_parameter_sets :: proc(t: ^testing.T) {
	headers := avcc_of(SPS_NAL, PPS_NAL)
	s := h264_sprop_parameter_sets(headers)
	defer delete(s)
	// base64(67 42 e0 1f aa bb) , base64(68 ce 3c 80)
	testing.expect_value(t, s, "Z0LgH6q7,aM48gA==")

	// Padding variants.
	s2 := h264_sprop_parameter_sets(avcc_of([]byte{0x67, 0x42, 0xe0}, []byte{0x68, 0xce}))
	defer delete(s2)
	testing.expect_value(t, s2, "Z0Lg,aM4=")

	// Order in the buffer does not matter.
	s3 := h264_sprop_parameter_sets(avcc_of(PPS_NAL, SLICE_NAL, SPS_NAL))
	defer delete(s3)
	testing.expect_value(t, s3, "Z0LgH6q7,aM48gA==")
}

@(test)
test_sprop_parameter_sets_unavailable :: proc(t: ^testing.T) {
	testing.expect_value(t, h264_sprop_parameter_sets(nil), "")
	testing.expect_value(t, h264_sprop_parameter_sets(avcc_of(SPS_NAL)), "")
	testing.expect_value(t, h264_sprop_parameter_sets(avcc_of(PPS_NAL)), "")
	testing.expect_value(t, h264_sprop_parameter_sets(avcc_of(IDR_NAL)), "")
}

Level_Case :: struct {
	w, h, fps: int,
	level:     string,
	idc:       u8,
	plid:      string,
}

// Expected levels derived from ITU-T H.264 Table A-1 (MaxMBPS / MaxFS):
//   3.1: 108000 / 3600   4.1: 245760 / 8192   4.2: 522240 / 8704
//   5.0: 589824 / 22080  5.1: 983040 / 36864  5.2: 2073600 / 36864
// Macroblocks per frame = ceil(w/16) * ceil(h/16).
//   1280x720  = 3600 MB  (@30 -> 108000)
//   1920x1080 = 8160 MB  (@30 -> 244800, @60 -> 489600)
//   2560x1440 = 14400 MB (@30 -> 432000, @60 -> 864000)
//   3840x2160 = 32400 MB (@30 -> 972000, @60 -> 1944000)
@(private = "file")
LEVEL_CASES := [?]Level_Case {
	{1280, 720, 30, "3.1", 31, "42e01f"},
	{1920, 1080, 30, "4.1", 41, "42e029"},
	{1920, 1080, 60, "4.2", 42, "42e02a"},
	{2560, 1440, 30, "5.0", 50, "42e032"},
	{2560, 1440, 60, "5.1", 51, "42e033"},
	{3840, 2160, 30, "5.1", 51, "42e033"},
	{3840, 2160, 60, "5.2", 52, "42e034"},
	// Small pictures and boundaries.
	{640, 480, 30, "3.1", 31, "42e01f"},
	{320, 240, 15, "3.1", 31, "42e01f"},
	{1280, 720, 24, "3.1", 31, "42e01f"},
	{1280, 720, 31, "4.1", 41, "42e029"}, // 3600*31 = 111600 > 108000
	{1280, 720, 60, "4.1", 41, "42e029"}, // 216000 <= 245760
	{1280, 721, 30, "4.1", 41, "42e029"}, // 3680 MB and 110400 MB/s: both limits exceeded
	{1280, 721, 24, "4.1", 41, "42e029"}, // 3680 MB > MaxFS 3600 although 88320 MB/s fits 3.1
	{1920, 1100, 24, "4.2", 42, "42e02a"}, // 8280 MB > MaxFS 8192 although 198720 MB/s fits 4.1
	{3840, 1920, 20, "5.1", 51, "42e033"}, // 28800 MB > MaxFS 22080 although 576000 MB/s fits 5.0
	{4096, 2304, 24, "5.1", 51, "42e033"}, // 36864 MB = MaxFS 5.1, 884736 MB/s
	{4096, 2320, 24, "5.2", 52, "42e034"}, // 37120 MB > MaxFS 36864
	{1366, 768, 30, "4.1", 41, "42e029"}, // 86*48 = 4128 MB
	{1920, 1200, 30, "5.0", 50, "42e032"}, // 120*75 = 9000 MB > MaxFS of 4.1/4.2
	{3440, 1440, 30, "5.0", 50, "42e032"}, // 215*90 = 19350 MB, 580500 <= 589824
	{3840, 2160, 120, "5.2", 52, "42e034"},
	{7680, 4320, 30, "5.2", 52, "42e034"}, // beyond the table: highest level
}

@(test)
test_pick_level_table :: proc(t: ^testing.T) {
	for c in LEVEL_CASES {
		want_level, want_idc, want_plid := c.level, c.idc, c.plid
		lvl := h264_pick_level(c.w, c.h, c.fps)
		testing.expectf(t, string(lvl.name) == want_level && lvl.idc == want_idc,
			"%dx%d@%d: got level %s (idc %d), want %s (idc %d)", c.w, c.h, c.fps, lvl.name, lvl.idc, want_level, want_idc)

		plid := h264_profile_level_id(c.w, c.h, c.fps)
		testing.expectf(t, string(plid[:]) == want_plid, "%dx%d@%d: profile-level-id %s, want %s", c.w, c.h, c.fps, string(plid[:]), want_plid)
	}
}

@(test)
test_pick_level_fps_zero_defaults_to_30 :: proc(t: ^testing.T) {
	testing.expect_value(t, h264_pick_level(1280, 720, 0).idc, u8(31))
	testing.expect_value(t, h264_pick_level(1920, 1080, 0).idc, u8(41))
	testing.expect_value(t, h264_pick_level(1920, 1080, -5).idc, u8(41))
	testing.expect_value(t, h264_pick_level(3840, 2160, 0).idc, u8(51))
}

@(test)
test_pick_level_degenerate_sizes :: proc(t: ^testing.T) {
	// Must not crash and must give the lowest level.
	testing.expect_value(t, h264_pick_level(0, 0, 30).idc, u8(31))
	testing.expect_value(t, h264_pick_level(1, 1, 30).idc, u8(31))
}

@(test)
test_pick_level_is_monotonic_in_fps :: proc(t: ^testing.T) {
	// A higher frame rate must never lower the level.
	sizes := [?][2]int{{640, 480}, {1280, 720}, {1920, 1080}, {2560, 1440}, {3840, 2160}}
	for sz in sizes {
		prev := u8(0)
		for fps in 1 ..= 240 {
			idc := h264_pick_level(sz[0], sz[1], fps).idc
			testing.expectf(t, idc >= prev, "%dx%d: level dropped from %d to %d at %d fps", sz[0], sz[1], prev, idc, fps)
			prev = idc
		}
	}
}

@(test)
test_profile_level_id_shape :: proc(t: ^testing.T) {
	plid := h264_profile_level_id(1280, 720, 30)
	testing.expect_value(t, string(plid[:]), "42e01f")
	// Lower-case hex only, always 6 chars: 42 e0 + two hex digits.
	for sz in ([?][3]int{{1280, 720, 30}, {1920, 1080, 30}, {1920, 1080, 60}, {3840, 2160, 60}}) {
		p := h264_profile_level_id(sz[0], sz[1], sz[2])
		for c in p {
			ok := (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')
			testing.expectf(t, ok, "non lower-case-hex byte %c in %s", c, string(p[:]))
		}
	}
}

@(test)
test_fmtp_with_headers :: proc(t: ^testing.T) {
	s := h264_fmtp(1280, 720, 30, avcc_of(SPS_NAL, PPS_NAL))
	defer delete(s)
	testing.expect_value(
		t,
		s,
		"level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f;sprop-parameter-sets=Z0LgH6q7,aM48gA==",
	)
}

@(test)
test_fmtp_without_headers :: proc(t: ^testing.T) {
	s := h264_fmtp(1920, 1080, 60, nil)
	defer delete(s)
	testing.expect_value(t, s, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e02a")

	// Headers lacking a PPS: sprop is omitted, not left dangling.
	s2 := h264_fmtp(1920, 1080, 30, avcc_of(SPS_NAL))
	defer delete(s2)
	testing.expect_value(t, s2, "level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e029")
}

@(test)
test_fmtp_allocator_is_honoured :: proc(t: ^testing.T) {
	// Returned string must live in the requested allocator: freeing the
	// temp-allocated result is a no-op, a default-allocated one would leak.
	s := h264_fmtp(1280, 720, 30, avcc_of(SPS_NAL, PPS_NAL), context.temp_allocator)
	testing.expect(t, len(s) > 0)
	s2 := h264_sprop_parameter_sets(avcc_of(SPS_NAL, PPS_NAL), context.temp_allocator)
	testing.expect(t, len(s2) > 0)
}

} // when ODIN_TEST
