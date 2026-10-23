#!/usr/bin/env bash
# =============================================================================
# baseline_test.sh — Measure latency with/without CAKE and with Intent API
# Teliport S4 | Case Study 3
#
# Runs THREE conditions in sequence and saves results for comparison:
#   Phase 1: No QoS   — raw ping during bulk flood
#   Phase 2: CAKE only — ping during bulk flood with CAKE active
#   Phase 3: CAKE + Intent — ping during bulk flood with call prioritised
#
# Usage:
#   sudo ./baseline_test.sh --server <IP> --iface wlp0s20f3 --bandwidth 50mbit
#
# Requirements: iperf3, ping, tc (iproute2), nft
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
SERVER_IP=""
IFACE="wlp0s20f3"
BANDWIDTH="50mbit"
TEST_DURATION=30       # seconds per phase
PING_INTERVAL=0.2      # seconds between pings (5 pings/sec)
RESULTS_DIR="$(dirname "$0")/../results"
LOG_DIR="$(dirname "$0")/../logs"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

ts()  { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_DIR/baseline_test_${TIMESTAMP}.log"; }
die() { log "ERROR: $*"; exit 1; }
sep() { log "══════════════════════════════════════════════════════"; }

[[ $EUID -eq 0 ]] || die "Must run as root (sudo)"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)    SERVER_IP="$2";    shift 2 ;;
        --iface)     IFACE="$2";        shift 2 ;;
        --bandwidth) BANDWIDTH="$2";    shift 2 ;;
        --duration)  TEST_DURATION="$2"; shift 2 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

[[ -n "$SERVER_IP" ]] || die "--server <IP> is required. Run: iperf3 -s on the server machine."

mkdir -p "$RESULTS_DIR" "$LOG_DIR"

# ── Helper: parse ping output into stats via Python ───────────────────────────
analyse_ping() {
    local file="$1"
    python3 - "$file" <<'PYEOF'
import re, sys, statistics
with open(sys.argv[1]) as f:
    times = [float(m.group(1)) for m in re.finditer(r'time=([\d.]+)', f.read())]
if not times:
    print("NO_DATA")
    sys.exit(0)
times.sort()
n = len(times)
avg    = statistics.mean(times)
p95    = times[int(n * 0.95)]
p99    = times[int(n * 0.99)]
jitter = statistics.stdev(times) if n > 1 else 0.0
print(f"{avg:.3f},{p95:.3f},{p99:.3f},{times[-1]:.3f},{jitter:.3f},{n}")
PYEOF
}

# ── Helper: remove CAKE cleanly ────────────────────────────────────────────────
remove_cake() {
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    log "CAKE removed from $IFACE"
}

# ── Helper: apply CAKE ─────────────────────────────────────────────────────────
apply_cake() {
    remove_cake
    tc qdisc add dev "$IFACE" root cake \
        bandwidth "$BANDWIDTH" \
        diffserv4 \
        dual-srchost \
        nat \
        wash \
        split-gso
    log "CAKE applied: $BANDWIDTH diffserv4"
}

