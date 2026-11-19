#!/bin/sh
# sf-netlock.sh — INTERNET-ONLY egress for the SFOS emulator (idempotent).
#
# MECHANISM: BLACKHOLE ROUTES (ip route), NOT iptables.
#   Why: connman (SFOS network manager) saves/restores iptables tables on
#   every service activation, which WIPES mangle rules within ~2 minutes
#   (verified in journal: "connman_iptables_restore() cannot restore table mangle").
#   Blackhole routes live in the kernel routing table, which connman does NOT
#   manage. Verified: routes persist through connman restarts and reboots
#   (re-applied by sf-netlock.service + sf-netlock.timer).
#
#   Exemptions are automatic via longest-prefix-match:
#     10.0.2.0/24 (24-bit kernel route) beats 10.0.0.0/8 (8-bit blackhole)
#     10.220.220.0/24 (24-bit kernel route) beats 10.0.0.0/8 (8-bit blackhole)
#   No ESTABLISHED rules needed — routing happens before netfilter.
#
# BLOCKED (blackholed):
#   10.0.0.0/8       everything in 10.x EXCEPT 10.0.2.0/24 and 10.220.220.0/24
#   172.16.0.0/12    RFC1918 LAN
#   192.168.0.0/16   RFC1918 LAN
#   169.254.0.0/16   link-local
#
# ALLOWED:
#   public internet    via NAT (default route via 10.0.2.2)
#   10.0.2.0/24        VBox NAT plumbing (gateway .2, DNS .3, guest-additions .1)
#   10.220.220.0/24    SDK host-only network (emulator ↔ build engine)
#
# WHY (see SECURITY.md §2): the emulator runs on the SAME host as dev tools
# (LM Studio, Bionic APIs, dev servers on 127.0.0.1). Without this lockdown,
# any guest process — including a malicious app — could reach host services.
#
# PERSISTENCE: sf-netlock.service (at boot) + sf-netlock.timer (every 60s).
#   Routes are NOT persistent across reboots — the units ensure re-application.
#   The timer is a safety net in case a network event clears routes.
#
# SAFETY: idempotent — uses `ip route replace` (adds if missing, no-op if
#   present). Safe to re-run any time from any context (boot, timer, manual).

set -eu

BLOCK_RANGES="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16"

for RANGE in $BLOCK_RANGES; do
    ip route replace blackhole "$RANGE" 2>/dev/null || true
done

# ── Verify (warn, don't hard-fail — the timer will re-apply) ──
ROUTE_TABLE=$(ip route show)

echo "$ROUTE_TABLE" | grep -q "blackhole 192.168.0.0/16" || \
    echo "sf-netlock: WARNING: 192.168/16 blackhole not in route table" >&2
echo "$ROUTE_TABLE" | grep -q "blackhole 10.0.0.0/8" || \
    echo "sf-netlock: WARNING: 10/8 blackhole not in route table" >&2
echo "$ROUTE_TABLE" | grep -q "10.0.2.0/24" || \
    echo "sf-netlock: WARNING: 10.0.2.0/24 kernel route missing (NAT broken?)" >&2

echo "sf-netlock: internet-only egress active (blackhole routes)"
ip route show | grep -E "blackhole|10\.0\.2\.0/24|10\.220\.220\.0/24" | sed 's/^/  /'
