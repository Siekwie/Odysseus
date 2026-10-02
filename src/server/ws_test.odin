package server

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

// Everything below only exists in `odin test` builds: the package directory is
// also built by a plain `odin build`, which must not compile (or break on) tests.
when ODIN_TEST {

// Unit tests for the WebSocket layer. The read side runs against a real
// loopback TCP connection: the "client" end of the pair writes hand-masked
// frames, the "server" end is handed to ws_read_text.

// ---------------------------------------------------------------------------
// Pure functions
// ---------------------------------------------------------------------------

@(test)
test_ws_accept_key_rfc6455_example :: proc(t: ^testing.T) {
	// RFC 6455 section 1.3.
	got := ws_accept_key("dGhlIHNhbXBsZSBub25jZQ==")
	defer delete(got)
	testing.expect_value(t, got, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

@(test)
test_ws_accept_key_trims_whitespace :: proc(t: ^testing.T) {
	got := ws_accept_key("  dGhlIHNhbXBsZSBub25jZQ==\t ")
	defer delete(got)
	testing.expect_value(t, got, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

@(test)
test_ws_accept_key_other_key :: proc(t: ^testing.T) {
	// Another well-known pair (Autobahn / many tutorials).
	got := ws_accept_key("x3JJHMbDL1EzLkh9GBhXDw==")
	defer delete(got)
	testing.expect_value(t, got, "HSmrc0sMlYUkAGmm5OPpG2HaGWk=")
}

@(test)
test_ws_accept_key_allocator :: proc(t: ^testing.T) {
	got := ws_accept_key("dGhlIHNhbXBsZSBub25jZQ==", context.temp_allocator)
	testing.expect_value(t, got, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
}

@(test)
test_ws_encode_header_lengths :: proc(t: ^testing.T) {
	hdr: [10]byte

	n := ws_encode_header(&hdr, WS_OP_TEXT, 0)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, hdr[0], u8(0x81))
	testing.expect_value(t, hdr[1], u8(0))

	n = ws_encode_header(&hdr, WS_OP_TEXT, 125)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, hdr[1], u8(125))

	n = ws_encode_header(&hdr, WS_OP_TEXT, 126)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, hdr[1], u8(126))
	testing.expect_value(t, hdr[2], u8(0))
	testing.expect_value(t, hdr[3], u8(126))

	n = ws_encode_header(&hdr, WS_OP_TEXT, 65535)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, hdr[1], u8(126))
	testing.expect_value(t, hdr[2], u8(0xFF))
	testing.expect_value(t, hdr[3], u8(0xFF))

	n = ws_encode_header(&hdr, WS_OP_TEXT, 65536)
	testing.expect_value(t, n, 10)
	testing.expect_value(t, hdr[1], u8(127))
	want := [8]byte{0, 0, 0, 0, 0, 1, 0, 0}
	for i in 0 ..< 8 {
		testing.expect_value(t, hdr[2 + i], want[i])
	}

	n = ws_encode_header(&hdr, WS_OP_TEXT, 0x1_0000_0001)
	testing.expect_value(t, n, 10)
	want2 := [8]byte{0, 0, 0, 1, 0, 0, 0, 1}
	for i in 0 ..< 8 {
		testing.expect_value(t, hdr[2 + i], want2[i])
	}
}

@(test)
test_ws_encode_header_opcodes :: proc(t: ^testing.T) {
	hdr: [10]byte
	ws_encode_header(&hdr, WS_OP_PING, 0)
	testing.expect_value(t, hdr[0], u8(0x89))
	ws_encode_header(&hdr, WS_OP_PONG, 3)
	testing.expect_value(t, hdr[0], u8(0x8A))
	ws_encode_header(&hdr, WS_OP_CLOSE, 0)
	testing.expect_value(t, hdr[0], u8(0x88))
	ws_encode_header(&hdr, WS_OP_BINARY, 0)
	testing.expect_value(t, hdr[0], u8(0x82))
	// Server frames are never masked: bit 7 of byte 1 stays clear.
	ws_encode_header(&hdr, WS_OP_TEXT, 100000)
	testing.expect_value(t, hdr[1] & 0x80, u8(0))
}

// ---------------------------------------------------------------------------
// Loopback fixture
// ---------------------------------------------------------------------------

@(private = "file")
Pair :: struct {
	listener: net.TCP_Socket,
	server:   net.TCP_Socket, // handed to ws_read_text / ws_write_*
	client:   net.TCP_Socket, // plays the browser
	buf:      [dynamic]byte,
	frame:    [dynamic]byte,
	mu:       sync.Mutex,
}

@(private = "file")
pair_open :: proc(t: ^testing.T, p: ^Pair) -> bool {
	testing.set_fail_timeout(t, 30 * time.Second)

	l, lerr := net.listen_tcp({address = net.IP4_Loopback, port = 0})
	if !testing.expectf(t, lerr == nil, "listen_tcp: %v", lerr) {
		return false
	}
	p.listener = l
	ep, eerr := net.bound_endpoint(l)
	if !testing.expectf(t, eerr == nil && ep.port != 0, "bound_endpoint: %v port=%d", eerr, ep.port) {
		net.close(l)
		return false
	}
	c, cerr := net.dial_tcp_from_endpoint({address = net.IP4_Loopback, port = ep.port})
	if !testing.expectf(t, cerr == nil, "dial_tcp: %v", cerr) {
		net.close(l)
		return false
	}
	p.client = c
	s, _, aerr := net.accept_tcp(l)
	if !testing.expectf(t, aerr == nil, "accept_tcp: %v", aerr) {
		net.close(c)
		net.close(l)
		return false
	}
	p.server = s
	// A buggy server must not hang the suite: reads give up quickly.
	net.set_option(p.server, .Receive_Timeout, 1 * time.Second)
	net.set_option(p.client, .Receive_Timeout, 2 * time.Second)
	net.set_option(p.client, .Send_Timeout, 5 * time.Second)
	return true
}

@(private = "file")
pair_close :: proc(p: ^Pair) {
	net.close(p.client)
	net.close(p.server)
	net.close(p.listener)
	delete(p.buf)
	delete(p.frame)
}

@(private = "file")
read_msg :: proc(p: ^Pair) -> Ws_Read {
	return ws_read_text(p.server, &p.buf, &p.frame, &p.mu)
}

@(private = "file")
send_all :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

DEFAULT_MASK :: [4]byte{0x37, 0xfa, 0x21, 0x3d}

// Builds one client-to-server frame. len_enc: 0 = minimal encoding, 16 or 64
// forces that many length bits (RFC 6455 allows any receiver to see the
// non-minimal form only as a protocol error, but this parser accepts it).
@(private = "file")
build_frame :: proc(
	opcode: byte,
	payload: []byte,
	fin := true,
	masked := true,
	mask := DEFAULT_MASK,
	len_enc := 0,
	rsv: byte = 0,
	allocator := context.allocator,
) -> []byte {
	out := make([dynamic]byte, allocator)
	b0 := opcode | rsv
	if fin {
		b0 |= 0x80
	}
	append(&out, b0)
	n := len(payload)
	mbit: byte = 0x80 if masked else 0
	switch {
	case len_enc == 16 || (len_enc == 0 && n > 125 && n <= 0xFFFF):
		append(&out, mbit | 126, u8(n >> 8), u8(n))
	case len_enc == 64 || (len_enc == 0 && n > 0xFFFF):
		append(&out, mbit | 127)
		for i in 0 ..< 8 {
			append(&out, u8(u64(n) >> uint(56 - 8 * i)))
		}
	case:
		append(&out, mbit | u8(n))
	}
	if masked {
		m := mask
		append(&out, ..m[:])
		for b, i in payload {
			append(&out, b ~ mask[i & 3])
		}
	} else {
		append(&out, ..payload)
	}
	return out[:]
}

@(private = "file")
text_frame :: proc(s: string, fin := true) -> []byte {
	return build_frame(WS_OP_TEXT, transmute([]byte)s, fin, allocator = context.temp_allocator)
}

@(private = "file")
cont_frame :: proc(s: string, fin := true) -> []byte {
	return build_frame(WS_OP_CONTINUATION, transmute([]byte)s, fin, allocator = context.temp_allocator)
}

@(private = "file")
client_send :: proc(t: ^testing.T, p: ^Pair, frames: ..[]byte, loc := #caller_location) {
	for f in frames {
		testing.expect(t, send_all(p.client, f), "client send failed", loc = loc)
	}
}

// Reads exactly n bytes from the client socket (the server's replies).
@(private = "file")
client_recv :: proc(p: ^Pair, n: int) -> (data: []byte, ok: bool) {
	data = make([]byte, n, context.temp_allocator)
	got := 0
	for got < n {
		m, err := net.recv_tcp(p.client, data[got:])
		if err != nil || m <= 0 {
			return nil, false
		}
		got += m
	}
	return data, true
}

// Parses one unmasked server frame.
@(private = "file")
client_read_frame :: proc(p: ^Pair) -> (opcode: byte, payload: []byte, ok: bool) {
	hdr := client_recv(p, 2) or_return
	opcode = hdr[0] & 0x0F
	if hdr[0] & 0x80 == 0 || hdr[1] & 0x80 != 0 {
		return opcode, nil, false // server frames must be final and unmasked
	}
	n := int(hdr[1] & 0x7F)
	if n == 126 {
		ext := client_recv(p, 2) or_return
		n = int(ext[0]) << 8 | int(ext[1])
	} else if n == 127 {
		ext := client_recv(p, 8) or_return
		n = 0
		for b in ext {
			n = n << 8 | int(b)
		}
	}
	payload = client_recv(p, n) or_return
	return opcode, payload, true
}

// After a protocol violation the server end is expected to be dropped; the
// helper to check "nothing else was written to the client" is not needed, only the result.

// A protocol violation must be rejected from the bytes already received, not by
// running into the receive timeout (1 s by default, see pair_open).
@(private = "file")
expect_closed :: proc(t: ^testing.T, p: ^Pair, loc := #caller_location) {
	started := time.now()
	r := read_msg(p)
	testing.expect_value(t, r, Ws_Read.Closed, loc = loc)
	testing.expectf(t, time.since(started) < 500 * time.Millisecond, "rejection took %v: it waited for the receive timeout", time.since(started), loc = loc)
}

@(private = "file")
expect_message :: proc(t: ^testing.T, p: ^Pair, want: string, loc := #caller_location) {
	r := read_msg(p)
	testing.expect_value(t, r, Ws_Read.Message, loc = loc)
	testing.expect_value(t, string(p.buf[:]), want, loc = loc)
}

// ---------------------------------------------------------------------------
// ws_read_text: messages
// ---------------------------------------------------------------------------

@(test)
test_ws_read_rfc_masked_hello :: proc(t: ^testing.T) {
	// RFC 6455 section 5.7: a single-frame masked text message "Hello".
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, []byte{0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58})
	expect_message(t, &p, "Hello")
}

@(test)
test_ws_read_single_text_frame :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame(`{"type":"offer","sdp":"v=0"}`))
	expect_message(t, &p, `{"type":"offer","sdp":"v=0"}`)
}

