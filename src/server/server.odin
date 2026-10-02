package server

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "../network"
import "../utils"

// Small HTTP server: serves the embedded viewer page and upgrades /signal to
// the WebSocket that carries WebRTC signaling. One thread per connection,
// which is plenty for a LAN tool with a handful of viewers.

// Client is one signaling WebSocket. It lives on its connection thread's stack
// for exactly as long as the connection is registered with the server.
Client :: struct {
	sock:          net.TCP_Socket,
	mu:            sync.Mutex, // serializes writes to sock
	remote:        net.Endpoint,
	authorized:    bool, // may watch
	control:       bool, // may send input
	auth_failures: int,
}

Hooks :: struct {
	user:       rawptr,
	on_open:    proc(user: rawptr, client: ^Client),
	on_message: proc(user: rawptr, client: ^Client, msg: ^network.Signal_Message),
	on_close:   proc(user: rawptr, client: ^Client),
	status:     proc(user: rawptr, allocator := context.allocator) -> string, // JSON body of /api/status
}

@(private)
Server :: struct {
	hooks:    Hooks,
	max_http: int,
	host_names:   string, // -host-name: extra names accepted in the Host header (comma separated)
	machine_name: string,
	mu:       sync.Mutex, // clients, connections
	clients:  [dynamic]^Client,
	connections: int,
	listener: net.TCP_Socket,
	stopping: bool,
}

@(private)
srv: Server

@(private)
HTTP_HEAD_MAX       :: 8192
@(private)
HTTP_HEAD_TIMEOUT   :: 5 * time.Second
@(private)
WS_IDLE_TIMEOUT     :: 20 * time.Second // ping after this much silence
@(private)
WS_IDLE_LIMIT       :: 3                // unanswered pings before the client is dropped
@(private)
WS_SEND_TIMEOUT     :: 10 * time.Second

// client_send marshals msg as JSON and sends it as one text frame.
client_send :: proc(client: ^Client, msg: any) -> bool {
	data, err := json.marshal(msg)
	if err != nil {
		return false
	}
	defer delete(data)
	sync.lock(&client.mu)
	defer sync.unlock(&client.mu)
	return ws_write_text(client.sock, string(data))
}

client_send_error :: proc(client: ^Client, code, message: string) {
	client_send(client, network.Error_Message{type = "error", code = code, message = message})
}

// broadcast calls visit for every connected signaling client.
broadcast :: proc(user: rawptr, visit: proc(user: rawptr, client: ^Client)) {
	sync.lock(&srv.mu)
	defer sync.unlock(&srv.mu)
	for client in srv.clients {
		visit(user, client)
	}
}

// listen_and_serve runs the accept loop until shutdown is called or the listener fails.
listen_and_serve :: proc(cfg: utils.Config, hooks: Hooks) -> net.Network_Error {
	address, addr_ok := bind_to_address(cfg.bind)
	if !addr_ok {
		utils.log_error("invalid -bind address: %s", cfg.bind)
		return net.Parse_Endpoint_Error.Bad_Address
	}

	endpoint := net.Endpoint{address = address, port = cfg.port}
	sock, err := net.listen_tcp(endpoint)
	if err != nil {
		return err
	}
	srv.hooks = hooks
	srv.max_http = cfg.max_http
	srv.host_names = strings.clone(cfg.host_name)
	srv.machine_name = strings.clone(utils.hostname())
	srv.listener = sock

	for {
		conn, remote, accept_err := net.accept_tcp(sock)
		if sync.atomic_load(&srv.stopping) {
			if accept_err == nil {
				net.close(conn)
			}
			return nil
		}
		if accept_err == net.Accept_Error.Interrupted {
			continue
		}
		if accept_err != nil {
			utils.log_warn("accept: %v", accept_err)
			time.sleep(50 * time.Millisecond)
			continue
		}

		sync.lock(&srv.mu)
		over := srv.max_http > 0 && srv.connections >= srv.max_http
		if !over {
			srv.connections += 1
		}
		sync.unlock(&srv.mu)
		if over {
			write_response(conn, 503, "text/plain; charset=utf-8", transmute([]byte)string("too many connections\n"))
			net.close(conn)
			continue
		}

		t := thread.create_and_start_with_poly_data2(conn, remote, handle_connection, self_cleanup = true)
		if t == nil {
			handle_connection_done(conn)
		}
	}
}

