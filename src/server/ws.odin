package server

import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"

WS_MAGIC       :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WS_MAX_PAYLOAD :: 1 << 20

ws_accept_key :: proc(client_key: string) -> string {
	src := fmt.tprintf("%s%s", strings.trim_space(client_key), WS_MAGIC)
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)src)
	digest: [sha1.DIGEST_SIZE]byte
	sha1.final(&ctx, digest[:])
	encoded, _ := base64.encode(digest[:])
	return encoded
}

ws_write_text :: proc(sock: net.TCP_Socket, text: string) -> bool {
	return ws_write_frame(sock, 0x1, transmute([]byte)text)
}

ws_write_close :: proc(sock: net.TCP_Socket) {
	ws_write_frame(sock, 0x8, nil)
}

@(private)
ws_write_frame :: proc(sock: net.TCP_Socket, opcode: byte, payload: []byte) -> bool {
	header: [14]byte
	n := 0
	header[0] = 0x80 | opcode
	n = 2
	plen := len(payload)
	if plen <= 125 {
		header[1] = byte(plen)
	} else if plen <= 0xFFFF {
		header[1] = 126
		header[2] = byte(plen >> 8)
		header[3] = byte(plen)
		n = 4
	} else {
		header[1] = 127
		for i in 0 ..< 8 {
			header[2 + i] = byte(u64(plen) >> uint(56 - i * 8))
		}
		n = 10
	}
	if _, err := net.send_tcp(sock, header[:n]); err != nil {
		return false
	}
	if plen > 0 {
		if _, err := net.send_tcp(sock, payload); err != nil {
			return false
		}
	}
	return true
}

// Reads one complete text (or close) message, including fragmented frames.
// Control frames (ping/pong/close) may arrive between fragments; ping is answered immediately.
ws_read_text :: proc(sock: net.TCP_Socket, buf: ^[dynamic]byte, write_mu: ^sync.Mutex = nil) -> (text: string, closed: bool, ok: bool) {
	clear(buf)
	started := false
	frame: [dynamic]byte
	defer delete(frame)

	for {
		opcode, fin, frame_ok := ws_read_frame(sock, &frame)
		if !frame_ok {
			return "", true, false
		}

		switch opcode {
		case 0x8:
			return "", true, true
		case 0x9:
			if write_mu != nil {
				sync.lock(write_mu)
			}
			ws_write_frame(sock, 0xA, frame[:])
			if write_mu != nil {
				sync.unlock(write_mu)
			}
			continue
		case 0xA:
			continue
		case 0x1:
			if started {
				return "", true, false
			}
			if len(buf) + len(frame) > WS_MAX_PAYLOAD {
				return "", true, false
			}
			append(buf, ..frame[:])
			started = true
			if fin {
				return string(buf[:]), false, true
			}
		case 0x0:
			if !started {
				return "", true, false
			}
			if len(buf) + len(frame) > WS_MAX_PAYLOAD {
				return "", true, false
			}
			append(buf, ..frame[:])
			if fin {
				return string(buf[:]), false, true
			}
		}
	}
}

@(private)
ws_read_frame :: proc(sock: net.TCP_Socket, buf: ^[dynamic]byte) -> (opcode: byte, fin: bool, ok: bool) {
	hdr: [2]byte
	if !recv_exact(sock, hdr[:]) {
		return 0, false, false
	}
	fin = hdr[0] & 0x80 != 0
	opcode = hdr[0] & 0x0F
	masked := hdr[1] & 0x80 != 0
	plen := int(hdr[1] & 0x7F)

	if plen == 126 {
		ext: [2]byte
		if !recv_exact(sock, ext[:]) { return 0, false, false }
		plen = int(ext[0]) << 8 | int(ext[1])
	} else if plen == 127 {
		ext: [8]byte
		if !recv_exact(sock, ext[:]) { return 0, false, false }
		plen = int(u64(ext[0]) << 56 | u64(ext[1]) << 48 | u64(ext[2]) << 40 | u64(ext[3]) << 32 |
			u64(ext[4]) << 24 | u64(ext[5]) << 16 | u64(ext[6]) << 8 | u64(ext[7]))
	}

	mask: [4]byte
	if masked {
		if !recv_exact(sock, mask[:]) { return 0, false, false }
	}

	if plen < 0 || plen > WS_MAX_PAYLOAD {
		return 0, false, false
	}

	clear(buf)
	resize(buf, plen)
	if plen > 0 && !recv_exact(sock, buf[:]) {
		return 0, false, false
	}
	if masked {
		for i in 0 ..< plen {
			buf[i] ~= mask[i % 4]
		}
	}
	return opcode, fin, true
}

@(private)
recv_exact :: proc(sock: net.TCP_Socket, dest: []byte) -> bool {
	got := 0
	for got < len(dest) {
		n, err := net.recv_tcp(sock, dest[got:])
		if err != nil || n <= 0 {
			return false
		}
		got += n
	}
	return true
}