@(test)
test_ws_read_empty_text_frame :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame(""))
	expect_message(t, &p, "")
}

@(test)
test_ws_read_all_mask_bytes_used :: proc(t: ^testing.T) {
	// 11 bytes: the mask repeats and its fourth byte is used.
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	msg := "0123456789a"
	client_send(t, &p, build_frame(WS_OP_TEXT, transmute([]byte)msg, mask = {0x01, 0x02, 0x04, 0x08}, allocator = context.temp_allocator))
	expect_message(t, &p, msg)
}

@(test)
test_ws_read_zero_mask :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	msg := "plain"
	client_send(t, &p, build_frame(WS_OP_TEXT, transmute([]byte)msg, mask = {0, 0, 0, 0}, allocator = context.temp_allocator))
	expect_message(t, &p, msg)
}

@(test)
test_ws_read_two_messages_back_to_back :: proc(t: ^testing.T) {
	// Both frames arrive in one TCP segment; the buffer is reset per message.
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	both := make([dynamic]byte, context.temp_allocator)
	append(&both, ..text_frame("first message"))
	append(&both, ..text_frame("second"))
	client_send(t, &p, both[:])
	expect_message(t, &p, "first message")
	expect_message(t, &p, "second")
}

@(test)
test_ws_read_bytewise_delivery :: proc(t: ^testing.T) {
	// The frame trickles in one byte at a time (recv_exact must loop).
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	f := build_frame(WS_OP_TEXT, transmute([]byte)string("slow but steady"), allocator = context.temp_allocator)
	for i in 0 ..< len(f) {
		client_send(t, &p, f[i:i + 1])
		time.sleep(2 * time.Millisecond)
	}
	expect_message(t, &p, "slow but steady")
}

