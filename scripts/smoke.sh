#!/usr/bin/env bash
# ═════════════════════════════════════════════════════════════
# smoke.sh — Smoke-test suite for the SFOS skill (and the live pipeline)
#
#   bash scripts/smoke.sh          # T0 static + T1 guest health (default)
#   bash scripts/smoke.sh --fast   # T0 static only (no VMs needed, ~15s)
#   bash scripts/smoke.sh --all    # T0 + T1 + T2 end-to-end canary (~2-4 min)
#
# Tiers:
#   T0  static checks: script syntax, repo hygiene, genericity scan,
#       installer hash gate, lock contract, uninstall dry-run safety.
#       No VMs required — safe to run anywhere the repo exists.
#   T1  live guest health: VMs up, SSH, single vts, shim mapped,
#       resolution, netlock (egress allowed / LAN blocked), vts root-only.
#   T2  end-to-end: build + deploy + launch the dedicated canary app
#       (apps/sfsmoke), verify the screen is alive, prove taps change
#       the UI (counter 0 → 3 via pixel diff), journal free of QML errors.
#       Holds the pipeline lock for its duration (released on exit).
#
# Exit code: 0 = all PASS (or SKIP with no FAIL), 1 = at least one FAIL.
# Strict by design: there is no WARN tier — a broken pipeline is a FAIL.
#
# Environment overrides (same names as the other scripts):
#   SSH_PORT, SSH_KEY, SSH_USER, SSH_HOST, SFDK, SCREEN_W, SCREEN_H,
#   SDK_INSTALL_DIR, DOWNLOAD_DIR, SFOSSKILL_LOCK_FILE
# ═════════════════════════════════════════════════════════════
set -u

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPTS_DIR/.." && pwd)"

# ── Config ─────────────────────────────────────────────────────
SSH_PORT="${SSH_PORT:-2223}"
SSH_KEY="${SSH_KEY:-$HOME/SailfishOS/vmshare/ssh/private_keys/sdk}"
SSH_USER="${SSH_USER:-root}"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SFDK="${SFDK:-$HOME/.local/bin/sfdk}"
SDK_DIR="${SDK_INSTALL_DIR:-$HOME/SailfishOS}"
DL_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
SCREEN_W="${SCREEN_W:-1088}"
SCREEN_H="${SCREEN_H:-2260}"
ENGINE_VM="Sailfish SDK Build Engine"
# Emulator VM: auto-detect (name encodes the SDK version), overridable.
EMUL_VM="${VM_NAME:-}"
if [[ -z "$EMUL_VM" ]] && command -v VBoxManage >/dev/null 2>&1; then
    EMUL_VM=$(VBoxManage list vms 2>/dev/null | sed -n 's/^"\([^"]*SailfishOS[^"]*\)".*/\1/p' | head -1)
fi
CANARY_APP="harbour-sfsmoke"
CANARY_DIR="$REPO/apps/sfsmoke"
WORK="$(mktemp -d /tmp/sfos-smoke.XXXXXX)"

TIER="${1:---default}"
case "$TIER" in
    --fast)  RUN_T1=0; RUN_T2=0 ;;
    --all)   RUN_T1=1; RUN_T2=1 ;;
    --default|-h|--help|"")
        [[ "$TIER" == "--help" || "$TIER" == "-h" ]] && { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
        RUN_T1=1; RUN_T2=0 ;;
    *) echo "Unknown option: $TIER (use --fast | --all | --help)" >&2; exit 2 ;;
esac

# ── Test harness ───────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
RESULTS=()
LOCK_HELD=0