# ── Helper: mark call peer as DSCP EF (Voice tin in CAKE) ─────────────────────
apply_intent() {
    local ip="$1"
    nft delete table inet qos_intent 2>/dev/null || true

    if [[ "$ip" == *":"* ]]; then
        # IPv6
        nft -f - <<EOF
table inet qos_intent {
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
        # IPv4
        nft -f - <<EOF
table inet qos_intent {
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
    log "Intent applied: traffic to/from $ip → DSCP EF → CAKE Tin 4 (Voice)"
}

remove_intent() {
    nft delete table inet qos_intent 2>/dev/null || true
    log "Intent removed"
}

# ── Run one test phase ─────────────────────────────────────────────────────────
run_phase() {
    local phase_name="$1"
    local ping_file="$RESULTS_DIR/ping_${phase_name}_${TIMESTAMP}.txt"
    local iperf_file="$RESULTS_DIR/iperf_${phase_name}_${TIMESTAMP}.txt"

    log "Starting phase: $phase_name"
    log "  Ping file:  $ping_file"
    log "  iperf file: $iperf_file"

    # Start ping in background
    ping -i "$PING_INTERVAL" -c $(( TEST_DURATION * 5 + 10 )) "$SERVER_IP" \
        > "$ping_file" 2>&1 &
    local ping_pid=$!
    log "  Ping started (PID $ping_pid)"

    sleep 1  # let ping establish baseline before flood starts

    # Start bulk flood
    iperf3 -c "$SERVER_IP" -t "$TEST_DURATION" -P 4 \
        > "$iperf_file" 2>&1 &
    local iperf_pid=$!
    log "  iperf3 bulk flood started (PID $iperf_pid, 4 streams, ${TEST_DURATION}s)"

    # Wait for iperf to finish
    wait "$iperf_pid" 2>/dev/null || true
    sleep 2
    kill "$ping_pid" 2>/dev/null || true
    wait "$ping_pid" 2>/dev/null || true

    log "Phase $phase_name complete."
}

# =============================================================================
# MAIN TEST SEQUENCE
# =============================================================================
sep
log "BASELINE TEST — Intent API Focus"
log "Server: $SERVER_IP | Interface: $IFACE | Bandwidth: $BANDWIDTH"
log "Test duration per phase: ${TEST_DURATION}s"
sep

# ── PHASE 1: No QoS ───────────────────────────────────────────────────────────
sep
log "PHASE 1: No QoS (raw default — no CAKE, no intent)"
remove_cake
remove_intent
sleep 2
run_phase "1_no_qos"
log "Phase 1 done. "
sleep 5

# ── PHASE 2: CAKE only ────────────────────────────────────────────────────────
sep
log "PHASE 2: CAKE only (baseline enforcement, no intent)"
apply_cake
remove_intent
sleep 2
run_phase "2_cake_only"
log "Phase 2 done. "
sleep 5

# ── PHASE 3: CAKE + Intent API ────────────────────────────────────────────────
sep
log "PHASE 3: CAKE + Intent API (call to $SERVER_IP prioritised)"
apply_cake
apply_intent "$SERVER_IP"
sleep 2
run_phase "3_cake_intent"

# Cleanup
remove_intent
log "Intent removed after phase 3 "


# RESULTS REPORT

sep
log "RESULTS SUMMARY"
sep

# Collect stats for each phase
declare -A STATS
declare -A PHASE_LABELS
PHASE_LABELS["1_no_qos"]="Phase 1 — No QoS"
PHASE_LABELS["2_cake_only"]="Phase 2 — CAKE only"
PHASE_LABELS["3_cake_intent"]="Phase 3 — CAKE+Intent"
PHASE_ORDER=("1_no_qos" "2_cake_only" "3_cake_intent")

for phase in "${PHASE_ORDER[@]}"; do
    pingfile="$RESULTS_DIR/ping_${phase}_${TIMESTAMP}.txt"
    if [[ -f "$pingfile" ]]; then
        STATS[$phase]=$(analyse_ping "$pingfile")
    else
        STATS[$phase]="NO_DATA"
    fi
done

# ── Pretty table printer ───────────────────────────────────────────────────────
COL0=38   # label column width
COL=12    # metric column width

print_row() {
    local label="$1"; shift
    printf "  %-${COL0}s" "$label"
    for val in "$@"; do
        printf "│ %-${COL}s" "$val"
    done
    printf "│\n"
}

print_divider() {
    printf "  %s" "$(printf '─%.0s' $(seq 1 $COL0))"
    for col in avg p95 p99 max jitter; do
        printf "┼%s" "$(printf '─%.0s' $(seq 1 $(( COL + 1 ))))"
    done
    printf "┤\n"
}

echo ""
echo "════════════════════════════════════════════════════════════════════════════"
echo "            INTENT API BASELINE TEST RESULTS                                "
echo "════════════════════════════════════════════════════════════════════════════"
echo ""
print_row "Phase" "avg" "p95" "p99" "max" "jitter"
print_divider

for phase in "${PHASE_ORDER[@]}"; do
    raw="${STATS[$phase]}"
    label="${PHASE_LABELS[$phase]}"
    if [[ "$raw" == "NO_DATA" ]]; then
        print_row "$label" "—" "—" "—" "—" "—"
    else
        IFS=',' read -r avg p95 p99 max jitter samples <<< "$raw"
        print_row "$label" "${avg}ms" "${p95}ms" "${p99}ms" "${max}ms" "${jitter}ms"
    fi
done

echo ""
echo "  Samples per phase: ~${TEST_DURATION} seconds × 5 pings/sec"
echo "  ITU-T G.114 target : avg one-way < 150ms │ jitter < 30ms"
echo "  WebRTC target      : p95 < 100ms          │ packet loss < 1%"
echo ""
echo ""
echo "  Results saved to: $RESULTS_DIR/"
echo "═════════════════════════════════════════════════════════════════════════════"

# Final cleanup — remove CAKE to restore system
sep
log "Restoring system: removing CAKE"
remove_cake
log "Test complete."