@(test)
test_ws_read_16bit_length :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	for size in ([]int{126, 300, 1000, 20000}) {
		payload, _ := strings.repeat("x", size, context.temp_allocator)
		client_send(t, &p, text_frame(payload))
		expect_message(t, &p, payload)
	}
}

@(test)
test_ws_read_boundary_lengths :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	for size in ([]int{124, 125, 126, 127}) {
		payload, _ := strings.repeat("y", size, context.temp_allocator)
		client_send(t, &p, text_frame(payload))
		expect_message(t, &p, payload)
	}
}

@(test)
test_ws_read_forced_16bit_length_for_short_payload :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	msg := "short"
	client_send(t, &p, build_frame(WS_OP_TEXT, transmute([]byte)msg, len_enc = 16, allocator = context.temp_allocator))
	expect_message(t, &p, msg)
}

@(test)
test_ws_read_64bit_length :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	// Small payload in a 64-bit length field, and a payload just above 64 KiB.
	msg := "tiny"
	client_send(t, &p, build_frame(WS_OP_TEXT, transmute([]byte)msg, len_enc = 64, allocator = context.temp_allocator))
	expect_message(t, &p, msg)

	big, _ := strings.repeat("z", 70000, context.temp_allocator)
	frame := build_frame(WS_OP_TEXT, transmute([]byte)big)
	defer delete(frame)
	th := thread.create_and_start_with_poly_data2(p.client, frame, proc(s: net.TCP_Socket, d: []byte) {
		send_all(s, d)
	})
	r := read_msg(&p)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, r, Ws_Read.Message)
	testing.expect_value(t, len(p.buf), 70000)
	testing.expect_value(t, string(p.buf[:]), big)
}

