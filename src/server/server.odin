package server

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"

import "../network"
import "../utils"

Client :: struct {
	sock: net.TCP_Socket,
	mu:   sync.Mutex,
}

Hooks :: struct {
	user:         rawptr,
	on_offer:     proc(user: rawptr, client: ^Client, sdp: string),
	on_candidate: proc(user: rawptr, client: ^Client, candidate, mid: string),
	on_close:     proc(user: rawptr, client: ^Client),
	on_keyframe:  proc(user: rawptr, client: ^Client),
}

@(private)
Http_State :: struct {
	mu:    sync.Mutex,
	count: int,
	max:   int,
}

@(private)
Client_Job :: struct {
	sock:  net.TCP_Socket,
	hooks: Hooks,
	http:  ^Http_State,
}

client_send_json :: proc(client: ^Client, msg: network.Signal_Message) {
	data, err := json.marshal(msg)
	if err != nil {
		return
	}
	defer delete(data)
	sync.lock(&client.mu)
	ws_write_text(client.sock, string(data))
	sync.unlock(&client.mu)
}

listen_and_serve :: proc(cfg: utils.Config, hooks: Hooks) -> net.Network_Error {
	address, addr_ok := bind_to_address(cfg.bind)
	if !addr_ok {
		fmt.eprintf("invalid -bind: %s\n", cfg.bind)
		return net.Parse_Endpoint_Error.Bad_Address
	}

	endpoint := net.Endpoint{
		address = address,
		port    = cfg.port,
	}
	sock, err := net.listen_tcp(endpoint)
	if err != nil {
		return err
	}
	defer net.close(sock)

	fmt.printf("Odysseus listening on http://%s/odysseus\n", net.endpoint_to_string(endpoint))

	http: Http_State
	http.max = cfg.max_http

	for {
		client, _, accept_err := net.accept_tcp(sock)
		if accept_err != nil {
			fmt.eprintln("accept:", accept_err)
			continue
		}

		sync.lock(&http.mu)
		over := http.max > 0 && http.count >= http.max
		if !over {
			http.count += 1
		}
		sync.unlock(&http.mu)
		if over {
			write_status(client, 503, "text/plain", "too many connections\n")
			net.close(client)
			continue
		}

		thread.create_and_start_with_poly_data(
			Client_Job{sock = client, hooks = hooks, http = &http},
			handle_client_job,
			self_cleanup = true,
		)
	}
}

@(private)
bind_to_address :: proc(bind: string) -> (net.Address, bool) {
	b := strings.trim_space(bind)
	if b == "" || b == "0.0.0.0" {
		return net.IP4_Any, true
	}
	if b == "::" || b == "[::]" {
		return net.IP6_Any, true
	}
	addr := net.parse_address(b)
	if addr == nil {
		return nil, false
	}
	return addr, true
}

@(private)
handle_client_job :: proc(job: Client_Job) {
	defer {
		if sync.guard(&job.http.mu) {
			job.http.count -= 1
		}
	}
	handle_client(job.sock, job.hooks)
}

