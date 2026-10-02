package server

import "core:net"
import "core:testing"

// Everything below only exists in `odin test` builds: the package directory is
// also built by a plain `odin build`, which must not compile (or break on) tests.
when ODIN_TEST {

// Unit tests for the HTTP request helpers in server.odin.

// ---------------------------------------------------------------------------
// parse_request
// ---------------------------------------------------------------------------

@(test)
test_parse_request_basic :: proc(t: ^testing.T) {
	req, ok := parse_request("GET /odysseus HTTP/1.1\r\nHost: 192.168.1.5:8080\r\nUser-Agent: x\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, req.method, "GET")
	testing.expect_value(t, req.path, "/odysseus")
	testing.expect_value(t, req.headers, "Host: 192.168.1.5:8080\r\nUser-Agent: x\r\n")
}

@(test)
test_parse_request_as_produced_by_read_request_head :: proc(t: ^testing.T) {
	// read_request_head returns the head up to and including the CRLF of the
	// last header line (the blank line is cut off).
	req, ok := parse_request("GET /signal HTTP/1.1\r\nHost: h\r\nUpgrade: websocket\r\n")
	testing.expect(t, ok)
	h, found := header_value(req.headers, "upgrade")
	testing.expect(t, found)
	testing.expect_value(t, h, "websocket")
}

@(test)
test_parse_request_strips_query_string :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"GET /signal?token=abc&x=1 HTTP/1.1\r\n", "/signal"},
		{"GET /?a=b HTTP/1.1\r\n", "/"},
		{"GET /odysseus/?x HTTP/1.1\r\n", "/odysseus/"},
		{"GET /odysseus? HTTP/1.1\r\n", "/odysseus"},
		{"GET /a?b?c HTTP/1.1\r\n", "/a"},
		{"GET /api/status?cache=0 HTTP/1.1\r\n", "/api/status"},
		{"GET /x?/../etc/passwd HTTP/1.1\r\n", "/x"},
	}
	for c in cases {
		req, ok := parse_request(c[0])
		testing.expectf(t, ok, "%q rejected", c[0])
		testing.expectf(t, req.path == c[1], "%q -> path %q, want %q", c[0], req.path, c[1])
	}
}