@(test)
test_ws_read_max_payload_accepted :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	big := make([]byte, WS_MAX_PAYLOAD)
	defer delete(big)
	for i in 0 ..< len(big) {
		big[i] = 'a' + u8(i % 26)
	}
	frame := build_frame(WS_OP_TEXT, big)
	defer delete(frame)
	th := thread.create_and_start_with_poly_data2(p.client, frame, proc(s: net.TCP_Socket, d: []byte) {
		send_all(s, d)
	})
	net.set_option(p.server, .Receive_Timeout, 5 * time.Second)
	r := read_msg(&p)
	net.close(p.server) // unblocks the sender if the read failed early
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, r, Ws_Read.Message)
	testing.expect_value(t, len(p.buf), WS_MAX_PAYLOAD)
}

// ---------------------------------------------------------------------------
// ws_read_text: fragmentation
// ---------------------------------------------------------------------------

@(test)
test_ws_read_fragmented_message :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame("Hel", fin = false), cont_frame("lo, ", fin = false), cont_frame("world"))
	expect_message(t, &p, "Hello, world")
}

@(test)
test_ws_read_fragmented_two_frames :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame("ab", fin = false), cont_frame("cd"))
	expect_message(t, &p, "abcd")
	// Followed by an ordinary message.
	client_send(t, &p, text_frame("next"))
	expect_message(t, &p, "next")
}

@(test)
test_ws_read_fragmented_with_empty_fragments :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame("", fin = false), cont_frame("", fin = false), cont_frame("x", fin = false), cont_frame(""))
	expect_message(t, &p, "x")
}

@(test)
test_ws_read_ping_in_the_middle_of_fragments :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	ping := build_frame(WS_OP_PING, transmute([]byte)string("pp-payload"), allocator = context.temp_allocator)
	client_send(t, &p, text_frame("abc", fin = false), ping, cont_frame("def"))
	expect_message(t, &p, "abcdef")

	op, payload, ok := client_read_frame(&p)
	testing.expect(t, ok, "expected a pong")
	testing.expect_value(t, op, byte(WS_OP_PONG))
	testing.expect_value(t, string(payload), "pp-payload")
}

@(test)
test_ws_read_ping_before_message :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	ping := build_frame(WS_OP_PING, transmute([]byte)string("hi"), allocator = context.temp_allocator)
	client_send(t, &p, ping, text_frame("after ping"))
	expect_message(t, &p, "after ping")

	op, payload, ok := client_read_frame(&p)
	testing.expect(t, ok)
	testing.expect_value(t, op, byte(WS_OP_PONG))
	testing.expect_value(t, string(payload), "hi")
}