cleanup() {
    if [[ "$LOCK_HELD" == 1 ]]; then
        bash "$SCRIPTS_DIR/lock.sh" release >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

t_pass() { RESULTS+=("PASS  $1"); PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
t_fail() { RESULTS+=("FAIL  $1"); FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
t_skip() { RESULTS+=("SKIP  $1"); SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s — %s\n' "$1" "${2:-}"; }

# Run a test function; non-zero return = FAIL.
run_test() {  # <id> <description> <function>
    local id="$1" desc="$2" fn="$3"
    if ! command -v VBoxManage >/dev/null 2>&1 && [[ "$id" != T0.* ]]; then
        t_skip "$id $desc" "VirtualBox not available"
        return
    fi
    local out rc=0
    out="$( "$fn" 2>&1 )" || rc=$?
    if [[ $rc -eq 0 ]]; then
        t_pass "$id $desc"
    elif [[ $rc -eq 2 ]]; then
        t_skip "$id $desc"
    else
        [[ -n "$out" ]] && sed 's/^/        /' <<<"$out"
        t_fail "$id $desc"
    fi
    return 0
}

# ── Guest SSH helper ───────────────────────────────────────────
guest() {
    ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no \
        -o BatchMode=yes -o ConnectTimeout=8 "$SSH_USER@$SSH_HOST" "$@"
}

# SDK "shared source" path: the only host tree the build-engine VM can
# see (sfdk workspace). Parsed from the engine config; fallback $HOME.
shared_src_dir() {
    local cfg="$HOME/.config/SailfishSDK/libsfdk/buildengines.xml" v=""
    if [[ -f "$cfg" ]]; then
        v=$(sed -n 's|.*key="SharedSrc">\([^<]*\)</value>.*|\1|p' "$cfg" | head -1)
    fi
    if [[ -n "$v" ]]; then printf '%s' "$v"; else printf '%s' "$HOME"; fi
}

# ═════════════════════════════════════════════════════════════
# T0 — static (no VMs required)
# ═════════════════════════════════════════════════════════════
t0_1_syntax() {
    local f rc=0
    for f in "$SCRIPTS_DIR"/*.sh; do
        bash -n "$f" || { echo "bash -n failed: $f"; rc=1; }
    done
    for f in "$REPO/tools"/*.sh; do
        bash -n "$f" || { echo "bash -n failed: $f"; rc=1; }
    done
    for f in "$REPO/tools"/*.py; do
        python3 -m py_compile "$f" 2>/dev/null || { echo "py_compile failed: $f"; rc=1; }
    done
    rm -rf "$REPO/tools/__pycache__"   # py_compile litter — never leave it
    return $rc
}

t0_2_repo_hygiene() {
    local rc=0 p
    # Every scripts/ | tools/ | apps/ path referenced in the docs must exist.
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        [[ -e "$REPO/$p" ]] || { echo "doc references missing path: $p"; rc=1; }
    done < <(grep -ohE '(scripts|tools|apps)/[A-Za-z0-9._/-]+' "$REPO/SKILL.md" "$REPO/README.md" \
             2>/dev/null | tr -d '`' | sort -u)
    # Every .md named in SKILL.md must exist.
    while IFS= read -r p; do
        [[ -e "$REPO/$p" ]] || { echo "SKILL.md references missing doc: $p"; rc=1; }
    done < <(grep -ohE '[A-Za-z][A-Za-z0-9-]*\.md' "$REPO/SKILL.md" | sort -u)
    # No build artifacts may be tracked by git.
    local bad
    bad=$(git -C "$REPO" ls-files 2>/dev/null | grep -E \
        '(^|/)(RPMS|\.sfdk|shots|__pycache__)/|(^|/)Makefile$|\.o$|(^|/)tools/vts$|tools/[^/]*\.so$|qrc_[A-Za-z0-9_]+\.cpp$|(^|/)(harbour-cpp|harbour-sfsmoke)$' \
        || true)
    if [[ -n "$bad" ]]; then
        echo "tracked build artifacts:"; sed 's/^/        /' <<<"$bad"; rc=1
    fi
    return $rc
}

t0_3_genericity() {
    # No personal paths, personal repo owners, or non-allowlisted IPs.
    # Allowlist rationale: 127.0.0.1 (loopback), 10.0.2.0/24 (VBox NAT),
    # 10.220.220.0/24 (SDK host-only), 169.254.0.0/16 (link-local),
    # 192.168.1.1 (generic doc example), any CIDR range (documented ranges).
    { git -C "$REPO" ls-files; git -C "$REPO" ls-files --others --exclude-standard; } | sort -u | python3 - "$REPO" <<'PYEOF'
import re, sys, os, ipaddress

repo = sys.argv[1]
# mersdk = the SDK docker image's INTERNAL build-user home (build-phone.sh
# mounts into /home/mersdk/proj) — a well-known SDK constant, NOT a host
# personal path, so it is allowlisted.
ALLOW_NAMES = re.compile(r'^(defaultuser|root|example|user|users|ozzi|ozzi-|username|youruser|mersdk)$', re.I)
ALLOW_NETS = [ipaddress.ip_network(n) for n in
              ('127.0.0.0/8', '10.0.2.0/24', '10.220.220.0/24', '169.254.0.0/16', '0.0.0.0/32')]
ALLOW_IPS = {ipaddress.ip_address('192.168.1.1'), ipaddress.ip_address('255.255.255.255')}

home_re = re.compile(r'/(?:home|Users)/([A-Za-z0-9_.-]+)/')
gh_re   = re.compile(r'github\.com/([A-Za-z0-9_.-]+)/')
ip_re   = re.compile(r'(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])')

findings = []
for line in sys.stdin:
    f = line.strip()
    if not f:
        continue
    path = os.path.join(repo, f)
    try:
        data = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        continue
    for m in home_re.finditer(data):
        if not ALLOW_NAMES.match(m.group(1)):
            findings.append(f'{f}: personal path /home|Users/{m.group(1)}/')
    for m in gh_re.finditer(data):
        if m.group(1) not in ('ozzi-',):
            findings.append(f'{f}: github.com/{m.group(1)}/ (non-skill repo)')
    for m in ip_re.finditer(data):
        rest = data[m.end():m.end()+3]
        if rest.startswith('/') and rest[1:2].isdigit():
            continue  # CIDR range notation — documented block ranges
        try:
            ip = ipaddress.ip_address(m.group(1))
        except ValueError:
            continue
        if ip in ALLOW_IPS or any(ip in n for n in ALLOW_NETS):
            continue
        findings.append(f'{f}: non-allowlisted IP {m.group(1)}')

if findings:
    print('genericity findings:')
    for x in findings[:25]:
        print('   ', x)
    sys.exit(1)
PYEOF
}

t0_4_hash_gate() {
    local f="$SCRIPTS_DIR/setup-sdk.sh" rc=0
    grep -q 'EXPECTED_SHA256=' "$f"          || { echo "no EXPECTED_SHA256 gate"; rc=1; }
    grep -q 'MISMATCH' "$f"                  || { echo "no MISMATCH refusal"; rc=1; }
    grep -q 'SKIP_HASH_CHECK' "$f"           || { echo "no SKIP_HASH_CHECK opt-out"; rc=1; }
    # Gate must run BEFORE the installer is launched.
    local l_hash l_run
    l_hash=$(grep -n 'ACTUAL_SHA256' "$f" | head -1 | cut -d: -f1)
    l_run=$(grep -n '=== Running installer ===' "$f" | head -1 | cut -d: -f1)
    if [[ -n "$l_hash" && -n "$l_run" && "$l_hash" -gt "$l_run" ]]; then
        echo "hash check runs AFTER installer launch (wrong order)"; rc=1
    fi
    return $rc
}

t0_5_lock_contract() {
    # Isolated lock file so the real pipeline lock is never touched.
    local LF="$WORK/t05.lock"
    export SFOSSKILL_LOCK_FILE="$LF"
    local rc=0

    check_exit() {  # <expected> <actual> <what>
        if [[ "$1" != "$2" ]]; then
            echo "${3:-check}: expected exit $1, got $2"; rc=1
        fi
    }

    # 1) Guarded scripts must refuse without the lock (exit 75).
    bash "$SCRIPTS_DIR/tap.sh" 10 10 >/dev/null 2>&1;            check_exit 75 $? "tap.sh without lock"
    bash "$SCRIPTS_DIR/swipe.sh" 0 0 10 10 >/dev/null 2>&1;      check_exit 75 $? "swipe.sh without lock"
    bash "$SCRIPTS_DIR/deploy.sh" "$CANARY_DIR" >/dev/null 2>&1; check_exit 75 $? "deploy.sh without lock"
    bash "$SCRIPTS_DIR/apply-input.sh" >/dev/null 2>&1;          check_exit 75 $? "apply-input.sh without lock"

    # 2) Hold works; status reports LOCKED; a second hold is refused.
    bash "$SCRIPTS_DIR/lock.sh" hold 1 >/dev/null 2>&1 || { echo "hold failed"; rc=1; }
    bash "$SCRIPTS_DIR/lock.sh" status >/dev/null 2>&1; check_exit 1 $? "status while held"
    bash "$SCRIPTS_DIR/lock.sh" hold 1 >/dev/null 2>&1; check_exit 1 $? "second hold (must be refused)"

    # 3) MINUTES contract: "hold 1" must still be held after 8 seconds
    #    (regression guard: holder used to sleep MIN *seconds*, so the lock
    #    silently expired mid-workflow).
    sleep 8
    bash "$SCRIPTS_DIR/lock.sh" status >/dev/null 2>&1; check_exit 1 $? "held after 8s (minutes contract)"

    # 4) Kernel release-on-death: kill the holder → lock must free up.
    local holder
    holder=$(cat "$LF.holder" 2>/dev/null || true)
    if [[ -n "$holder" ]]; then
        kill -9 -- "-$holder" 2>/dev/null || kill -9 "$holder" 2>/dev/null || true
        sleep 0.5
    fi
    bash "$SCRIPTS_DIR/lock.sh" status >/dev/null 2>&1; check_exit 0 $? "status after holder death (auto-expire)"

    # 5) release is idempotent.
    bash "$SCRIPTS_DIR/lock.sh" release >/dev/null 2>&1; check_exit 0 $? "release (idempotent)"
    rm -f "$LF" "$LF.holder"
    return $rc
}

t0_6_uninstall_dryrun() {
    command -v VBoxManage >/dev/null 2>&1 || return 0   # nothing to protect
    local before="$WORK/uninst-before" after="$WORK/uninst-after"
    fingerprint() {
        { find "$SDK_DIR" -maxdepth 2 2>/dev/null
          ls "$DL_DIR" 2>/dev/null
          [[ -f "$HOME/.local/bin/sfdk" ]] && md5sum < "$HOME/.local/bin/sfdk"
          for vm in $(VBoxManage list vms 2>/dev/null | sed -n 's/^"\([^"]*\)".*/\1/p'); do
              echo "VM: $vm"
              VBoxManage showvminfo "$vm" 2>/dev/null | grep -iE '^State:'
          done
        } | sort
    }
    fingerprint > "$before"

    local out rc
    out=$(bash "$SCRIPTS_DIR/uninstall.sh" 2>&1); rc=$?
    [[ $rc -eq 0 ]] || { echo "uninstall dry-run exited $rc:"; sed 's/^/   /' <<<"$out" | tail -5; return 1; }

    fingerprint > "$after"
    local lost
    lost=$(comm -23 "$before" "$after")
    if [[ -n "$lost" ]]; then
        echo "DRY-RUN DELETED/CHANGED entries (must be empty):"; sed 's/^/   /' <<<"$lost"; return 1
    fi
    # Every non-SFOS VM must be explicitly reported as untouched.
    local vm rc2=0
    while IFS= read -r vm; do
        [[ -z "$vm" ]] && continue
        if [[ "$vm" != "Sailfish SDK Build Engine" && ! "$vm" =~ ^SailfishOS- ]]; then
            grep -qF "never touched: $vm" <<<"$out" || { echo "non-SFOS VM not marked untouched: $vm"; rc2=1; }
        fi
    done < <(VBoxManage list vms 2>/dev/null | sed -n 's/^"\([^"]*\)".*/\1/p')
    return $rc2
}

t0_7_spec_parser() {
    # The app-name resolver (scripts/lib-spec.sh) must handle every common
    # spec form — the reviewer's real-world app used `Name: %{appname}` +
    # `%define appname …`, which the old `grep '%define name'` never matched.
    local T rc=0
    T=$(mktemp -d)
    source "$SCRIPTS_DIR/lib-spec.sh"
    printf 'Name:           harbour-alpha\nVersion:  1.2.3\nRelease: 4\n' > "$T/s1.spec"
    printf '%%define name harbour-beta\n%%define version 2.0.0\nName:           %%{name}\nVersion:        %%{version}\n' > "$T/s2.spec"
    printf '%%define appname harbour-bionic-remote\nName:           %%{appname}\n' > "$T/s3.spec"
    printf 'Name: %%{name}\n' > "$T/harbour-orphan.spec"   # broken macro -> filename

    chk() { local got want label; got="$1"; want="$2"; label="$3"
        if [[ "$got" == "$want" ]]; then :; else printf '  BAD %-28s -> %q (want %q)\n' "$label" "$got" "$want"; rc=1; fi; }

    chk "$(spec_app_name "$T/s1.spec")"            "harbour-alpha"         "literal Name:"
    chk "$(spec_app_name "$T/s2.spec")"            "harbour-beta"          "Name: %{name}+define"
    chk "$(spec_app_name "$T/s3.spec")"            "harbour-bionic-remote" "Name: %{appname}+define"
    chk "$(spec_app_name "$T/harbour-orphan.spec")" "harbour-orphan"      "filename fallback"
    chk "$(spec_app_name "$CANARY_DIR/rpm/harbour-sfsmoke.spec")" "harbour-sfsmoke" "bundled canary spec"
    chk "$(spec_app_version "$T/s2.spec")"         "2.0.0"               "version resolve"
    rm -rf "$T"
    return $rc
}

t0_8_build_phone_dryrun() {
    # build-phone.sh: --help exits 0; --dry-run resolves name+version and shows
    # the docker/mb2 plan WITHOUT touching docker (safe on any host).
    local rc=0 out
    bash "$SCRIPTS_DIR/build-phone.sh" --help >/dev/null 2>&1 || { echo "--help exited non-zero"; rc=1; }
    out=$(bash "$SCRIPTS_DIR/build-phone.sh" "$CANARY_DIR" --dry-run 2>&1) || { echo "dry-run exited non-zero:"; sed 's/^/   /' <<<"$out" | tail -8; return 1; }
    grep -q  "harbour-sfsmoke" <<<"$out" || { echo "dry-run did not resolve the app name"; rc=1; }
    grep -qi "docker run"      <<<"$out" || { echo "dry-run did not show the docker command"; rc=1; }
    grep -qi "mb2 build"       <<<"$out" || { echo "dry-run did not show the mb2 build"; rc=1; }
    grep -q  "nothing was built" <<<"$out" || { echo "dry-run missing its 'nothing was built' marker"; rc=1; }
    return $rc
}

# ═════════════════════════════════════════════════════════════
# T1 — live guest health (needs emulator + engine running)
# ═════════════════════════════════════════════════════════════
t1_1_vms_running() {
    command -v VBoxManage >/dev/null 2>&1 || return 0
    local rc=0
    for vm in "$EMUL_VM" "$ENGINE_VM"; do
        [[ -n "$vm" ]] || { echo "no VM name resolved (emulator?)"; rc=1; continue; }
        VBoxManage showvminfo "$vm" 2>/dev/null | grep -qiE '^State:[[:space:]]+running' \
            || { echo "VM not running: $vm"; rc=1; }
    done
    return $rc
}

t1_2_ssh_and_key() {
    local rc=0
    guest "true" || { echo "guest SSH (port $SSH_PORT) unreachable"; rc=1; }
    local mode
    mode=$(stat -c '%a' "$SSH_KEY" 2>/dev/null)
    [[ "$mode" == "600" ]] || { echo "SSH key mode is $mode (want 600)"; rc=1; }
    return $rc
}

t1_3_single_vts() {
    local n
    n=$(guest 'ps -eo pid,comm | awk '"'"'$2=="vts"'"'"' | wc -l')
    [[ "$n" == "1" ]] || { echo "vts daemons: $n (want exactly 1)"; return 1; }
}

t1_4_shim_mapped() {
    local n lmode rc=0
    n=$(guest 'LPID=$(ps -eo pid,comm | awk '"'"'$2=="lipstick"{print $1; exit}'"'"'); grep -c vboxfake /proc/$LPID/maps 2>/dev/null')
    if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 5 )); then
        echo "shim maps in lipstick: ${n:-0} (want >= 5)"; rc=1
    fi
    lmode=$(guest 'stat -c "%A" /usr/bin/lipstick')
    if [[ "${lmode:5:1}" == "s" || "${lmode:5:1}" == "S" ]]; then
        echo "lipstick is setgid: $lmode (want plain -rwxr-xr-x)"; rc=1
    fi
    return $rc
}