// shutdown stops accepting connections and closes every signaling socket.
shutdown :: proc() {
	sync.atomic_store(&srv.stopping, true)
	net.close(srv.listener)
	sync.lock(&srv.mu)
	for client in srv.clients {
		net.shutdown(client.sock, .Both)
	}
	sync.unlock(&srv.mu)
}

@(private)
bind_to_address :: proc(bind: string) -> (net.Address, bool) {
	b := strings.trim_space(bind)
	if len(b) >= 2 && b[0] == '[' && b[len(b) - 1] == ']' {
		b = b[1:len(b) - 1] // "[::1]"
	}
	switch b {
	case "", "0.0.0.0":
		return net.IP4_Any, true
	case "::":
		return net.IP6_Any, true
	}
	addr := net.parse_address(b)
	if _, is_v4 := addr.(net.IP4_Address); is_v4 && strings.contains_rune(b, ':') {
		return nil, false // "1.2.3.4:8080": core:net drops the port, but -bind takes no port
	}
	return addr, addr != nil
}

@(private)
handle_connection_done :: proc(sock: net.TCP_Socket) {
	net.close(sock)
	sync.lock(&srv.mu)
	srv.connections -= 1
	sync.unlock(&srv.mu)
}

@(private)
handle_connection :: proc(sock: net.TCP_Socket, remote: net.Endpoint) {
	defer handle_connection_done(sock)
	defer free_all(context.temp_allocator)

	net.set_option(sock, .Receive_Timeout, HTTP_HEAD_TIMEOUT)
	net.set_option(sock, .Send_Timeout, WS_SEND_TIMEOUT)

	buf: [HTTP_HEAD_MAX]byte
	head, head_ok := read_request_head(sock, buf[:])
	if !head_ok {
		return
	}
	req, req_ok := parse_request(head)
	if !req_ok {
		write_text(sock, 400, "bad request\n")
		return
	}
	if req.method != "GET" && req.method != "HEAD" {
		write_text(sock, 405, "method not allowed\n")
		return
	}
	head_only := req.method == "HEAD"

	if host, _ := header_value(req.headers, "Host"); !host_allowed(host, srv.machine_name, srv.host_names) {
		write_text(sock, 403, "Odysseus does not answer to this host name. Open it by IP address, or start it with -host-name:<name>.\n")
		return
	}

	switch req.path {
	case "/signal":
		serve_signal(sock, remote, req)
	case "/", "/index.html":
		write_redirect(sock, "/odysseus")
	case "/odysseus", "/odysseus/":
		write_response(sock, 200, "text/html; charset=utf-8", INDEX_HTML, head_only)
	case "/odysseus/app.js":
		write_response(sock, 200, "text/javascript; charset=utf-8", APP_JS, head_only)
	case "/odysseus/style.css":
		write_response(sock, 200, "text/css; charset=utf-8", STYLE_CSS, head_only)
	case "/odysseus/favicon.svg", "/favicon.ico":
		write_response(sock, 200, "image/svg+xml", FAVICON_SVG, head_only)
	case "/api/status":
		body := "{}"
		if srv.hooks.status != nil {
			body = srv.hooks.status(srv.hooks.user, context.temp_allocator)
		}
		write_response(sock, 200, "application/json", transmute([]byte)body, head_only)
	case:
		write_text(sock, 404, "not found\n")
	}
}

@(private)
Request :: struct {
	method:  string,
	path:    string, // without the query string
	headers: string,
}