@(private)
handle_client :: proc(sock: net.TCP_Socket, hooks: Hooks) {
	defer net.close(sock)

	buf: [8192]byte
	n, recverr := net.recv_tcp(sock, buf[:])
	if recverr != nil || n <= 0 {
		return
	}

	req := string(buf[:n])
	line, _, rest := strings.partition(req, "\r\n")
	parts := strings.split(line, " ")
	defer delete(parts)
	if len(parts) < 2 {
		write_status(sock, 400, "text/plain", "bad request\n")
		return
	}

	method := parts[0]
	path := parts[1]
	if method != "GET" && method != "HEAD" {
		write_status(sock, 405, "text/plain", "method not allowed\n")
		return
	}

	if path == "/signal" {
		key, has_key := header_value(rest, "Sec-WebSocket-Key")
		if !has_key {
			write_status(sock, 400, "text/plain", "missing websocket key\n")
			return
		}
		accept := ws_accept_key(key)
		defer delete(accept)
		upgrade := fmt.tprintf(
			"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
			accept,
		)
		net.send_tcp(sock, transmute([]byte)upgrade)
		run_signal_socket(sock, hooks)
		return
	}

	switch path {
	case "/", "/index.html":
		write_status(sock, 200, "text/plain; charset=utf-8", HOME_TEXT)
	case "/odysseus", "/odysseus/":
		write_static(sock, 200, "text/html; charset=utf-8", INDEX_HTML)
	case "/odysseus/app.js":
		write_static(sock, 200, "text/javascript; charset=utf-8", APP_JS)
	case "/odysseus/style.css":
		write_static(sock, 200, "text/css; charset=utf-8", STYLE_CSS)
	case:
		write_status(sock, 404, "text/plain", "not found\n")
	}
}

@(private)
run_signal_socket :: proc(sock: net.TCP_Socket, hooks: Hooks) {
	client := Client{sock = sock}
	payload: [dynamic]byte
	defer delete(payload)

	read_loop: for {
		text, closed, ok := ws_read_text(sock, &payload, &client.mu)
		if closed || !ok {
			break
		}
		if text == "" {
			continue
		}

		msg: network.Signal_Message
		if json.unmarshal_string(text, &msg) != nil {
			fmt.eprintln("bad signaling json:", text)
			continue
		}

		switch msg.type {
		case "offer":
			if hooks.on_offer != nil {
				hooks.on_offer(hooks.user, &client, msg.sdp)
			}
		case "candidate":
			if hooks.on_candidate != nil {
				hooks.on_candidate(hooks.user, &client, msg.candidate, msg.mid)
			}
		case "bye":
			break read_loop
		case "keyframe", "viewer-ready":
			if hooks.on_keyframe != nil {
				hooks.on_keyframe(hooks.user, &client)
			}
		}
	}

	if hooks.on_close != nil {
		hooks.on_close(hooks.user, &client)
	}
}

@(private)
header_value :: proc(headers, name: string) -> (string, bool) {
	remaining := headers
	for remaining != "" {
		line, sep, rest := strings.partition(remaining, "\r\n")
		remaining = rest
		if line == "" {
			break
		}
		k, _, v := strings.partition(line, ":")
		if strings.equal_fold(strings.trim_space(k), name) {
			return strings.trim_space(v), true
		}
		if sep == "" {
			break
		}
	}
	return "", false
}

@(private)
write_status :: proc(client: net.TCP_Socket, status: int, content_type, body: string) {
	write_bytes(client, status, content_type, transmute([]byte)body)
}

@(private)
write_static :: proc(client: net.TCP_Socket, status: int, content_type: string, body: []byte) {
	reason := "OK"
	switch status {
	case 400: reason = "Bad Request"
	case 404: reason = "Not Found"
	case 405: reason = "Method Not Allowed"
	case 501: reason = "Not Implemented"
	case 503: reason = "Service Unavailable"
	}

	header := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
		status,
		reason,
		content_type,
		len(body),
	)
	net.send_tcp(client, transmute([]byte)header)
	if len(body) > 0 {
		net.send_tcp(client, body)
	}
}

@(private)
write_bytes :: proc(client: net.TCP_Socket, status: int, content_type: string, body: []byte) {
	reason := "OK"
	switch status {
	case 400: reason = "Bad Request"
	case 404: reason = "Not Found"
	case 405: reason = "Method Not Allowed"
	case 501: reason = "Not Implemented"
	case 503: reason = "Service Unavailable"
	}

	header := fmt.tprintf(
		"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n",
		status,
		reason,
		content_type,
		len(body),
	)
	net.send_tcp(client, transmute([]byte)header)
	if len(body) > 0 {
		net.send_tcp(client, body)
	}
}