@(test)
test_ws_read_empty_ping :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, build_frame(WS_OP_PING, nil, allocator = context.temp_allocator), text_frame("x"))
	expect_message(t, &p, "x")
	op, payload, ok := client_read_frame(&p)
	testing.expect(t, ok)
	testing.expect_value(t, op, byte(WS_OP_PONG))
	testing.expect_value(t, len(payload), 0)
}

@(test)
test_ws_read_ping_with_125_byte_payload :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	body, _ := strings.repeat("p", 125, context.temp_allocator)
	client_send(t, &p, build_frame(WS_OP_PING, transmute([]byte)body, allocator = context.temp_allocator), text_frame("x"))
	expect_message(t, &p, "x")
	op, payload, ok := client_read_frame(&p)
	testing.expect(t, ok)
	testing.expect_value(t, op, byte(WS_OP_PONG))
	testing.expect_value(t, string(payload), body)
}

@(test)
test_ws_read_several_pings_get_several_pongs :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	pa := build_frame(WS_OP_PING, transmute([]byte)string("one"), allocator = context.temp_allocator)
	pb := build_frame(WS_OP_PING, transmute([]byte)string("two"), allocator = context.temp_allocator)
	client_send(t, &p, pa, pb, text_frame("go"))
	expect_message(t, &p, "go")
	for want in ([]string{"one", "two"}) {
		op, payload, ok := client_read_frame(&p)
		testing.expect(t, ok)
		testing.expect_value(t, op, byte(WS_OP_PONG))
		testing.expect_value(t, string(payload), want)
	}
}

@(test)
test_ws_read_pong_does_not_disturb_fragments :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	pong := build_frame(WS_OP_PONG, nil, allocator = context.temp_allocator)
	client_send(t, &p, text_frame("a", fin = false), pong, cont_frame("b"))
	expect_message(t, &p, "ab")
}

@(test)
test_ws_read_unsolicited_pong_reports_empty_message :: proc(t: ^testing.T) {
	// Documented: a pong between messages is surfaced as an empty Message so
	// that the caller can reset its idle counter.
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, build_frame(WS_OP_PONG, transmute([]byte)string("x"), allocator = context.temp_allocator))
	expect_message(t, &p, "")
}

@(test)
test_ws_read_fragmented_message_exceeding_limit_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	half := make([]byte, WS_MAX_PAYLOAD / 2 + 10)
	defer delete(half)
	for i in 0 ..< len(half) {
		half[i] = 'q'
	}
	f1 := build_frame(WS_OP_TEXT, half, fin = false)
	f2 := build_frame(WS_OP_CONTINUATION, half, fin = true)
	defer delete(f1)
	defer delete(f2)
	both := make([]byte, len(f1) + len(f2))
	defer delete(both)
	copy(both, f1)
	copy(both[len(f1):], f2)
	th := thread.create_and_start_with_poly_data2(p.client, both, proc(s: net.TCP_Socket, d: []byte) {
		send_all(s, d)
	})
	net.set_option(p.server, .Receive_Timeout, 5 * time.Second)
	r := read_msg(&p)
	net.close(p.server)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, r, Ws_Read.Closed)
}

// ---------------------------------------------------------------------------
// ws_read_text: close and protocol errors
// ---------------------------------------------------------------------------

@(test)
test_ws_read_close_frame :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	// Close with status 1000 and a reason.
	body := []byte{0x03, 0xe8, 'b', 'y', 'e'}
	client_send(t, &p, build_frame(WS_OP_CLOSE, body, allocator = context.temp_allocator))
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)

	op, _, ok := client_read_frame(&p)
	testing.expect(t, ok, "server must answer a close frame")
	testing.expect_value(t, op, byte(WS_OP_CLOSE))
}

@(test)
test_ws_read_close_frame_without_payload :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, build_frame(WS_OP_CLOSE, nil, allocator = context.temp_allocator))
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
	op, _, ok := client_read_frame(&p)
	testing.expect(t, ok)
	testing.expect_value(t, op, byte(WS_OP_CLOSE))
}

@(test)
test_ws_read_close_in_the_middle_of_fragments :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame("part", fin = false), build_frame(WS_OP_CLOSE, nil, allocator = context.temp_allocator))
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
}

@(test)
test_ws_read_message_before_close_is_delivered :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame("last words"), build_frame(WS_OP_CLOSE, nil, allocator = context.temp_allocator))
	expect_message(t, &p, "last words")
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
}

