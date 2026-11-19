# NETWORKING — Emulator network topology + lockdown

## Topology

The SDK ships two NICs:

| NIC | Type | Guest IP | Purpose |
|---|---|---|---|
| eth0 | **NAT** | 10.0.2.15/24, gw 10.0.2.2 | Internet via NAT |
| eth1 | **Host-only** (SDK-managed) | 10.220.220.1/24 | VM↔VM (emulator ↔ build engine) |

## Internet-Only Lockdown (sf-netlock)

**The guest can reach the public internet but CANNOT reach the host LAN.**
This is enforced by **blackhole routes** (see SECURITY.md §2):

```
blackhole 10.0.0.0/8       ← blocks all 10.x (except more-specific routes)
blackhole 172.16.0.0/12    ← RFC1918 LAN
blackhole 192.168.0.0/16   ← RFC1918 LAN
blackhole 169.254.0.0/16   ← link-local
```

**Allowed (via longest-prefix-match):**
- `10.0.2.0/24` → VBox NAT (internet, DNS, guest additions)
- `10.220.220.0/24` → SDK build engine (host-only)

**Blocked:**
- Host LAN (192.168.x.x, 10.x.x.x non-VBox, 172.16.x.x)
- Link-local (169.254.x.x)
- Other VMs

**Why blackhole routes, not iptables?** Connman (SFOS network manager)
wipes iptables mangle/filter rules on service activation. Blackhole routes
are in the kernel routing table, which connman does NOT manage.

**Persistence:** `sf-netlock.service` (boot) + `sf-netlock.timer` (60s re-apply).
Auto-applies on every guest reboot.

## Verified facts

- **Guest → internet:** `curl https://www.google.com` → 200 ✓
- **Guest → LAN:** `ping 192.168.1.1` → "Invalid argument" (blackholed) ✓
- **Guest → build engine:** `ping 10.220.220.254` → reply ✓
- **DNS:** via systemd-resolved stub `127.0.0.53` (forwards to 10.0.2.3)
- **Default route:** `via 10.0.2.2` (VBox NAT proxy)

## Host → Guest (port forwards on 127.0.0.1)

Created by the SDK:
- `2223 → 22` — SSH
- `10234 → 10234` — QML live reload

Add your own:
```bash
VBoxManage modifyvm "<VM>" --natpf1 add myport,tcp,127.0.0.1,<HOST_PORT>,,<GUEST_PORT>
```

## Implications for app testing

- **Internet features:** Can be tested directly (app has `internet` permission).
- **Host dev servers:** NOT reachable from the guest (blackholed). If you need
  a local API, either:
  - Use a public test endpoint
  - Temporarily exempt the host IP (remove the blackhole, test, re-add)
  - Run the test server inside the guest
- **Sandboxed app networking:** Requires `internet` permission in manifest
  + sailjaild capability grant (deploy.sh handles both).

## Quick self-test

```bash
K="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
S() { ssh -p 2223 -i "$K" -o StrictHostKeyChecking=no -o BatchMode=yes root@127.0.0.1 "$@"; }
S 'curl -sS -m 8 -o /dev/null -w "internet: %{http_code}\n" https://www.google.com'
S 'ping -c1 -W2 192.168.1.1 2>&1 | grep -q "Invalid" && echo "LAN: BLOCKED" || echo "LAN: LEAK!"'
S 'ping -c1 -W2 10.220.220.254 2>&1 | grep -q "bytes" && echo "SDK: OK" || echo "SDK: FAIL"'
```
