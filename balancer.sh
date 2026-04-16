#!/bin/bash
# virtio-mem-balancer — grow/shrink a KVM guest's memory via virtio-mem
# based on the guest's own memory pressure, reported via virtio-balloon stats.
#
# Runs as a long-lived loop. Single-instance per domain via flock.
# Config precedence: env > $CONFIG > /etc/virtio-mem-balancer/<domain>.conf > defaults.
# Required: DOMAIN (guest name in libvirt).

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: DOMAIN=<libvirt-domain> [options-as-env] virtio-mem-balancer

Auto-grow/shrink a KVM guest's memory via virtio-mem based on guest pressure.

Env / config vars (all optional except DOMAIN):
  DOMAIN      libvirt domain name (required)
  CONFIG      path to a bash-sourced config file
  MAX_KIB     pluggable ceiling in KiB          (default 6291456 = 6 GiB)
  STEP_KIB    grow/shrink step in KiB           (default 524288  = 512 MiB)
  LOW_PCT     grow when unused% < this          (default 15)
  HIGH_PCT    shrink when unused% > this        (default 40)
  INTERVAL    seconds between ticks             (default 15)
  NODE        virtio-mem NUMA node              (default 0)
  LOCK        lockfile path                     (default /var/run/virtio-mem-balancer.<DOMAIN>.lock)

Precedence: env > $CONFIG > /etc/virtio-mem-balancer/<DOMAIN>.conf > defaults.
See README.md for VM XML requirements and install instructions.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

# ---------- snapshot env-set values so they win over config ----------
_e_DOMAIN="${DOMAIN-}"
_e_CONFIG="${CONFIG-}"
_e_MAX_KIB="${MAX_KIB-}"
_e_STEP_KIB="${STEP_KIB-}"
_e_LOW_PCT="${LOW_PCT-}"
_e_HIGH_PCT="${HIGH_PCT-}"
_e_INTERVAL="${INTERVAL-}"
_e_NODE="${NODE-}"
_e_LOCK="${LOCK-}"

# ---------- resolve config path ----------
CONFIG="$_e_CONFIG"
if [[ -z "$CONFIG" && -n "$_e_DOMAIN" && -r "/etc/virtio-mem-balancer/${_e_DOMAIN}.conf" ]]; then
    CONFIG="/etc/virtio-mem-balancer/${_e_DOMAIN}.conf"
fi