@(test)
test_ws_read_unmasked_frame_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	// Padding after the frame: a server that ignored the MASK bit would read 4
	// of these bytes as a mask and find a complete message.
	client_send(t, &p, build_frame(WS_OP_TEXT, transmute([]byte)string("hello"), masked = false, allocator = context.temp_allocator), []byte{0, 0, 0, 0, 0, 0, 0, 0, 0})
	expect_closed(t, &p)
}

@(test)
test_ws_read_unmasked_control_frame_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, build_frame(WS_OP_PING, nil, masked = false, allocator = context.temp_allocator), []byte{0, 0, 0, 0, 0})
	expect_closed(t, &p)
}

@(test)
test_ws_read_oversized_length_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	// Header claims WS_MAX_PAYLOAD + 1 bytes; no payload follows. Must be
	// rejected from the header alone, without waiting for (or allocating) it.
	n := WS_MAX_PAYLOAD + 1
	hdr := []byte{0x81, 0x80 | 127, 0, 0, 0, 0, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n), 1, 2, 3, 4}
	client_send(t, &p, hdr)
	started := time.now()
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
	testing.expect(t, time.since(started) < 250 * time.Millisecond, "rejection must not wait for the receive timeout")
	testing.expect(t, cap(p.frame) < WS_MAX_PAYLOAD, "must not allocate the claimed payload size")
}

@(test)
test_ws_read_huge_64bit_length_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	// 2^63 + 5: negative if mis-read as i64, absurd either way.
	hdr := []byte{0x81, 0x80 | 127, 0x80, 0, 0, 0, 0, 0, 0, 5, 1, 2, 3, 4}
	client_send(t, &p, hdr)
	expect_closed(t, &p)
}

@(test)
test_ws_read_max_u64_length_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	hdr := []byte{0x81, 0x80 | 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1, 2, 3, 4}
	client_send(t, &p, hdr)
	expect_closed(t, &p)
}

@(test)
test_ws_read_binary_opcode_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, build_frame(WS_OP_BINARY, []byte{1, 2, 3}, allocator = context.temp_allocator))
	expect_closed(t, &p)
}

@(test)
test_ws_read_reserved_opcodes_are_closed :: proc(t: ^testing.T) {
	for op in ([]byte{0x3, 0x4, 0x5, 0x6, 0x7, 0xB, 0xC, 0xD, 0xE, 0xF}) {
		p: Pair
		if !pair_open(t, &p) {
			return
		}
		client_send(t, &p, build_frame(op, []byte{1}, allocator = context.temp_allocator))
		started := time.now()
		r := read_msg(&p)
		testing.expectf(t, r == .Closed && time.since(started) < 500 * time.Millisecond, "reserved opcode 0x%x gave %v after %v", op, r, time.since(started))
		pair_close(&p)
	}
}

@(test)
test_ws_read_continuation_without_start_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, cont_frame("orphan"))
	expect_closed(t, &p)
}

@(test)
test_ws_read_continuation_after_complete_message_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame("complete"), cont_frame("extra"))
	expect_message(t, &p, "complete")
	expect_closed(t, &p)
}

@(test)
test_ws_read_new_text_inside_fragmented_message_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, text_frame("first", fin = false), text_frame("second"))
	expect_closed(t, &p)
}

@(test)
test_ws_read_rsv_bits_are_closed :: proc(t: ^testing.T) {
	for rsv in ([]byte{0x40, 0x20, 0x10, 0x70}) {
		p: Pair
		if !pair_open(t, &p) {
			return
		}
		client_send(t, &p, build_frame(WS_OP_TEXT, transmute([]byte)string("x"), rsv = rsv, allocator = context.temp_allocator))
		started := time.now()
		r := read_msg(&p)
		testing.expectf(t, r == .Closed && time.since(started) < 500 * time.Millisecond, "RSV bits 0x%x gave %v after %v", rsv, r, time.since(started))
		pair_close(&p)
	}
}

@(test)
test_ws_read_control_frame_too_long_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	body, _ := strings.repeat("p", 126, context.temp_allocator)
	client_send(t, &p, build_frame(WS_OP_PING, transmute([]byte)body, allocator = context.temp_allocator))
	expect_closed(t, &p)
}

