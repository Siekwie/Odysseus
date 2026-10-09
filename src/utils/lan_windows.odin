package utils

import "core:net"

// lan_addresses fills out with this machine's IPv4 addresses that other
// devices on the network can reach (no loopback, no link-local) and returns how many.
lan_addresses :: proc(out: [][4]u8) -> int {
	interfaces, err := net.enumerate_interfaces(context.temp_allocator)
	if err != nil {
		return 0
	}
	n := 0
	for iface in interfaces {
		if .Up not_in iface.link.state || .Loopback in iface.link.state {
			continue
		}
		for lease in iface.unicast {
			ip, is_ip4 := lease.address.(net.IP4_Address)
			if !is_ip4 || !lan_address_usable(([4]u8)(ip)) || n >= len(out) {
				continue
			}
			out[n] = ([4]u8)(ip)
			n += 1
		}
	}
	return n
}
