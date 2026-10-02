#+build !windows
package utils

import "core:c"

foreign import libc "system:c"

// Leading fields of struct ifaddrs, identical on Linux, macOS and the BSDs.
@(private)
Ifaddrs :: struct {
	next:    ^Ifaddrs,
	name:    cstring,
	flags:   c.uint,
	addr:    ^Sockaddr_In,
	netmask: rawptr,
}

// struct sockaddr_in. The BSDs (and macOS) put a length byte before an 8-bit family.
when ODIN_OS == .Linux {
	@(private)
	Sockaddr_In :: struct {
		family: u16,
		port:   u16,
		addr:   [4]u8,
	}
} else {
	@(private)
	Sockaddr_In :: struct {
		len:    u8,
		family: u8,
		port:   u16,
		addr:   [4]u8,
	}
}

@(private)
AF_INET :: 2
@(private)
IFF_UP :: 0x1
@(private)
IFF_LOOPBACK :: 0x8

@(default_calling_convention = "c")
foreign libc {
	getifaddrs :: proc(ifap: ^^Ifaddrs) -> c.int ---
	freeifaddrs :: proc(ifa: ^Ifaddrs) ---
}

// lan_addresses fills out with this machine's IPv4 addresses that other
// devices on the network can reach (no loopback, no link-local) and returns how many.
lan_addresses :: proc(out: [][4]u8) -> int {
	list: ^Ifaddrs
	if getifaddrs(&list) != 0 {
		return 0
	}
	defer freeifaddrs(list)

	n := 0
	for ifa := list; ifa != nil; ifa = ifa.next {
		if ifa.addr == nil || ifa.flags & IFF_UP == 0 || ifa.flags & IFF_LOOPBACK != 0 {
			continue
		}
		if int(ifa.addr.family) != AF_INET || !lan_address_usable(ifa.addr.addr) || n >= len(out) {
			continue
		}
		out[n] = ifa.addr.addr
		n += 1
	}
	return n
}