@(test)
test_ws_read_fragmented_control_frame_is_closed :: proc(t: ^testing.T) {
	for op in ([]byte{WS_OP_PING, WS_OP_PONG, WS_OP_CLOSE}) {
		p: Pair
		if !pair_open(t, &p) {
			return
		}
		client_send(t, &p, build_frame(op, nil, fin = false, allocator = context.temp_allocator))
		started := time.now()
		r := read_msg(&p)
		testing.expectf(t, r == .Closed && time.since(started) < 500 * time.Millisecond, "non-final control opcode 0x%x gave %v after %v", op, r, time.since(started))
		pair_close(&p)
	}
}

// ---------------------------------------------------------------------------
// ws_read_text: timeouts and dead peers
// ---------------------------------------------------------------------------

@(test)
test_ws_read_idle_when_no_data :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)
	net.set_option(p.server, .Receive_Timeout, 100 * time.Millisecond)

	testing.expect_value(t, read_msg(&p), Ws_Read.Idle)
	// Still usable afterwards.
	client_send(t, &p, text_frame("still here"))
	expect_message(t, &p, "still here")
}

@(test)
test_ws_read_timeout_between_fragments_is_closed :: proc(t: ^testing.T) {
	// A message started but never finished: no idle grace once it has begun.
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)
	net.set_option(p.server, .Receive_Timeout, 100 * time.Millisecond)

	client_send(t, &p, text_frame("half", fin = false))
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
}

@(test)
test_ws_read_timeout_inside_a_frame_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)
	net.set_option(p.server, .Receive_Timeout, 100 * time.Millisecond)

	// Header says 10 bytes, only the mask and 3 payload bytes arrive.
	client_send(t, &p, []byte{0x81, 0x80 | 10, 1, 2, 3, 4, 'a', 'b', 'c'})
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
}

@(test)
test_ws_read_timeout_after_first_header_byte_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)
	net.set_option(p.server, .Receive_Timeout, 100 * time.Millisecond)

	client_send(t, &p, []byte{0x81})
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
}

@(test)
test_ws_read_peer_disconnect_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	net.shutdown(p.client, .Send)
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
}

@(test)
test_ws_read_peer_disconnect_mid_frame_is_closed :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	client_send(t, &p, []byte{0x81, 0x80 | 20, 1, 2, 3, 4, 'a'})
	net.shutdown(p.client, .Send)
	testing.expect_value(t, read_msg(&p), Ws_Read.Closed)
}

// ---------------------------------------------------------------------------
// Write side
// ---------------------------------------------------------------------------

@(test)
test_ws_write_text_roundtrip :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	testing.expect(t, ws_write_text(p.server, `{"type":"answer"}`))
	op, payload, ok := client_read_frame(&p)
	testing.expect(t, ok)
	testing.expect_value(t, op, byte(WS_OP_TEXT))
	testing.expect_value(t, string(payload), `{"type":"answer"}`)
}

@(test)
test_ws_write_text_sizes :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	for size in ([]int{0, 1, 125, 126, 1000, 30000}) {
		body, _ := strings.repeat("w", size, context.temp_allocator)
		testing.expect(t, ws_write_text(p.server, body))
		op, payload, ok := client_read_frame(&p)
		testing.expectf(t, ok && op == WS_OP_TEXT && string(payload) == body, "size %d did not round-trip", size)
	}
}

@(test)
test_ws_write_ping_and_close_frames :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	testing.expect(t, ws_write_frame(p.server, WS_OP_PING, nil))
	op, payload, ok := client_read_frame(&p)
	testing.expect(t, ok)
	testing.expect_value(t, op, byte(WS_OP_PING))
	testing.expect_value(t, len(payload), 0)

	testing.expect(t, ws_write_frame(p.server, WS_OP_CLOSE, nil))
	op, _, ok = client_read_frame(&p)
	testing.expect(t, ok)
	testing.expect_value(t, op, byte(WS_OP_CLOSE))
}

@(test)
test_ws_write_to_closed_peer_reports_failure :: proc(t: ^testing.T) {
	p: Pair
	if !pair_open(t, &p) {
		return
	}
	defer pair_close(&p)

	net.close(p.client)
	// Writing to a reset connection fails eventually (the first write after
	// the peer closed may still be accepted by the kernel).
	failed := false
	for _ in 0 ..< 50 {
		if !ws_write_text(p.server, "are you there?") {
			failed = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, failed, "writes to a closed peer must eventually return false")
}

} // when ODIN_TEST
