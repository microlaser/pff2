#!/bin/bash
# pfctl.sh - Minimal stealth ruleset for macOS (static IP, no IPv6)
# DNS stack: nslookup -> dnsmasq(127.0.0.1:53) -> stubby(:5300) -> Quad9:853 DoT
# Port 53 stays on loopback only (skipped by pf via set skip on lo0).
# Only port 853 (DoT) needs to be open externally.

set -e

CONF="/etc/pf.conf"
BACKUP="/etc/pf.conf.bak.$(date +%Y%m%d_%H%M%S)"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root (sudo $0)" >&2
  exit 1
fi

IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
if [[ -z "$IFACE" ]]; then
  echo "ERROR: could not detect default interface" >&2
  exit 1
fi
echo "[+] Detected primary interface: $IFACE"

cp "$CONF" "$BACKUP"
echo "[+] Backed up to $BACKUP"

printf '%s\n' \
'# /etc/pf.conf - minimal stealth ruleset' \
'# DNS chain: dnsmasq(lo:53) -> stubby(lo:5300) -> Quad9:853/DoT' \
'# Port 53 is loopback-only; pf only needs to pass port 853 externally.' \
'# block-policy drop = no RST/ICMP unreachable (invisible)' \
'' \
'set block-policy drop' \
'set skip on lo0' \
'' \
'# System anchor must precede block all' \
'anchor "com.apple/*"' \
'' \
'# Default deny (no quick = state table still consulted)' \
'block all' \
'' \
'# Hard blocks' \
'block quick inet6 all' \
'block quick inet proto { tcp udp } to   port 5353' \
'block quick inet proto { tcp udp } from port 5353' \
'' \
'# Outbound allowed services' \
'# 853  = DNS-over-TLS (stubby -> Quad9)' \
'# 123  = NTP' \
'# 80   = HTTP' \
'# 443  = HTTPS (tcp + udp/QUIC)' \
'pass out quick inet proto tcp to any port 853 keep state' \
'pass out quick inet proto udp to any port 123 keep state' \
'pass out quick inet proto tcp to any port 80  keep state' \
'pass out quick inet proto tcp to any port 443 keep state' \
'pass out quick inet proto udp to any port 443 keep state' \
'pass out quick inet proto icmp all keep state' \
'' \
'# Inbound: return traffic only (proto-explicit to avoid flags S/SA on UDP)' \
'pass in quick inet proto udp  keep state' \
'pass in quick inet proto tcp  keep state' \
'pass in quick inet proto icmp keep state' \
> "$CONF"

echo "[+] Ruleset written to $CONF"
echo ""
echo "=== Ruleset to be loaded ==="
cat "$CONF"
echo ""

echo "[+] Validating..."
if pfctl -nf "$CONF" 2>&1 | grep -iE "^[0-9]+:.*error|^pfctl: error"; then
  echo "ERROR: validation failed - restoring backup" >&2
  cp "$BACKUP" "$CONF"
  exit 1
fi
echo "[+] Validation passed"

pfctl -f "$CONF" 2>&1 | grep -iE "error|warning" || true
echo "[+] Rules loaded"
pfctl -e 2>/dev/null | grep -v "ALTQ" || echo "[~] pf already enabled"

echo ""
echo "=== Active ruleset (pfctl -sr) ==="
pfctl -sr 2>/dev/null | grep -v "ALTQ"

echo ""
echo "[+] Testing DNS (via dnsmasq -> stubby -> DoT)..."
sleep 1
if nslookup -timeout=5 google.com &>/dev/null; then
  echo "    [OK] DNS working"
else
  echo "    [FAIL] DNS broken - disabling pf and restoring backup"
  pfctl -d 2>/dev/null || true
  cp "$BACKUP" "$CONF"
  echo "    [!] pf disabled, backup restored: $BACKUP"
  exit 1
fi

echo "[+] Testing HTTPS..."
if curl -s --max-time 5 https://one.one.one.one &>/dev/null; then
  echo "    [OK] HTTPS working"
else
  echo "    [WARN] HTTPS test inconclusive"
fi

echo ""
echo "=== Sanity checks ==="
echo -n "  block-policy drop  : "; grep -q "set block-policy drop" "$CONF"              && echo "OK" || echo "MISSING"
echo -n "  com.apple anchor   : "; pfctl -sr 2>/dev/null | grep -q "com.apple"           && echo "OK" || echo "MISSING"
echo -n "  IPv6 blocked       : "; pfctl -sr 2>/dev/null | grep -q "block.*inet6"        && echo "OK" || echo "MISSING"
echo -n "  mDNS blocked       : "; pfctl -sr 2>/dev/null | grep -q "5353"                && echo "OK" || echo "MISSING"
echo -n "  DoT port 853       : "; pfctl -sr 2>/dev/null | grep "pass out" | grep -q "port = 853" && echo "OK" || echo "MISSING"
echo -n "  UDP inbound pass   : "; pfctl -sr 2>/dev/null | grep -q "pass in.*proto udp"  && echo "OK" || echo "MISSING"
echo -n "  TCP inbound pass   : "; pfctl -sr 2>/dev/null | grep -q "pass in.*proto tcp"  && echo "OK" || echo "MISSING"

echo ""
echo "[+] Done."
echo "    Reload : sudo pfctl -f $CONF"
echo "    Disable: sudo pfctl -d"
echo "    Enable : sudo pfctl -e"
