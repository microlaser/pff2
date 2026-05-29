# secure_mac_dns

Encrypts all DNS queries on macOS using DNS-over-TLS (DoT) via [Quad9](https://quad9.net), and locks the firewall so plaintext DNS cannot leak from any application.

---

## Why this exists

By default, macOS sends DNS queries in plaintext UDP. Every query — every domain you visit — is visible to your ISP, router, and anyone on the local network. This script replaces that with an encrypted chain that your ISP cannot read and your router cannot intercept.

It is also a **required dependency** for the hardened `pf` firewall ruleset in this repo. The firewall blocks port 53 externally and only opens port 853 (DoT). Without this DNS stack running, the firewall will break name resolution entirely.

---

## How it works

```
Your apps
    │
    ▼
macOS resolver
    │  port 53 (loopback only — never leaves the machine)
    ▼
dnsmasq @ 127.0.0.1:53
    │  forwards to stubby on localhost
    ▼
stubby @ 127.0.0.1:5300
    │  TLS-encrypted, port 853
    ▼
Quad9 @ 9.9.9.9 / 149.112.112.112
```

**dnsmasq** sits on the standard port 53 so macOS and every application work without any configuration changes. It does no resolution itself — it just bridges queries to stubby.

**stubby** is a DNS-over-TLS stub resolver. It opens a persistent TLS connection to Quad9 on port 853, authenticates the server certificate (`dns.quad9.net`), and never falls back to plaintext. Query padding is enabled to reduce fingerprinting.

**Quad9** is a non-profit resolver that does not log or sell query data, and filters known malicious domains. Both the primary (`9.9.9.9`) and secondary (`149.112.112.112`) servers are configured for failover.

---

## Relationship to the pf firewall ruleset

The hardened `pfctl.sh` firewall in this repo is built around this DNS stack. The two are designed to work together:

| What the firewall does | Why |
|---|---|
| `set skip on lo0` | Loopback is unfiltered — dnsmasq and stubby communicate on `127.0.0.1` without pf interference |
| `block quick inet6 all` | All IPv6 dropped; DNS stack is IPv4-only |
| `block quick inet proto { tcp udp } to/from port 5353` | mDNS/Bonjour blocked in both directions |
| `pass out quick inet proto tcp to any port 853 keep state` | Stubby's outbound DoT connection to Quad9 — the **only** external DNS traffic |
| No `port 53` outbound rule | Intentional. Port 53 never leaves the machine. Anything trying to bypass the stack is silently dropped. |

If you run `pfctl.sh` without this DNS stack active, all name resolution will fail because:
- Port 53 outbound is blocked at the firewall
- Port 853 outbound is open, but nothing will be listening to use it

Run `setup_dns_privacy.sh` first, verify it passes all checks, then apply `pfctl.sh`.

---

## Installation

```bash
sudo bash setup_dns_privacy.sh
```

Requires macOS. Works on both Apple Silicon and Intel. Safe to run more than once — every step is idempotent.

The script will:

1. Install Homebrew if not present
2. Install and configure **stubby** (DoT daemon)
3. Install and configure **dnsmasq** (local DNS bridge)
4. Start both services via LaunchDaemons (survives reboots)
5. Lock every network interface to `127.0.0.1` as its DNS server
6. Install a pf anchor that blocks plaintext DNS leaks on port 53
7. Run a full verification suite

---

## Verification

The script runs these checks automatically at the end. You can re-run them manually at any time:

```bash
# Is the system resolver pointing to localhost?
scutil --dns | grep nameserver

# Is stubby resolving queries directly?
dig +short google.com @127.0.0.1 -p 5300

# Is dnsmasq bridging correctly?
dig +short google.com @127.0.0.1

# Is Quad9 confirmed as upstream?
dig +short id.server.on.quad9.net txt @127.0.0.1 -p 5300

# Is port 853 reachable outbound?
nc -z -w 4 9.9.9.9 853 && echo "open" || echo "blocked"

# Is plaintext DNS leaking? (watch for 5 seconds)
sudo tcpdump -i any -nn udp port 53 or tcp port 53 &
sleep 5 && sudo kill %1
# Any line NOT from 127.0.0.1 is a leak
```

---

## What gets installed

| Component | Location |
|---|---|
| stubby config | `/opt/homebrew/etc/stubby/stubby.yml` |
| dnsmasq config | `/opt/homebrew/etc/dnsmasq.conf` |
| stubby LaunchDaemon | `/Library/LaunchDaemons/homebrew.mxcl.stubby.plist` |
| dnsmasq LaunchDaemon | `/Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist` |
| pf anchor rules | `/etc/pf.anchors/dns_privacy` |
| pf reload daemon | `/Library/LaunchDaemons/com.dns-privacy.pf-anchor.plist` |
| Backups | `/var/backups/dns_privacy_<timestamp>/` |

---

## Troubleshooting

**stubby won't start**
```bash
cat /var/log/stubby_err.log
```

**dnsmasq won't start**
```bash
cat /var/log/dnsmasq_err.log
```

**DNS broken after applying pfctl.sh**
```bash
# Confirm the DNS stack is running before enabling the firewall
pgrep -x stubby  && echo "stubby OK"  || echo "stubby NOT running"
pgrep -x dnsmasq && echo "dnsmasq OK" || echo "dnsmasq NOT running"

# Reload the firewall
sudo pfctl -f /etc/pf.conf

# Confirm port 853 is passing
sudo pfctl -sr | grep 853
```

**Name resolution fails with pf enabled but DNS stack is running**
```bash
# Check that stubby is actually reaching Quad9 on port 853
nc -z -w 4 9.9.9.9 853 && echo "853 open" || echo "853 BLOCKED by pf"

# If blocked, verify pfctl.sh has the port 853 pass rule loaded
sudo pfctl -sr | grep "port = 853"
```

**Revert everything**
```bash
# Stop services
sudo launchctl unload /Library/LaunchDaemons/homebrew.mxcl.stubby.plist
sudo launchctl unload /Library/LaunchDaemons/homebrew.mxcl.dnsmasq.plist

# Restore pf.conf from backup
sudo cp /var/backups/dns_privacy_<timestamp>/pf.conf /etc/pf.conf
sudo pfctl -f /etc/pf.conf

# Reset network interfaces to DHCP DNS
sudo networksetup -setdnsservers "Wi-Fi" "Empty"
```

---

## Privacy properties

| Property | Status |
|---|---|
| Queries encrypted in transit | ✓ TLS 1.3 to Quad9 |
| Resolver authenticates server cert | ✓ `tls_auth_name: dns.quad9.net` |
| Falls back to plaintext | ✗ Never (`GETDNS_AUTHENTICATION_REQUIRED`) |
| Query padding | ✓ 128-byte blocks (reduces fingerprinting) |
| EDNS Client Subnet | ✗ Disabled (`edns_client_subnet_private: 1`) |
| Resolver logs queries | ✗ Quad9 privacy policy: no query logging |
| Plaintext DNS blocked at firewall | ✓ port 53 outbound blocked externally |
| mDNS/Bonjour blocked | ✓ port 5353 blocked in both directions |
| IPv6 DNS exposure | ✗ IPv6 fully blocked at firewall |

---

## Related tools

This script is part of a broader security stack:

- [`pfctl.sh`](pfctl.sh) — hardened pf firewall ruleset (requires this DNS stack)
- [`net_exploit_detector.py`](https://github.com/microlaser/net_exploit_detector) — network anomaly detector
- [`wifi-guardian`](https://github.com/microlaser/wifi-guardian) — evil twin AP detector
- [`apt_detector_improved`](https://github.com/microlaser/apt_detector_improved) — macOS APT/malware detector