# ---------- source config ----------
if [[ -n "$CONFIG" && -r "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

# ---------- re-apply env overrides ----------
[[ -n "$_e_DOMAIN"   ]] && DOMAIN="$_e_DOMAIN"
[[ -n "$_e_MAX_KIB"  ]] && MAX_KIB="$_e_MAX_KIB"
[[ -n "$_e_STEP_KIB" ]] && STEP_KIB="$_e_STEP_KIB"
[[ -n "$_e_LOW_PCT"  ]] && LOW_PCT="$_e_LOW_PCT"
[[ -n "$_e_HIGH_PCT" ]] && HIGH_PCT="$_e_HIGH_PCT"
[[ -n "$_e_INTERVAL" ]] && INTERVAL="$_e_INTERVAL"
[[ -n "$_e_NODE"     ]] && NODE="$_e_NODE"
[[ -n "$_e_LOCK"     ]] && LOCK="$_e_LOCK"

# ---------- apply defaults ----------
DOMAIN="${DOMAIN:-}"
MAX_KIB="${MAX_KIB:-6291456}"
STEP_KIB="${STEP_KIB:-524288}"
LOW_PCT="${LOW_PCT:-15}"
HIGH_PCT="${HIGH_PCT:-40}"
INTERVAL="${INTERVAL:-15}"
NODE="${NODE:-0}"
LOCK="${LOCK:-/var/run/virtio-mem-balancer.${DOMAIN}.lock}"

# ---------- validate ----------
if [[ -z "$DOMAIN" ]]; then
    echo "ERROR: DOMAIN is required (env, config file, or --help for usage)" >&2
    exit 2
fi
if ! command -v virsh >/dev/null; then
    echo "ERROR: virsh not found in PATH" >&2
    exit 2
fi
for _var in MAX_KIB STEP_KIB LOW_PCT HIGH_PCT INTERVAL NODE; do
    _val="${!_var}"
    if ! [[ "$_val" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $_var must be a non-negative integer, got: '$_val'" >&2
        exit 2
    fi
done

# ---------- single-instance lock ----------
exec 200>"$LOCK"
if ! flock -n 200; then
    echo "$(date '+%T') already running for $DOMAIN (lock: $LOCK)"
    exit 0
fi

# ---------- cleanup on signal ----------
cleanup() {
    trap - TERM INT HUP
    echo "$(date '+%T') $DOMAIN: shutting down"
    rm -f "$LOCK" 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT HUP

# ---------- helpers ----------
# Parse <requested> from the first <memory model='virtio-mem'> block in dumpxml.
# Prints value in KiB, or empty on failure.
read_live_req() {
    local xml val
    xml=$(virsh dumpxml "$DOMAIN" 2>/dev/null) || return 1
    val=$(awk '
        /<memory model=.virtio-mem./ { in_vm = 1; next }
        in_vm && /<\/memory>/        { in_vm = 0 }
        in_vm && /<requested/ {
            if (match($0, /[0-9]+/))
                print substr($0, RSTART, RLENGTH)
            exit
        }
    ' <<<"$xml")
    [[ "$val" =~ ^[0-9]+$ ]] || return 1
    echo "$val"
}

# ---------- initial req ----------
# If the VM is up, read the live <requested>. Otherwise 0 — a shut-off guest's
# virtio-mem device resets to whatever the stored XML says, which for this
# tool's recommended XML is <requested>0</requested>.
req=0
initial_state=$(virsh domstate "$DOMAIN" 2>/dev/null || echo missing)
if [[ "$initial_state" == "running" ]]; then
    if initial_req=$(read_live_req); then
        req="$initial_req"
    else
        echo "$(date '+%T') $DOMAIN: WARNING: could not read <requested> from live XML; starting from 0 — first shrink tick may be a no-op"
    fi
elif [[ "$initial_state" == "missing" ]]; then
    echo "$(date '+%T') $DOMAIN: WARNING: domain not defined yet; will wait"
fi

echo "$(date '+%T') $DOMAIN: starting (req=${req}KiB step=${STEP_KIB}KiB max=${MAX_KIB}KiB interval=${INTERVAL}s low=${LOW_PCT}% high=${HIGH_PCT}%)"

# ---------- main loop ----------
prev_state="$initial_state"

while true; do
    state=$(virsh domstate "$DOMAIN" 2>/dev/null || echo missing)

    if [[ "$state" != "running" ]]; then
        # --live changes don't persist across VM restarts, so tracked `req`
        # becomes stale once the VM is down. Reset to match cold-boot state.
        req=0
        prev_state="$state"
        sleep "$INTERVAL" & wait $! 2>/dev/null || true
        continue
    fi

    # On transition from non-running -> running, resync from the live XML in
    # case something else set --requested-size between ticks.
    if [[ "$prev_state" != "running" ]]; then
        if synced=$(read_live_req); then
            if (( synced != req )); then
                echo "$(date '+%T') $DOMAIN: resynced req from XML after VM start: ${req}KiB -> ${synced}KiB"
            fi
            req="$synced"
        fi
    fi
    prev_state="$state"

    # Ensure balloon stats are populating (idempotent; surfaces libvirt errors).
    if ! err=$(virsh dommemstat "$DOMAIN" --period 2 --live 2>&1 >/dev/null); then
        echo "$(date '+%T') $DOMAIN stats-period-set FAILED: ${err//$'\n'/ | }"
    fi

    if ! stats=$(virsh dommemstat "$DOMAIN" 2>&1); then
        echo "$(date '+%T') $DOMAIN dommemstat query FAILED: ${stats//$'\n'/ | }"
        stats=""
    fi

    avail=$(awk '$1=="available"{print $2}' <<<"$stats")
    unused=$(awk '$1=="unused"{print $2}' <<<"$stats")

    if [[ -n "${avail:-}" && -n "${unused:-}" && "$avail" -gt 0 ]]; then
        pct=$(( unused * 100 / avail ))
        new=$req
        (( pct < LOW_PCT  )) && new=$(( req + STEP_KIB ))
        (( pct > HIGH_PCT )) && new=$(( req - STEP_KIB ))
        (( new < 0 )) && new=0
        (( new > MAX_KIB )) && new=$MAX_KIB

        if (( new != req )); then
            if out=$(virsh update-memory-device "$DOMAIN" --node "$NODE" \
                         --requested-size "${new}KiB" --live 2>&1); then
                echo "$(date '+%T') $DOMAIN unused=${pct}% req ${req}KiB -> ${new}KiB"
                req=$new
            else
                echo "$(date '+%T') $DOMAIN update-memory-device FAILED: ${out//$'\n'/ | }"
            fi
        fi
    else
        echo "$(date '+%T') $DOMAIN no stats (avail=${avail:-} unused=${unused:-})"
    fi

    sleep "$INTERVAL" & wait $! 2>/dev/null || true
done