t1_5_resolution() {
    local v
    v=$(guest 'cat /sys/class/graphics/fb0/virtual_size')
    [[ "$v" == "$SCREEN_W,$SCREEN_H" ]] || { echo "fb0 = $v (want $SCREEN_W,$SCREEN_H)"; return 1; }
}

t1_6_netlock() {
    local rc=0 code
    # All four blackhole routes present.
    local routes
    routes=$(guest 'ip route show | grep blackhole')
    for r in "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "169.254.0.0/16"; do
        grep -q "blackhole $r" <<<"$routes" || { echo "missing blackhole: $r"; rc=1; }
    done
    # Internet egress works.
    code=$(guest 'curl -s -m 15 -o /dev/null -w "%{http_code}" https://example.com' 2>/dev/null)
    [[ "$code" == "200" ]] || { echo "public egress: HTTP $code (want 200)"; rc=1; }
    # LAN is unreachable (curl must fail fast).
    if guest 'curl -s -m 5 -o /dev/null http://192.168.1.1' 2>/dev/null; then
        echo "LAN 192.168.1.1 is REACHABLE — netlock broken"; rc=1
    fi
    return $rc
}

t1_7_vts_rootonly() {
    local before after rc=0
    before=$(guest 'wc -l < /tmp/vts.log')
    guest 'su defaultuser -s /bin/sh -c "echo quit > /tmp/vts.cmd"' >/dev/null 2>&1 || true
    sleep 0.5
    after=$(guest "tail -n +$((before+1)) /tmp/vts.log")
    grep -q "REJECTED /tmp/vts.cmd (uid=100000, must be root)" <<<"$after" \
        || { echo "non-root vts write was NOT rejected"; rc=1; }
    local n
    n=$(guest 'ps -eo pid,comm | awk '"'"'$2=="vts"'"'"' | wc -l')
    [[ "$n" == "1" ]] || { echo "vts died after non-root write ($n running)"; rc=1; }
    return $rc
}