@(test)
test_parse_request_methods :: proc(t: ^testing.T) {
	// Methods are returned verbatim (the caller decides which it allows).
	req, ok := parse_request("POST /x HTTP/1.1\r\nContent-Length: 0\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, req.method, "POST")
	req, ok = parse_request("get /x HTTP/1.1\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, req.method, "get")
}

@(test)
test_parse_request_http_versions :: proc(t: ^testing.T) {
	_, ok := parse_request("GET / HTTP/1.0\r\n")
	testing.expect(t, ok, "HTTP/1.0 is fine")
	_, ok = parse_request("GET / HTTP/1.1\r\n")
	testing.expect(t, ok)
	_, ok = parse_request("GET / HTTP/2.0\r\n")
	testing.expect(t, !ok)
	_, ok = parse_request("GET / HTTP/0.9\r\n")
	testing.expect(t, !ok)
	_, ok = parse_request("GET / HTTP/1\r\n")
	testing.expect(t, !ok)
	_, ok = parse_request("GET / http/1.1\r\n")
	testing.expect(t, !ok)
	_, ok = parse_request("GET / SPDY/3\r\n")
	testing.expect(t, !ok)
}

@(test)
test_parse_request_malformed_lines :: proc(t: ^testing.T) {
	bad := []string {
		"",
		"\r\n",
		"GET",
		"GET\r\n",
		"GET /",
		"GET /\r\n",
		"GET / \r\n",
		"GET  / HTTP/1.1\r\n", // double space: empty target
		" / HTTP/1.1\r\n",     // empty method
		"/ HTTP/1.1\r\n",
		"GET\t/ HTTP/1.1\r\n",
		"GET /a b HTTP/1.1\r\n", // space in the target
		"HTTP/1.1\r\n",
		"\x00\x01\x02\r\n",
		"\r\nGET / HTTP/1.1\r\n", // leading blank line: first line is empty
	}
	for line in bad {
		_, ok := parse_request(line)
		testing.expectf(t, !ok, "malformed request %q was accepted", line)
	}
}

@(test)
test_parse_request_without_headers :: proc(t: ^testing.T) {
	req, ok := parse_request("GET / HTTP/1.1")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, "/")
	testing.expect_value(t, req.headers, "")

	req, ok = parse_request("GET / HTTP/1.1\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, req.headers, "")
}

@(test)
test_parse_request_target_forms :: proc(t: ^testing.T) {
	// Absolute-form and asterisk-form are passed through; they will not match any route.
	req, ok := parse_request("GET http://host/odysseus HTTP/1.1\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, "http://host/odysseus")
	req, ok = parse_request("OPTIONS * HTTP/1.1\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, req.path, "*")
}

// ---------------------------------------------------------------------------
// header_value
// ---------------------------------------------------------------------------

@(test)
test_header_value_basic :: proc(t: ^testing.T) {
	h := "Host: 192.168.1.5:8080\r\nOrigin: http://192.168.1.5:8080\r\nSec-WebSocket-Version: 13\r\n"
	v, ok := header_value(h, "Host")
	testing.expect(t, ok)
	testing.expect_value(t, v, "192.168.1.5:8080")
	v, ok = header_value(h, "Origin")
	testing.expect(t, ok)
	testing.expect_value(t, v, "http://192.168.1.5:8080")
	v, ok = header_value(h, "Sec-WebSocket-Version") // last line
	testing.expect(t, ok)
	testing.expect_value(t, v, "13")
}

@(test)
test_header_value_name_is_case_insensitive :: proc(t: ^testing.T) {
	h := "hOsT: example\r\nSEC-WEBSOCKET-KEY: abc==\r\n"
	for name in ([]string{"Host", "host", "HOST", "hOsT"}) {
		v, ok := header_value(h, name)
		testing.expectf(t, ok && v == "example", "lookup of %q failed", name)
	}
	v, ok := header_value(h, "Sec-WebSocket-Key")
	testing.expect(t, ok)
	testing.expect_value(t, v, "abc==")
}

@(test)
test_header_value_whitespace :: proc(t: ^testing.T) {
	v, ok := header_value("Host:   example.com:8080   \r\n", "Host")
	testing.expect(t, ok)
	testing.expect_value(t, v, "example.com:8080")

	v, ok = header_value("Host:example.com\r\n", "Host") // no space after the colon
	testing.expect(t, ok)
	testing.expect_value(t, v, "example.com")

	v, ok = header_value("Host:\texample.com\t\r\n", "Host")
	testing.expect(t, ok)
	testing.expect_value(t, v, "example.com")

	// Internal whitespace is kept.
	v, ok = header_value("User-Agent: Mozilla/5.0 (X11; Linux)\r\n", "User-Agent")
	testing.expect(t, ok)
	testing.expect_value(t, v, "Mozilla/5.0 (X11; Linux)")
}

@(test)
test_header_value_missing_and_empty :: proc(t: ^testing.T) {
	_, ok := header_value("Host: x\r\n", "Origin")
	testing.expect(t, !ok)
	_, ok = header_value("", "Host")
	testing.expect(t, !ok)

	v, ok2 := header_value("X-Empty:\r\nHost: x\r\n", "X-Empty")
	testing.expect(t, ok2, "an empty value is still a present header")
	testing.expect_value(t, v, "")
	v, ok2 = header_value("X-Empty:   \r\n", "X-Empty")
	testing.expect(t, ok2)
	testing.expect_value(t, v, "")
}

@(test)
test_header_value_names_do_not_match_partially :: proc(t: ^testing.T) {
	h := "X-Origin: evil\r\nOrigin-Extra: evil\r\nOriginx: evil\r\nxOrigin: evil\r\n"
	_, ok := header_value(h, "Origin")
	testing.expect(t, !ok, "only an exact (case-insensitive) name may match")

	h2 := "X-Host: a\r\nHost: b\r\n"
	v, ok2 := header_value(h2, "Host")
	testing.expect(t, ok2)
	testing.expect_value(t, v, "b")
}

@(test)
test_header_value_value_with_colons :: proc(t: ^testing.T) {
	v, ok := header_value("Origin: http://[::1]:8080\r\n", "Origin")
	testing.expect(t, ok)
	testing.expect_value(t, v, "http://[::1]:8080")
}

@(test)
test_header_value_first_occurrence_wins :: proc(t: ^testing.T) {
	v, ok := header_value("Host: first\r\nHost: second\r\n", "Host")
	testing.expect(t, ok)
	testing.expect_value(t, v, "first")
}

@(test)
test_header_value_skips_lines_without_name :: proc(t: ^testing.T) {
	h := "garbage line\r\n: no name\r\n\r\nHost: x\r\n"
	v, ok := header_value(h, "Host")
	testing.expect(t, ok)
	testing.expect_value(t, v, "x")
	_, ok = header_value(": 5\r\n", "")
	testing.expect(t, !ok)
}

@(test)
test_header_value_last_line_without_crlf :: proc(t: ^testing.T) {
	v, ok := header_value("Host: a\r\nOrigin: b", "Origin")
	testing.expect(t, ok)
	testing.expect_value(t, v, "b")
}

// ---------------------------------------------------------------------------
// host_allowed

@(test)
test_host_allowed_addresses_and_local_names :: proc(t: ^testing.T) {
	testing.expect(t, host_allowed("192.168.1.5:8080", "MYPC", ""))
	testing.expect(t, host_allowed("10.0.0.2", "MYPC", ""))
	testing.expect(t, host_allowed("[fe80::1]:8080", "MYPC", ""))
	testing.expect(t, host_allowed("localhost:8080", "MYPC", ""))
	testing.expect(t, host_allowed("LOCALHOST", "MYPC", ""))
	testing.expect(t, host_allowed("mypc:8080", "MYPC", ""), "machine name, any case")
	testing.expect(t, host_allowed("mypc.local:8080", "MYPC", ""), "mDNS name")
	testing.expect(t, host_allowed("", "MYPC", ""), "no Host header: not a browser")
}

@(test)
test_host_allowed_refuses_foreign_names :: proc(t: ^testing.T) {
	// DNS rebinding: the attacker's domain resolves to this machine.
	testing.expect(t, !host_allowed("evil.example:8080", "MYPC", ""))
	testing.expect(t, !host_allowed("mypc.evil.example:8080", "MYPC", ""))
	testing.expect(t, !host_allowed("mypc.localx", "MYPC", ""))
	testing.expect(t, !host_allowed("192.168.1.5.evil.example", "MYPC", ""))
	testing.expect(t, !host_allowed("mypc.local", "", ""), "unknown machine name allows nothing extra")
	testing.expect(t, !host_allowed("[fe80::1", "MYPC", ""))
}

@(test)
test_host_allowed_extra_names :: proc(t: ^testing.T) {
	testing.expect(t, host_allowed("desk.fritz.box:8080", "MYPC", "desk.fritz.box"))
	testing.expect(t, host_allowed("Share.Example.org", "MYPC", "desk.fritz.box, share.example.org"))
	testing.expect(t, !host_allowed("other.fritz.box", "MYPC", "desk.fritz.box, share.example.org"))
	testing.expect(t, !host_allowed("evil.example", "MYPC", " , "))
}

// ---------------------------------------------------------------------------
// origin_allowed
// ---------------------------------------------------------------------------

@(test)
test_origin_same_host_and_port_allowed :: proc(t: ^testing.T) {
	testing.expect(t, origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http://192.168.1.5:8080\r\n"))
	// Order of the headers does not matter.
	testing.expect(t, origin_allowed("Origin: http://192.168.1.5:8080\r\nHost: 192.168.1.5:8080\r\n"))
	testing.expect(t, origin_allowed("Host: localhost:8080\r\nOrigin: http://localhost:8080\r\n"))
	testing.expect(t, origin_allowed("Host: my-pc.local:8080\r\nOrigin: http://my-pc.local:8080\r\n"))
	// Default port: both sides omit it.
	testing.expect(t, origin_allowed("Host: 10.0.0.2\r\nOrigin: http://10.0.0.2\r\n"))
	// https page on the same host:port.
	testing.expect(t, origin_allowed("Host: 10.0.0.2:8443\r\nOrigin: https://10.0.0.2:8443\r\n"))
	// IPv6 literal.
	testing.expect(t, origin_allowed("Host: [fe80::1]:8080\r\nOrigin: http://[fe80::1]:8080\r\n"))
}

@(test)
test_origin_different_host_refused :: proc(t: ^testing.T) {
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http://192.168.1.6:8080\r\n"))
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http://evil.example:8080\r\n"))
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http://evil.example\r\n"))
	testing.expect(t, !origin_allowed("Host: localhost:8080\r\nOrigin: http://127.0.0.1:8080\r\n"))
}

@(test)
test_origin_different_port_refused :: proc(t: ^testing.T) {
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http://192.168.1.5:8081\r\n"))
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http://192.168.1.5\r\n"))
	testing.expect(t, !origin_allowed("Host: 192.168.1.5\r\nOrigin: http://192.168.1.5:8080\r\n"))
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http://192.168.1.5:80800\r\n"))
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http://192.168.1.5:808\r\n"))
}

@(test)
test_origin_missing_allowed :: proc(t: ^testing.T) {
	// Not a browser: no Origin header, no check.
	testing.expect(t, origin_allowed("Host: 192.168.1.5:8080\r\n"))
	testing.expect(t, origin_allowed(""))
	testing.expect(t, origin_allowed("Upgrade: websocket\r\n"))
}

@(test)
test_origin_null_and_garbage_refused :: proc(t: ^testing.T) {
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: null\r\n"), "sandboxed iframes / file:// send Origin: null")
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: NULL\r\n"))
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin:\r\n"), "empty Origin")
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: 192.168.1.5:8080\r\n"), "no scheme")
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: //192.168.1.5:8080\r\n"))
	testing.expect(t, !origin_allowed("Host: 192.168.1.5:8080\r\nOrigin: http:/192.168.1.5:8080\r\n"))
}

@(test)
test_origin_without_host_refused :: proc(t: ^testing.T) {
	testing.expect(t, !origin_allowed("Origin: http://192.168.1.5:8080\r\n"))
}

@(test)
test_origin_must_match_exactly :: proc(t: ^testing.T) {
	host := "Host: 192.168.1.5:8080\r\n"
	// Suffix / prefix / path / userinfo tricks.
	for o in ([]string {
		"http://192.168.1.5:8080.evil.com",
		"http://evil.com/192.168.1.5:8080",
		"http://evil.com#192.168.1.5:8080",
		"http://192.168.1.5:8080/",
		"http://192.168.1.5:8080/path",
		"http://user@192.168.1.5:8080",
		"http://x.192.168.1.5:8080",
		"evil://http://192.168.1.5:8080",
	}) {
		hdrs := make([dynamic]byte, context.temp_allocator)
		append(&hdrs, host)
		append(&hdrs, "Origin: ")
		append(&hdrs, o)
		append(&hdrs, "\r\n")
		testing.expectf(t, !origin_allowed(string(hdrs[:])), "Origin %q was accepted", o)
	}
}

@(test)
test_origin_case_insensitive :: proc(t: ^testing.T) {
	testing.expect(t, origin_allowed("Host: MyPC.local:8080\r\nOrigin: http://mypc.LOCAL:8080\r\n"))
	testing.expect(t, origin_allowed("host: a:1\r\norigin: HTTP://A:1\r\n"))
}

@(test)
test_origin_header_names_not_confused :: proc(t: ^testing.T) {
	// A header merely containing "Origin" in its name must not count as Origin.
	testing.expect(t, origin_allowed("Host: a:1\r\nX-Origin: http://evil.com\r\n"))
	// And a later real Origin is still checked.
	testing.expect(t, !origin_allowed("Host: a:1\r\nX-Origin: http://a:1\r\nOrigin: http://evil.com\r\n"))
}

// ---------------------------------------------------------------------------
// bind_to_address
// ---------------------------------------------------------------------------

@(private = "file")
expect_ip4 :: proc(t: ^testing.T, bind: string, want: net.IP4_Address, loc := #caller_location) {
	addr, ok := bind_to_address(bind)
	if !testing.expectf(t, ok, "%q was rejected", bind, loc = loc) {
		return
	}
	a4, is4 := addr.(net.IP4_Address)
	testing.expectf(t, is4 && a4 == want, "%q resolved to %v, want %v", bind, addr, want, loc = loc)
}

@(private = "file")
expect_ip6 :: proc(t: ^testing.T, bind: string, want: net.IP6_Address, loc := #caller_location) {
	addr, ok := bind_to_address(bind)
	if !testing.expectf(t, ok, "%q was rejected", bind, loc = loc) {
		return
	}
	a6, is6 := addr.(net.IP6_Address)
	testing.expectf(t, is6 && a6 == want, "%q resolved to %v, want %v", bind, addr, want, loc = loc)
}

@(test)
test_bind_wildcards :: proc(t: ^testing.T) {
	expect_ip4(t, "", net.IP4_Any)
	expect_ip4(t, "   ", net.IP4_Any)
	expect_ip4(t, "0.0.0.0", net.IP4_Any)
	expect_ip4(t, " 0.0.0.0 ", net.IP4_Any)
	expect_ip6(t, "::", net.IP6_Any)
	expect_ip6(t, "[::]", net.IP6_Any)
	expect_ip6(t, "  ::  ", net.IP6_Any)
}

@(test)
test_bind_specific_addresses :: proc(t: ^testing.T) {
	expect_ip4(t, "127.0.0.1", net.IP4_Loopback)
	expect_ip4(t, "192.168.1.5", net.IP4_Address{192, 168, 1, 5})
	expect_ip4(t, " 10.0.0.2\t", net.IP4_Address{10, 0, 0, 2})
	expect_ip6(t, "::1", net.IP6_Loopback)
}

@(test)
test_bind_ipv6_in_brackets :: proc(t: ^testing.T) {
	// "[::]" is accepted as a wildcard, so the bracketed form of a concrete
	// address should work too.
	expect_ip6(t, "[::1]", net.IP6_Loopback)
}

@(test)
test_bind_invalid_addresses :: proc(t: ^testing.T) {
	for s in ([]string {
		"garbage",
		"256.0.0.1",
		"1.2.3",
		"1.2.3.4.5",
		"192.168.1.5:8080",
		"localhost",
		"example.com",
		"-1.0.0.1",
		"0.0.0.0/0",
		":::",
		"[::1",
		"0x7f000001",
	}) {
		addr, ok := bind_to_address(s)
		testing.expectf(t, !ok, "%q was accepted as %v", s, addr)
		testing.expectf(t, addr == nil, "%q returned a non-nil address %v along with ok=false", s, addr)
	}
}

// ---------------------------------------------------------------------------
// status_reason
// ---------------------------------------------------------------------------

@(test)
test_status_reason :: proc(t: ^testing.T) {
	testing.expect_value(t, status_reason(200), "OK")
	testing.expect_value(t, status_reason(302), "Found")
	testing.expect_value(t, status_reason(400), "Bad Request")
	testing.expect_value(t, status_reason(403), "Forbidden")
	testing.expect_value(t, status_reason(404), "Not Found")
	testing.expect_value(t, status_reason(405), "Method Not Allowed")
	testing.expect_value(t, status_reason(426), "Upgrade Required")
	testing.expect_value(t, status_reason(431), "Request Header Fields Too Large")
	testing.expect_value(t, status_reason(503), "Service Unavailable")
	testing.expect_value(t, status_reason(999), "Error")
}

} // when ODIN_TEST