// Reads until the blank line that ends the request head. The whole head has
// to arrive within HTTP_HEAD_TIMEOUT, however slowly the client trickles it.
@(private)
read_request_head :: proc(sock: net.TCP_Socket, buf: []byte) -> (head: string, ok: bool) {
	started := time.tick_now()
	n := 0
	for n < len(buf) {
		got, err := net.recv_tcp(sock, buf[n:])
		if err == net.TCP_Recv_Error.Interrupted {
			continue
		}
		if err != nil || got <= 0 {
			return "", false
		}
		n += got
		if end := strings.index(string(buf[:n]), "\r\n\r\n"); end >= 0 {
			return string(buf[:end + 2]), true
		}
		if time.tick_since(started) > HTTP_HEAD_TIMEOUT {
			return "", false
		}
	}
	write_text(sock, 431, "request header too large\n")
	return "", false
}

@(private)
parse_request :: proc(head: string) -> (req: Request, ok: bool) {
	line, _, rest := strings.partition(head, "\r\n")
	method, _, after := strings.partition(line, " ")
	target, _, version := strings.partition(after, " ")
	if method == "" || target == "" || !strings.has_prefix(version, "HTTP/1.") {
		return {}, false
	}
	path := target
	if q := strings.index_byte(path, '?'); q >= 0 {
		path = path[:q]
	}
	return {method = method, path = path, headers = rest}, true
}

// header_value finds a request header by case-insensitive name.
@(private)
header_value :: proc(headers, name: string) -> (value: string, found: bool) {
	rest := headers
	for line in strings.split_iterator(&rest, "\r\n") {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		if strings.equal_fold(strings.trim_space(line[:colon]), name) {
			return strings.trim_space(line[colon + 1:]), true
		}
	}
	return "", false
}

// A page on another site must not be able to open the signaling socket of a
// host on the viewer's LAN (cross-site WebSocket hijacking): when the browser
// sends an Origin, it has to be this server.
@(private)
origin_allowed :: proc(headers: string) -> bool {
	origin, has_origin := header_value(headers, "Origin")
	if !has_origin {
		return true // not a browser
	}
	host, has_host := header_value(headers, "Host")
	if !has_host {
		return false
	}
	scheme := strings.index(origin, "://")
	if scheme < 0 {
		return false
	}
	return strings.equal_fold(origin[scheme + 3:], host)
}

// host_allowed guards against DNS rebinding: a hostile page whose domain
// resolves to this machine passes the Origin == Host comparison, so the Host
// itself must be a name viewers legitimately use: an IP address, localhost,
// this machine's name (also as <name>.local), or one given with -host-name.
// A request without a Host header is not from a browser and is let through.
@(private)
host_allowed :: proc(host_header, machine_name, extra_names: string) -> bool {
	host := strings.trim_space(host_header)
	if host == "" {
		return true
	}
	if host[0] == '[' {
		return strings.index_byte(host, ']') > 0 // IPv6 literal
	}
	if colon := strings.last_index_byte(host, ':'); colon >= 0 {
		host = host[:colon]
	}
	if _, is_ip := net.parse_ip4_address(host); is_ip {
		return true
	}
	if strings.equal_fold(host, "localhost") {
		return true
	}
	if machine_name != "" {
		if strings.equal_fold(host, machine_name) {
			return true
		}
		if len(host) == len(machine_name) + len(".local") &&
		   strings.equal_fold(host[:len(machine_name)], machine_name) &&
		   strings.equal_fold(host[len(machine_name):], ".local") {
			return true
		}
	}
	rest := extra_names
	for name in strings.split_iterator(&rest, ",") {
		if n := strings.trim_space(name); n != "" && strings.equal_fold(host, n) {
			return true
		}
	}
	return false
}

