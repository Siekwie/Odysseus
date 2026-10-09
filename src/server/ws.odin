package server

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:net"
import "core:strings"
import "core:sync"

import "../utils"

// Minimal RFC 6455 server side: text messages, fragmentation, ping/pong, close.

WS_MAGIC       :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_MAX_PAYLOAD :: 256 << 10 // an SDP offer is a few kilobytes

WS_OP_CONTINUATION :: 0x0
WS_OP_TEXT         :: 0x1
WS_OP_BINARY       :: 0x2
WS_OP_CLOSE        :: 0x8
WS_OP_PING         :: 0x9
WS_OP_PONG         :: 0xA

Ws_Read :: enum {
	Message, // a complete text message is in the buffer
	Idle,    // the receive timeout elapsed with no data
	Closed,  // peer closed, protocol error or socket error
}

// ws_accept_key computes the Sec-WebSocket-Accept value; the result is owned by the caller.
ws_accept_key :: proc(client_key: string, allocator := context.allocator) -> string {
	src := strings.concatenate({strings.trim_space(client_key), WS_MAGIC}, context.temp_allocator)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)src)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	encoded, _ := base64.encode(digest[:], allocator = allocator)
	return encoded
}

ws_write_text :: proc(sock: net.TCP_Socket, text: string) -> bool {
	return ws_write_frame(sock, WS_OP_TEXT, transmute([]byte)text)
}

// ws_encode_header writes the header of an unmasked final frame and returns its length.
ws_encode_header :: proc(header: ^[10]byte, opcode: byte, payload_len: int) -> int {
	header[0] = 0x80 | opcode
	switch {
	case payload_len <= 125:
		header[1] = byte(payload_len)
		return 2
	case payload_len <= 0xFFFF:
		header[1] = 126
		header[2] = byte(payload_len >> 8)
		header[3] = byte(payload_len)
		return 4
	}
	header[1] = 127
	for i in 0 ..< 8 {
		header[2 + i] = byte(u64(payload_len) >> uint(56 - i * 8))
	}
	return 10
}

ws_write_frame :: proc(sock: net.TCP_Socket, opcode: byte, payload: []byte) -> bool {
	header: [10]byte
	n := ws_encode_header(&header, opcode, len(payload))
	return send_all(sock, header[:n]) && send_all(sock, payload)
}

// ws_read_text reads one complete text message into buf, reassembling
// fragments. Pings arriving in between are answered (under write_mu, which
// also guards every other write to the socket).
ws_read_text :: proc(sock: net.TCP_Socket, buf: ^[dynamic]byte, frame: ^[dynamic]byte, write_mu: ^sync.Mutex) -> Ws_Read {
	clear(buf)
	started := false
	for {
		opcode, fin, result := ws_read_frame(sock, frame, idle_ok = !started)
		if result != .Message {
			return result
		}

		switch opcode {
		case WS_OP_CLOSE:
			sync.lock(write_mu)
			ws_write_frame(sock, WS_OP_CLOSE, nil)
			sync.unlock(write_mu)
			return .Closed
		case WS_OP_PING:
			sync.lock(write_mu)
			ws_write_frame(sock, WS_OP_PONG, frame[:])
			sync.unlock(write_mu)
		case WS_OP_PONG:
			if !started {
				// Lets the caller reset its idle counter.
				clear(buf)
				return .Message
			}
		case WS_OP_TEXT, WS_OP_CONTINUATION:
			// A text frame starts a message; continuations may only follow one.
			if (opcode == WS_OP_TEXT) == started {
				return .Closed
			}
			if len(buf) + len(frame) > WS_MAX_PAYLOAD {
				return .Closed
			}
			append(buf, ..frame[:])
			started = true
			if fin {
				return .Message
			}
		case:
			// Binary and reserved opcodes are not part of the protocol.
			return .Closed
		}
	}
}

@(private)
ws_read_frame :: proc(sock: net.TCP_Socket, payload: ^[dynamic]byte, idle_ok: bool) -> (opcode: byte, fin: bool, result: Ws_Read) {
	hdr: [2]byte
	switch recv_exact(sock, hdr[:], idle_ok) {
	case .Idle:   return 0, false, .Idle
	case .Closed: return 0, false, .Closed
	case .Message:
	}
	fin = hdr[0] & 0x80 != 0
	opcode = hdr[0] & 0x0F
	masked := hdr[1] & 0x80 != 0
	plen := u64(hdr[1] & 0x7F)

	// RSV bits need a negotiated extension, and clients must mask (RFC 6455 5.1).
	if hdr[0] & 0x70 != 0 || !masked {
		return 0, false, .Closed
	}
	if plen == 126 {
		ext: [2]byte
		if recv_exact(sock, ext[:], false) != .Message { return 0, false, .Closed }
		plen = u64(ext[0]) << 8 | u64(ext[1])
	} else if plen == 127 {
		ext: [8]byte
		if recv_exact(sock, ext[:], false) != .Message { return 0, false, .Closed }
		plen = 0
		for b in ext {
			plen = plen << 8 | u64(b)
		}
	}
	// Control frames are short and never fragmented.
	if opcode >= WS_OP_CLOSE && (plen > 125 || !fin) {
		return 0, false, .Closed
	}
	if plen > WS_MAX_PAYLOAD {
		return 0, false, .Closed
	}

	mask: [4]byte
	if recv_exact(sock, mask[:], false) != .Message { return 0, false, .Closed }

	resize(payload, int(plen))
	if plen > 0 && recv_exact(sock, payload[:], false) != .Message {
		return 0, false, .Closed
	}
	for i in 0 ..< int(plen) {
		payload[i] ~= mask[i & 3]
	}
	return opcode, fin, .Message
}

// send_all writes all of data, resuming after a signal interrupts the call.
send_all :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		sent += max(n, 0)
		if err != nil && err != net.TCP_Send_Error.Interrupted {
			return false
		}
	}
	return true
}

// Fills dest completely. A receive timeout before the first byte is .Idle
// when idle_ok; a timeout in the middle of a frame counts as a dead peer.
@(private)
recv_exact :: proc(sock: net.TCP_Socket, dest: []byte, idle_ok: bool) -> Ws_Read {
	got := 0
	for got < len(dest) {
		n, err := net.recv_tcp(sock, dest[got:])
		if err != nil {
			if err == net.TCP_Recv_Error.Interrupted {
				continue // a signal arrived; nothing was lost
			}
			if (err == net.TCP_Recv_Error.Timeout || err == net.TCP_Recv_Error.Would_Block) && got == 0 && idle_ok {
				return .Idle
			}
			utils.log_debug("signaling socket: %v", err)
			return .Closed
		}
		if n <= 0 {
			return .Closed
		}
		got += n
	}
	return .Message
}