# ═════════════════════════════════════════════════════════════
# T2 — end-to-end canary (build → deploy → launch → tap → verify)
# The lock is held in the PARENT shell (not inside the test subshell)
# so the EXIT trap can release it reliably.
# ═════════════════════════════════════════════════════════════

t2_1_deploy() {
    [[ -d "$CANARY_DIR" ]] || { echo "canary app missing: $CANARY_DIR"; return 1; }
    [[ -x "$SFDK" ]] || { echo "sfdk not found: $SFDK"; return 1; }
    local out
    out=$(timeout 600 bash "$SCRIPTS_DIR/deploy.sh" "$CANARY_DIR" --launch 2>&1) || {
        echo "deploy failed:"; sed 's/^/   /' <<<"$out" | tail -15; return 1; }
    # The RPM lands next to the BUILD dir — in-place (app inside the SDK
    # workspace) or the staged copy (app outside it, deploy.sh stages it).
    local shared_src="$(shared_src_dir)" rpm="" d
    for d in "$CANARY_DIR" "$shared_src/.sfdk-staging/$(basename "$CANARY_DIR")"; do
        local r; r=$(ls -t "$d"/RPMS/*.rpm 2>/dev/null | head -1)
        [[ -n "$r" ]] && { rpm="$r"; break; }
    done
    [[ -n "$rpm" ]] || { echo "no RPM produced (looked in $CANARY_DIR and the staging dir)"; return 1; }
    echo "   RPM: $rpm"
    echo "$out" | sed 's/^/   /' | grep -E '✓|staged|Building|Launching|Running' | head -8
}

t2_2_process_running() {
    local n
    n=$(guest "pgrep $CANARY_APP | wc -l" 2>/dev/null)
    [[ -n "$n" && "$n" -ge 1 ]] || { echo "canary process not found in guest"; return 1; }
}

# Raise the app to the foreground (deploy launches in the background):
# invoker --single-instance activates the existing window.
t2_raise() {
    guest "su defaultuser -s /bin/sh -c 'export HOME=/home/defaultuser USER=defaultuser \
WAYLAND_DISPLAY=/run/display/wayland-0 XDG_RUNTIME_DIR=/run/user/100000 \
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/100000/dbus/user_bus_socket; \
setsid nohup /usr/bin/invoker -s --type=silica-session /usr/bin/$CANARY_APP \
>/tmp/$CANARY_APP.log 2>&1 </dev/null &'" >/dev/null 2>&1
    sleep 5
    return 0
}

# PIL helpers: <png> <mode>
#   mode=alive  → center region not black (mean luma > 30)
#   mode=diff A B → center region changed between A and B
pil_check() {
    python3 - "$@" <<'PYEOF'
import sys
from PIL import Image

def center_box(w, h, xw=250, yw=80):
    cx, cy = w // 2, h // 2
    return (cx - xw, cy - yw, cx + xw, cy + yw)

def region(img):
    b = center_box(*img.size)
    return img.crop(b).convert('L')

if sys.argv[1] == 'alive':
    img = Image.open(sys.argv[2])
    r = region(img)
    h = r.histogram()
    mean = sum(i * c for i, c in enumerate(h)) / max(sum(h), 1)
    if mean > 30:
        print(f'   center region mean luma = {mean:.1f} (alive)')
        sys.exit(0)
    print(f'   center region mean luma = {mean:.1f} (BLACK/DEAD screen)')
    sys.exit(1)

if sys.argv[1] == 'diff':
    a = region(Image.open(sys.argv[2]))
    b = region(Image.open(sys.argv[3]))
    pa = list(a.getdata()); pb = list(b.getdata())
    diff = sum(1 for x, y in zip(pa, pb) if abs(x - y) > 10)
    frac = diff / max(len(pa), 1)
    if frac >= 0.001:
        print(f'   center region changed: {frac*100:.2f}% of pixels differ (UI reacted)')
        sys.exit(0)
    print(f'   center region UNCHANGED: {frac*100:.3f}% of pixels differ (taps had no visible effect)')
    sys.exit(1)
PYEOF
}

shot() {  # <output.png>
    VBoxManage controlvm "$EMUL_VM" screenshotpng "$1" >/dev/null 2>&1 \
        || { echo "screenshot failed"; return 1; }
}

t2_3_screen_alive() {
    t2_raise || true
    local s="$WORK/t2-before.png"
    shot "$s" || return 1
    pil_check alive "$s" || return 1
    return 0
}

t2_4_taps_change_ui() {
    local before="$WORK/t2-before.png" after="$WORK/t2-after.png"
    # Ensure a fresh 'before' with the app in front.
    t2_raise || true
    shot "$before" || return 1

    tap3() {
        for i in 1 2 3; do
            bash "$SCRIPTS_DIR/tap.sh" "$((SCREEN_W/2))" "$((SCREEN_H/2))" >/dev/null 2>&1 \
                || { echo "tap.sh failed"; return 1; }
            sleep 0.5
        done
    }

    # Attempt 1: plain taps (app should be in front after raise).
    tap3
    sleep 1
    shot "$after" || return 1
    if pil_check diff "$before" "$after"; then
        return 0
    fi

    # Attempt 2: maybe the lock screen / home screen was in front —
    # swipe up to unlock, re-raise, tap again.
    echo "   no visible change — retrying with unlock swipe"
    bash "$SCRIPTS_DIR/swipe.sh" "$((SCREEN_W/2))" "$((SCREEN_H-210))" "$((SCREEN_W/2))" 150 28 >/dev/null 2>&1
    sleep 2
    t2_raise || true
    shot "$before" || return 1
    tap3
    sleep 1
    shot "$after" || return 1
    pil_check diff "$before" "$after"
}

t2_5_journal_clean() {
    local rc=0
    # Any error signatures tied to the canary = FAIL.
    local errs
    errs=$(guest "journalctl --no-pager 2>/dev/null | grep -i '$CANARY_APP' | grep -iE 'ReferenceError|TypeError|Failed to (load|instantiate)'" || true)
    if [[ -n "$errs" ]]; then
        echo "QML error signatures in journal:"; sed 's/^/   /' <<<"$errs" | head -5; rc=1
    fi
    # App stderr log (invoker redirects it) — check for QML errors too.
    local logerr
    logerr=$(guest "grep -iE 'ReferenceError|TypeError|qrc:.*qml.*error' /tmp/$CANARY_APP.log 2>/dev/null" || true)
    if [[ -n "$logerr" ]]; then
        echo "QML error signatures in app log:"; sed 's/^/   /' <<<"$logerr" | head -5; rc=1
    fi
    return $rc
}

# ═════════════════════════════════════════════════════════════
# Run
# ═════════════════════════════════════════════════════════════
echo
echo "  SFOS skill smoke suite — tier: ${TIER} (T0${RUN_T1:+ +T1}${RUN_T2:+ +T2})"
echo

echo "T0 — static (repo hygiene, no VMs needed)"
run_test T0.1 "script + tool syntax (bash -n, py_compile)"            t0_1_syntax
run_test T0.2 "doc references exist; no build artifacts in git"      t0_2_repo_hygiene
run_test T0.3 "genericity scan (no personal paths/owners/IPs)"       t0_3_genericity
run_test T0.4 "setup-sdk.sh SHA-256 fail-hard gate + opt-out"        t0_4_hash_gate
run_test T0.5 "lock contract (75-refusal, hold, minutes, auto-expire)" t0_5_lock_contract
run_test T0.6 "uninstall dry-run touches nothing; non-SFOS VMs safe" t0_6_uninstall_dryrun
run_test T0.7 "spec parser resolves Name: literal/%define/filename"    t0_7_spec_parser
run_test T0.8 "build-phone.sh --dry-run (name+version, docker plan)"  t0_8_build_phone_dryrun

if [[ "$RUN_T1" == 1 ]]; then
    echo
    echo "T1 — live guest health"
    run_test T1.1 "emulator + build engine running"                  t1_1_vms_running
    run_test T1.2 "guest SSH reachable; key mode 600"                t1_2_ssh_and_key
    run_test T1.3 "exactly ONE vts daemon"                           t1_3_single_vts
    run_test T1.4 "vboxfake shim mapped in lipstick; not setgid"     t1_4_shim_mapped
    run_test T1.5 "framebuffer resolution = ${SCREEN_W}x${SCREEN_H}" t1_5_resolution
    run_test T1.6 "netlock: 4 blackholes, internet OK, LAN blocked"  t1_6_netlock
    run_test T1.7 "vts root-only (non-root rejected, survives)"      t1_7_vts_rootonly
fi

if [[ "$RUN_T2" == 1 ]]; then
    echo
    echo "T2 — end-to-end canary (apps/sfsmoke, holds pipeline lock)"
    T2_OK=0
    if bash "$SCRIPTS_DIR/lock.sh" hold 30 >/dev/null 2>&1; then
        LOCK_HELD=1
        T2_OK=1
        t_pass "T2.0 acquire pipeline lock"
    else
        t_fail "T2.0 acquire pipeline lock (busy — another session is driving the pipeline)"
    fi
    if [[ "$T2_OK" == 1 ]]; then
        run_test T2.1 "build + deploy + launch (sfdk engine, RPM, sailjail)" t2_1_deploy
        run_test T2.2 "canary process running in guest"          t2_2_process_running
        run_test T2.3 "screen alive (not black) after raise"     t2_3_screen_alive
        run_test T2.4 "3 center taps change the UI (pixel diff)" t2_4_taps_change_ui
        run_test T2.5 "journal + app log free of QML errors"     t2_5_journal_clean
    else
        for t in "T2.1 build + deploy + launch" "T2.2 canary process running" \
                 "T2.3 screen alive" "T2.4 taps change the UI" "T2.5 journal clean"; do
            t_skip "$t" "pipeline lock not acquired"
        done
    fi
fi

# ── Summary ────────────────────────────────────────────────────
echo
echo "──────────────────────────────────────────────────────────"
printf '  \033[32m%d passed\033[0m   \033[31m%d failed\033[0m   \033[33m%d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
if [[ "$FAIL" -gt 0 ]]; then
    echo
    echo "  Failing tests:"
    for r in "${RESULTS[@]}"; do
        [[ "$r" == FAIL* ]] && echo "   ✗ ${r#FAIL  }"
    done
    echo
    echo "  SMOKE RESULT: FAIL"
    exit 1
fi
echo "  SMOKE RESULT: PASS"
exit 0
