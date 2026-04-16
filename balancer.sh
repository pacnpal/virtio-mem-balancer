#!/bin/bash
# virtio-mem-balancer — grow/shrink a KVM guest's memory via virtio-mem
# based on the guest's own memory pressure, reported via virtio-balloon stats.
#
# Runs as a long-lived loop. Single-instance enforced via flock.
# Config precedence: env vars > /etc/virtio-mem-balancer/<domain>.conf > defaults.
# Required: DOMAIN (guest name in libvirt).

set -u

# ---------- defaults ----------
DOMAIN="${DOMAIN:-}"
CONFIG="${CONFIG:-}"
MAX_KIB="${MAX_KIB:-6291456}"       # pluggable ceiling (KiB)
STEP_KIB="${STEP_KIB:-524288}"      # step per tick (KiB)
LOW_PCT="${LOW_PCT:-15}"            # grow when guest unused% < LOW_PCT
HIGH_PCT="${HIGH_PCT:-40}"          # shrink when guest unused% > HIGH_PCT
INTERVAL="${INTERVAL:-15}"          # seconds between ticks
NODE="${NODE:-0}"                   # NUMA node of the virtio-mem device
LOCK="${LOCK:-}"                    # lockfile path (auto-derived if blank)

# ---------- config file ----------
if [[ -n "$DOMAIN" && -z "$CONFIG" && -r "/etc/virtio-mem-balancer/${DOMAIN}.conf" ]]; then
    CONFIG="/etc/virtio-mem-balancer/${DOMAIN}.conf"
fi
if [[ -n "$CONFIG" && -r "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG"
fi

# ---------- validate ----------
if [[ -z "$DOMAIN" ]]; then
    echo "ERROR: DOMAIN is required (env var, CLI, or config file)" >&2
    echo "Usage: DOMAIN=<libvirt-domain-name> $0" >&2
    exit 2
fi
if ! command -v virsh >/dev/null; then
    echo "ERROR: virsh not found in PATH" >&2
    exit 2
fi

[[ -z "$LOCK" ]] && LOCK="/var/run/virtio-mem-balancer.${DOMAIN}.lock"

# ---------- single-instance lock ----------
exec 200>"$LOCK"
flock -n 200 || { echo "$(date '+%T') already running for $DOMAIN"; exit 0; }

echo "$(date '+%T') starting balancer for $DOMAIN (step=${STEP_KIB}KiB max=${MAX_KIB}KiB interval=${INTERVAL}s low=${LOW_PCT}% high=${HIGH_PCT}%)"

req=0   # last requested-size in KiB, tracked in-process

while true; do
    state=$(virsh domstate "$DOMAIN" 2>/dev/null || echo missing)
    if [[ "$state" != "running" ]]; then
        req=0
        sleep "$INTERVAL"
        continue
    fi

    # Idempotent — enables stats collection and handles VM restarts.
    virsh dommemstat "$DOMAIN" --period 2 --live >/dev/null 2>&1 || true

    stats=$(virsh dommemstat "$DOMAIN" 2>/dev/null || true)
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
            out=$(virsh update-memory-device "$DOMAIN" --node "$NODE" \
                  --requested-size "${new}KiB" --live 2>&1)
            rc=$?
            if (( rc == 0 )); then
                echo "$(date '+%T') $DOMAIN unused=${pct}% req ${req}KiB -> ${new}KiB"
                req=$new
            else
                echo "$(date '+%T') $DOMAIN FAILED rc=$rc: $out"
            fi
        fi
    else
        echo "$(date '+%T') $DOMAIN no stats (avail=${avail:-} unused=${unused:-})"
    fi

    sleep "$INTERVAL"
done
