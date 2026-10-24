#!/usr/bin/env bash
# =============================================================================
# intent_api.sh — Time-bounded call prioritisation via CAKE + nftables
# Teliport S4 | Case Study 3: Adaptive QoS Engine
#
# Usage:
#   sudo ./intent_api.sh start  --ip <CALL_PEER_IP> [--duration 3600] [--iface wlp0s20f3]
#   sudo ./intent_api.sh stop
#   sudo ./intent_api.sh status
#
# What it does:
#   1. Validates CAKE is running on the interface
#   2. Marks packets to/from the call peer with DSCP EF (46) using nftables
#   3. CAKE's diffserv4 mode puts EF-marked packets in Tin 4 (Voice, highest priority)
#   4. A background timer auto-reverts after --duration seconds
#   5. Logs every action with timestamp for the verifier to read
#
# Standards basis:
#   - DSCP EF (RFC 3246): Expedited Forwarding — designed for voice/interactive
#   - ITU-T G.114: one-way delay target < 150 ms for acceptable voice quality
#   - CAKE diffserv4 tins: Bulk < BestEffort < Video < Voice
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
IFACE="${IFACE:-wlp0s20f3}"
DURATION=3600          # seconds (1 hour default)
CALL_IP=""
LOG_DIR="$(dirname "$0")/../logs"
LOG_FILE="$LOG_DIR/intent_api.log"
PID_FILE="/tmp/qos_intent_timer.pid"
STATE_FILE="/tmp/qos_intent_state"
NFT_TABLE="qos_intent"

# ── Helpers ───────────────────────────────────────────────────────────────────
ts()  { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

die() { log "ERROR: $*"; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root "
}

check_cake_running() {
    tc qdisc show dev "$IFACE" | grep -q "cake" \
        || die "CAKE is not running on $IFACE. Run setup_cake.sh first."
    log "CAKE confirmed on $IFACE"
}

# ── nftables: mark call packets with DSCP EF (46 decimal = 0x2E) ──────────────
# CAKE diffserv4 maps EF → Tin 4 (Voice), highest priority
apply_nft_mark() {
    local ip="$1"
    log "Applying nftables DSCP EF mark for call peer $ip"

    # Remove existing table if any (idempotent)
    nft delete table inet "$NFT_TABLE" 2>/dev/null || true

    # Detect IP version and apply only the matching nftables rule
    if [[ "$ip" == *":"* ]]; then
        # IPv6 address
        nft -f - <<EOF
table inet $NFT_TABLE {
    chain output {
        type filter hook output priority mangle; policy accept;
        ip6 daddr $ip ip6 dscp set ef
    }
    chain input {
        type filter hook input priority mangle; policy accept;
        ip6 saddr $ip ip6 dscp set ef
    }
}
EOF
    else
        # IPv4 address
        nft -f - <<EOF
table inet $NFT_TABLE {
    chain output {
        type filter hook output priority mangle; policy accept;
        ip daddr $ip ip dscp set ef
    }
    chain input {
        type filter hook input priority mangle; policy accept;
        ip saddr $ip ip dscp set ef
    }
}
EOF
    fi
    log "nftables rule applied: traffic to/from $ip marked DSCP EF"
    log "CAKE Tin 4 (Voice) will now prioritise this flow"
}

remove_nft_mark() {
    if nft list tables 2>/dev/null | grep -q "$NFT_TABLE"; then
        nft delete table inet "$NFT_TABLE"
        log "nftables rule removed — traffic reverted to best-effort"
    else
        log "No active nftables rule to remove"
    fi
}

# ── Timer: background process that auto-reverts after DURATION seconds ─────────
start_timer() {
    local duration="$1"
    local expire_at
    expire_at=$(date -d "+${duration} seconds" '+%Y-%m-%dT%H:%M:%S')

    log "Intent timer started: will auto-revert at $expire_at (${duration}s from now)"

    # Background sleep + revert
    (
        sleep "$duration"
        log "Intent expired after ${duration}s — auto-reverting"
        remove_nft_mark
        rm -f "$STATE_FILE" "$PID_FILE"
        log "Revert complete. System back to CAKE-only baseline."
    ) &

    echo $! > "$PID_FILE"
    log "Timer PID: $(cat $PID_FILE)"
}

save_state() {
    cat > "$STATE_FILE" <<EOF
CALL_IP=$CALL_IP
DURATION=$DURATION
IFACE=$IFACE
START_TIME=$(ts)
EXPIRE_TIME=$(date -d "+${DURATION} seconds" '+%Y-%m-%dT%H:%M:%S')
TIMER_PID=$(cat "$PID_FILE" 2>/dev/null || echo "unknown")
EOF
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_start() {
    require_root
    mkdir -p "$LOG_DIR"

    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)       CALL_IP="$2";   shift 2 ;;
            --duration) DURATION="$2";  shift 2 ;;
            --iface)    IFACE="$2";     shift 2 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    [[ -n "$CALL_IP" ]] || die "--ip <CALL_PEER_IP> is required"

    # Check no intent already active
    if [[ -f "$STATE_FILE" ]]; then
        log "WARNING: An intent session is already active. Stop it first."
        cmd_status
        exit 1
    fi

    log "=========================================================="
    log "INTENT API: START"
    log "  Interface : $IFACE"
    log "  Call peer : $CALL_IP"
    log "  Duration  : ${DURATION}s ($(( DURATION / 60 )) minutes)"
    log "=========================================================="

    check_cake_running
    apply_nft_mark "$CALL_IP"
    start_timer "$DURATION"
    save_state

    log "Intent active. Call traffic will be prioritised for ${DURATION}s."
    log "Run './intent_api.sh status' to check, './intent_api.sh stop' to cancel early."
}

cmd_stop() {
    require_root
    mkdir -p "$LOG_DIR"
    log "INTENT API: MANUAL STOP requested"

    # Kill timer if running
    if [[ -f "$PID_FILE" ]]; then
        local timer_pid
        timer_pid=$(cat "$PID_FILE")
        kill "$timer_pid" 2>/dev/null && log "Timer (PID $timer_pid) killed" || true
        rm -f "$PID_FILE"
    fi

    remove_nft_mark
    rm -f "$STATE_FILE"
    log "Intent stopped. System back to CAKE-only baseline."
}

cmd_status() {
    if [[ -f "$STATE_FILE" ]]; then
        echo ""
        echo "═══════════════════════════════════════"
        echo "  INTENT API — ACTIVE SESSION"
        echo "═══════════════════════════════════════"
        cat "$STATE_FILE"
        echo ""
        echo "  nftables rules:"
        nft list table inet "$NFT_TABLE" 2>/dev/null | grep -E "(daddr|saddr|dscp)" || echo "  (none found)"
        echo "═══════════════════════════════════════"
    else
        echo "No active intent session."
        echo "Last log entries:"
        tail -5 "$LOG_FILE" 2>/dev/null || echo "(no log yet)"
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
COMMAND="${1:-status}"
shift || true

case "$COMMAND" in
    start)  cmd_start "$@" ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    *) echo "Usage: $0 {start|stop|status}"; exit 1 ;;
esac