@(private)
serve_signal :: proc(sock: net.TCP_Socket, remote: net.Endpoint, req: Request) {
	key, has_key := header_value(req.headers, "Sec-WebSocket-Key")
	upgrade, _ := header_value(req.headers, "Upgrade")
	version, _ := header_value(req.headers, "Sec-WebSocket-Version")
	if req.method != "GET" || !has_key || !strings.equal_fold(upgrade, "websocket") {
		write_text(sock, 400, "expected a websocket upgrade\n")
		return
	}
	if version != "13" {
		write_text(sock, 426, "unsupported websocket version\n")
		return
	}
	if !origin_allowed(req.headers) {
		write_text(sock, 403, "cross-origin signaling is not allowed\n")
		return
	}

	accept := ws_accept_key(key, context.temp_allocator)
	response := fmt.tprintf(
		"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n",
		accept,
	)
	if !send_all(sock, transmute([]byte)response) {
		return
	}
	net.set_option(sock, .Receive_Timeout, WS_IDLE_TIMEOUT)

	client := Client{sock = sock, remote = remote}
	sync.lock(&srv.mu)
	append(&srv.clients, &client)
	sync.unlock(&srv.mu)

	hooks := srv.hooks
	if hooks.on_open != nil {
		hooks.on_open(hooks.user, &client)
	}

	message: [dynamic]byte
	frame: [dynamic]byte
	defer delete(message)
	defer delete(frame)
	idle := 0

	read_loop: for {
		free_all(context.temp_allocator)
		switch ws_read_text(sock, &message, &frame, &client.mu) {
		case .Closed:
			break read_loop
		case .Idle:
			idle += 1
			if idle > WS_IDLE_LIMIT {
				utils.log_debug("signaling client timed out")
				break read_loop
			}
			sync.lock(&client.mu)
			alive := ws_write_frame(sock, WS_OP_PING, nil)
			sync.unlock(&client.mu)
			if !alive {
				break read_loop
			}
			continue
		case .Message:
			idle = 0
		}
		if len(message) == 0 {
			continue
		}

		msg: network.Signal_Message
		if json.unmarshal(message[:], &msg, allocator = context.temp_allocator) != nil {
			utils.log_debug("ignoring malformed signaling message")
			continue
		}
		if msg.type == "bye" {
			break read_loop
		}
		if hooks.on_message != nil {
			hooks.on_message(hooks.user, &client, &msg)
		}
	}

	// Unregister first so no broadcast can reach a client that is going away.
	sync.lock(&srv.mu)
	for c, i in srv.clients {
		if c == &client {
			unordered_remove(&srv.clients, i)
			break
		}
	}
	sync.unlock(&srv.mu)

	if hooks.on_close != nil {
		hooks.on_close(hooks.user, &client)
	}
}

@(private)
status_reason :: proc(status: int) -> string {
	switch status {
	case 200: return "OK"
	case 302: return "Found"
	case 400: return "Bad Request"
	case 403: return "Forbidden"
	case 404: return "Not Found"
	case 405: return "Method Not Allowed"
	case 426: return "Upgrade Required"
	case 431: return "Request Header Fields Too Large"
	case 503: return "Service Unavailable"
	}
	return "Error"
}

@(private)
write_text :: proc(sock: net.TCP_Socket, status: int, body: string) {
	write_response(sock, status, "text/plain; charset=utf-8", transmute([]byte)body)
}

@(private)
write_redirect :: proc(sock: net.TCP_Socket, location: string) {
	header := fmt.tprintf(
		"HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
		location,
	)
	send_all(sock, transmute([]byte)header)
}

@(private)
write_response :: proc(sock: net.TCP_Socket, status: int, content_type: string, body: []byte, head_only := false) {
	header := fmt.tprintf(
		"HTTP/1.1 %d %s\r\n" +
		"Content-Type: %s\r\n" +
		"Content-Length: %d\r\n" +
		"Cache-Control: no-cache\r\n" +
		"X-Content-Type-Options: nosniff\r\n" +
		"Referrer-Policy: no-referrer\r\n" +
		"Content-Security-Policy: default-src 'self'; connect-src 'self' ws: wss:; img-src 'self' data:; media-src 'self' blob: mediastream:; frame-ancestors 'none'\r\n" +
		"Connection: close\r\n\r\n",
		status,
		status_reason(status),
		content_type,
		len(body),
	)
	if !send_all(sock, transmute([]byte)header) {
		return
	}
	if !head_only {
		send_all(sock, body)
	}
}
