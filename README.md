# pff2

Extreme hardening ruleset for the macOS `pf` firewall. Blocks all IPv6, all mDNS, and all unsolicited inbound traffic. The machine produces no RST or ICMP unreachable replies — it is invisible on the network.

**This ruleset will break DNS if you run it alone.** It requires the encrypted DNS stack described below.

---

## Prerequisite: encrypted DNS

`pfctl2.sh` opens port 853 (DNS-over-TLS) and blocks port 53 externally. This is intentional — plaintext DNS never leaves the machine. But it means your system DNS must be routed through a local DoT proxy, or name resolution will fail entirely.

Install the DNS stack first:

```bash
git clone https://github.com/microlaser/secure_mac_dns
cd secure_mac_dns
sudo bash setup_dns_privacy.sh
```

That script installs and configures:

- **stubby** — DNS-over-TLS daemon, listens on `127.0.0.1:5300`, connects to Quad9 (`9.9.9.9`) on port 853 with TLS certificate verification. Never falls back to plaintext.
- **dnsmasq** — bridges macOS system DNS (port 53, loopback only) to stubby on port 5300
- **LaunchDaemons** for both, so they survive reboots
- **Interface lock** — every network adapter set to `127.0.0.1` as its resolver so DHCP cannot override it

The full chain once configured:

```
Any app → dnsmasq @ 127.0.0.1:53 → stubby @ 127.0.0.1:5300 → Quad9 @ 9.9.9.9:853 (TLS)
```

Both dnsmasq and stubby live on loopback. The `pf` ruleset skips loopback entirely (`set skip on lo0`), so port 53 traffic never touches the firewall. The only external DNS traffic is stubby's outbound TLS connection on port 853, which the ruleset explicitly passes.

Verify the DNS stack is working before applying the firewall:

```bash
# Stubby resolving directly
dig +short google.com @127.0.0.1 -p 5300

# Full chain through dnsmasq
dig +short google.com @127.0.0.1

# Quad9 confirmed as upstream
dig +short id.server.on.quad9.net txt @127.0.0.1 -p 5300

# Port 853 reachable
nc -z -w 4 9.9.9.9 853 && echo "open" || echo "BLOCKED"
```

All four must pass before proceeding.

---

## Installation

```bash
sudo bash pfctl2.sh
```

The script backs up your existing `/etc/pf.conf` with a timestamp before writing anything. If the DNS connectivity test fails after loading, it automatically disables pf and restores the backup.

---

## What the ruleset does

```
set block-policy drop       # No RST or ICMP unreachable — machine is invisible
set skip on lo0             # Loopback unfiltered (dnsmasq/stubby live here)
anchor "com.apple/*"        # Preserve macOS system rules
block all                   # Default deny
block quick inet6 all       # All IPv6 dropped
block quick ... port 5353   # mDNS/Bonjour blocked both directions
pass out ... port 853       # DNS-over-TLS to Quad9 (stubby's only external port)
pass out ... port 123       # NTP
pass out ... port 80/443    # HTTP/HTTPS
pass out ... icmp            # Outbound ping/traceroute
pass in  ... keep state     # Return traffic for established sessions only
```

Nothing reaches the machine unsolicited. There are no open inbound ports. The `pass in` rules only admit packets that match an existing outbound state table entry.

---

## Troubleshooting

**DNS broken after running pfctl2.sh**

The DNS stack is not running. Check:

```bash
pgrep -x stubby  && echo "OK" || echo "stubby not running"
pgrep -x dnsmasq && echo "OK" || echo "dnsmasq not running"
```

If either is down, re-run `setup_dns_privacy.sh` from the [secure_mac_dns](https://github.com/microlaser/secure_mac_dns) repo.

**Networking broken, need to recover**

```bash
sudo pfctl -d                          # Disable pf immediately
sudo pfctl -f /etc/pf.conf             # Reload after fixing
```

**Verify active ruleset**

```bash
sudo pfctl -sr
```

---

## Related projects

- [secure_mac_dns](https://github.com/microlaser/secure_mac_dns) — DNS-over-TLS stack (required dependency)
- [apt_detector_improved](https://github.com/microlaser/apt_detector_improved) — C-based APT/malware detector for macOS
- [apt_detector_linux](https://github.com/microlaser/apt_detector_linux) — Python malware scanner for Linux (aarch64/x86-64)
- [Standalone_WiFi_Scanner](https://github.com/microlaser/Standalone_WiFi_Scanner) — command-line Wi-Fi scanner for Linux, no NetworkManager dependency
- [wifi-guardian](https://github.com/microlaser/wifi-guardian) — evil twin AP detector for macOS (CoreWLAN) and Windows (netsh)
- [net_exploit_detector](https://github.com/microlaser/net_exploit_detector) — zero-dependency Python network anomaly detector using tcpdump
