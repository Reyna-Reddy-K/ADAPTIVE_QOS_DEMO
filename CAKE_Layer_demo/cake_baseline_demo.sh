#!/usr/bin/env bash
# Creates three network namespaces:
#   client -> gateway (CAKE/netem) -> server
#
# It compares:
#   1. Plain bottleneck: netem rate limit, no traffic classification
#   2. CAKE only: diffserv4 queueing
#   3. CAKE + intent: simulated video-call UDP flow marked DSCP EF
#
# The real host network is not modified. The call flow is represented by a
# 500 kbit/s UDP stream and the competing download by four TCP streams.

set -euo pipefail

PREFIX="qos"
CLIENT_NS="${PREFIX}_client"
ROUTER_NS="${PREFIX}_gateway"
SERVER_NS="${PREFIX}_server"
CLIENT_IF="${PREFIX}_c0"
ROUTER_C_IF="${PREFIX}_r0"
ROUTER_S_IF="${PREFIX}_r1"
SERVER_IF="${PREFIX}_s0"

PHASE_DURATION=30
INTENT_DURATION=60
WAN_RATE="20mbit"
CALL_RATE="500k"
RESULTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)/results"
RUN_ID="cake_baseline_$(date '+%Y%m%d_%H%M%S')"
RUN_DIR="$RESULTS_ROOT/$RUN_ID"
CALL_PORT=5001
BULK_PORT=5201

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*"; }

usage() {
    sed -n '1,25p' "$0"
    echo "Options: --phase-duration SECONDS --intent-duration SECONDS --wan-rate RATE"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase-duration)  PHASE_DURATION="$2"; shift 2 ;;
        --intent-duration) INTENT_DURATION="$2"; shift 2 ;;
        --wan-rate)        WAN_RATE="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Run this demo with sudo."
[[ "$PHASE_DURATION" =~ ^[1-9][0-9]*$ ]] || die "Invalid --phase-duration"
[[ "$INTENT_DURATION" =~ ^[1-9][0-9]*$ ]] || die "Invalid --intent-duration"

for command_name in ip tc nft iperf3 ping python3; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "Required command not found: $command_name"
done

mkdir -p "$RUN_DIR"

cleanup() {
    local status=$?
    pkill -f "iperf3.*(-p|--port) (${CALL_PORT}|${BULK_PORT})" 2>/dev/null || true
    ip netns del "$CLIENT_NS" 2>/dev/null || true
    ip netns del "$ROUTER_NS" 2>/dev/null || true
    ip netns del "$SERVER_NS" 2>/dev/null || true
    log "Results saved in: $RUN_DIR"
    exit "$status"
}
trap cleanup EXIT INT TERM

delete_old_namespaces() {
    ip netns del "$CLIENT_NS" 2>/dev/null || true
    ip netns del "$ROUTER_NS" 2>/dev/null || true
    ip netns del "$SERVER_NS" 2>/dev/null || true
}

delete_old_namespaces

log "Creating isolated client, gateway, and server namespaces"
ip netns add "$CLIENT_NS"
ip netns add "$ROUTER_NS"
ip netns add "$SERVER_NS"

ip link add "$CLIENT_IF" type veth peer name "$ROUTER_C_IF"
ip link add "$ROUTER_S_IF" type veth peer name "$SERVER_IF"
ip link set "$CLIENT_IF" netns "$CLIENT_NS"
ip link set "$ROUTER_C_IF" netns "$ROUTER_NS"
ip link set "$ROUTER_S_IF" netns "$ROUTER_NS"
ip link set "$SERVER_IF" netns "$SERVER_NS"

ip netns exec "$CLIENT_NS" ip addr add 10.10.0.2/24 dev "$CLIENT_IF"
ip netns exec "$CLIENT_NS" ip link set lo up
ip netns exec "$CLIENT_NS" ip link set "$CLIENT_IF" up
ip netns exec "$CLIENT_NS" ip route add 10.10.1.0/24 via 10.10.0.1

ip netns exec "$ROUTER_NS" ip addr add 10.10.0.1/24 dev "$ROUTER_C_IF"
ip netns exec "$ROUTER_NS" ip addr add 10.10.1.1/24 dev "$ROUTER_S_IF"
ip netns exec "$ROUTER_NS" ip link set lo up
ip netns exec "$ROUTER_NS" ip link set "$ROUTER_C_IF" up
ip netns exec "$ROUTER_NS" ip link set "$ROUTER_S_IF" up
ip netns exec "$ROUTER_NS" sysctl -qw net.ipv4.ip_forward=1

ip netns exec "$SERVER_NS" ip addr add 10.10.1.2/24 dev "$SERVER_IF"
ip netns exec "$SERVER_NS" ip link set lo up
ip netns exec "$SERVER_NS" ip link set "$SERVER_IF" up
ip netns exec "$SERVER_NS" ip route add 10.10.0.0/24 via 10.10.1.1

apply_plain() {
    ip netns exec "$ROUTER_NS" tc qdisc del dev "$ROUTER_C_IF" root 2>/dev/null || true
    ip netns exec "$ROUTER_NS" tc qdisc add dev "$ROUTER_C_IF" root \
        netem rate "$WAN_RATE" delay 20ms 2ms distribution normal
}

apply_cake() {
    ip netns exec "$ROUTER_NS" tc qdisc del dev "$ROUTER_C_IF" root 2>/dev/null || true
    ip netns exec "$ROUTER_NS" tc qdisc add dev "$ROUTER_C_IF" root cake \
        bandwidth "$WAN_RATE" diffserv4 dual-srchost nat wash split-gso
    verify_cake
}

verify_cake() {
    local qdisc
    qdisc="$(ip netns exec "$ROUTER_NS" tc qdisc show dev "$ROUTER_C_IF")" \
        || die "Could not inspect the gateway qdisc."

    if [[ "$qdisc" != *"qdisc cake "* ]]; then
        echo "$qdisc" >&2
        die "CAKE verification failed on $ROUTER_NS/$ROUTER_C_IF"
    fi

    log "CAKE verified on $ROUTER_NS/$ROUTER_C_IF"
}

apply_intent() {
    ip netns exec "$ROUTER_NS" nft delete table inet qos_demo_intent 2>/dev/null || true
    ip netns exec "$ROUTER_NS" nft -f - <<EOF
table inet qos_demo_intent {
    chain forward {
        type filter hook forward priority mangle; policy accept;
        ip daddr 10.10.0.2 udp sport $CALL_PORT ip dscp set ef
    }
}
EOF
    ip netns exec "$ROUTER_NS" nft list table inet qos_demo_intent \
        | grep -q "dscp set ef" \
        || die "Intent verification failed: DSCP EF rule is not active."
    log "Intent verified: UDP source port $CALL_PORT is marked DSCP EF"
}

remove_intent() {
    ip netns exec "$ROUTER_NS" nft delete table inet qos_demo_intent 2>/dev/null || true
}

summarize_phase() {
    local phase="$1"
    python3 - "$RUN_DIR" "$phase" <<'PY'
import json
import re
import statistics
import sys
from pathlib import Path

root = Path(sys.argv[1])
phase = sys.argv[2]
ping_text = (root / f"{phase}_ping.txt").read_text(errors="replace")
values = [float(x) for x in re.findall(r"time[=<]([0-9.]+)", ping_text)]
sent = len(re.findall(r"icmp_seq=", ping_text))
received = len(values)
loss = ((sent - received) / sent * 100) if sent else 100.0

def load_json(name):
    try:
        return json.loads((root / f"{phase}_{name}.json").read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}

def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)

call = load_json("call")
udp = call.get("end", {}).get("sum_received", {})
if not udp:
    udp = call.get("end", {}).get("sum", {})
loss_udp = udp.get("lost_percent", "n/a")
jitter = udp.get("jitter_ms", "n/a")
call_mbps = udp.get("bits_per_second", 0) / 1_000_000 if udp.get("bits_per_second") else "n/a"
bulk = load_json("bulk")
bulk_end = bulk.get("end", {}).get("sum_received", {})
if not bulk_end:
    bulk_end = bulk.get("end", {}).get("sum", {})
bulk_mbps = bulk_end.get("bits_per_second", 0) / 1_000_000 if bulk_end.get("bits_per_second") else "n/a"
qdisc_text = (root / f"{phase}_qdisc.txt").read_text(errors="replace")
qdisc_line = re.search(
    r"Sent (\d+) bytes (\d+) pkt \(dropped (\d+), overlimits (\d+)",
    qdisc_text,
)
tin_rows = re.findall(r"^\s+pkts\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", qdisc_text, flags=re.M)
voice_packets = int(tin_rows[-1][3]) if tin_rows else 0
drops = int(qdisc_line.group(3)) if qdisc_line else "n/a"
overlimits = int(qdisc_line.group(4)) if qdisc_line else "n/a"

if values:
    values.sort()
    p95 = values[min(len(values) - 1, max(0, int(len(values) * .95) - 1))]
    p99 = values[min(len(values) - 1, max(0, int(len(values) * .99) - 1))]
    avg = statistics.mean(values)
    maximum = max(values)
else:
    avg = p95 = p99 = maximum = "n/a"

print(json.dumps({
    "phase": phase,
    "ping_sent": sent,
    "ping_received": received,
    "ping_loss_percent": round(loss, 2),
    "ping_avg_ms": round(avg, 2) if isinstance(avg, float) else avg,
    "ping_p95_ms": round(p95, 2) if isinstance(p95, float) else p95,
    "ping_p99_ms": round(p99, 2) if isinstance(p99, float) else p99,
    "ping_max_ms": round(maximum, 2) if isinstance(maximum, float) else maximum,
    "call_jitter_ms": jitter,
    "call_loss_percent": loss_udp,
    "call_mbps": call_mbps,
    "bulk_mbps": bulk_mbps,
    "voice_tin_packets": voice_packets,
    "cake_drops": drops,
    "cake_overlimits": overlimits,
}))
PY
}

run_phase() {
    local phase="$1"
    local duration="$2"
    local with_intent="$3"
    log "Phase $phase: duration=${duration}s intent=${with_intent}"

    if [[ "$phase" == "plain" ]]; then
        apply_plain
    else
        apply_cake
    fi
    if [[ "$with_intent" == "yes" ]]; then
        apply_intent
    else
        remove_intent
    fi

    ip netns exec "$SERVER_NS" iperf3 -s -1 -p "$CALL_PORT" > "$RUN_DIR/${phase}_server_call.log" 2>&1 &
    local call_server_pid=$!
    ip netns exec "$SERVER_NS" iperf3 -s -1 -p "$BULK_PORT" > "$RUN_DIR/${phase}_server_bulk.log" 2>&1 &
    local bulk_server_pid=$!
    sleep 1

    ip netns exec "$CLIENT_NS" ping -n -i 0.05 -c $((duration * 20 + 20)) \
        10.10.1.2 > "$RUN_DIR/${phase}_ping.txt" 2>&1 &
    local ping_pid=$!

    ip netns exec "$CLIENT_NS" iperf3 -c 10.10.1.2 -u -b "$CALL_RATE" \
        -l 1200 -t "$duration" -p "$CALL_PORT" -R --json \
        > "$RUN_DIR/${phase}_call.json" 2>&1 &
    local call_pid=$!
    ip netns exec "$CLIENT_NS" iperf3 -c 10.10.1.2 -P 4 -t "$duration" \
        -p "$BULK_PORT" -R --json > "$RUN_DIR/${phase}_bulk.json" 2>&1 &
    local bulk_pid=$!

    wait "$call_pid" 2>/dev/null || true
    wait "$bulk_pid" 2>/dev/null || true
    wait "$ping_pid" 2>/dev/null || true
    wait "$call_server_pid" 2>/dev/null || true
    wait "$bulk_server_pid" 2>/dev/null || true
    ip netns exec "$ROUTER_NS" tc -s qdisc show dev "$ROUTER_C_IF" \
        > "$RUN_DIR/${phase}_qdisc.txt" 2>&1
    summarize_phase "$phase" > "$RUN_DIR/${phase}_summary.json"
    remove_intent
}

run_phase "plain" "$PHASE_DURATION" "no"
run_phase "cake" "$PHASE_DURATION" "no"
run_phase "intent" "$INTENT_DURATION" "yes"

python3 - "$RUN_DIR" "$PHASE_DURATION" "$INTENT_DURATION" "$WAN_RATE" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
phase_duration = sys.argv[2]
intent_duration = sys.argv[3]
wan_rate = sys.argv[4]
rows = []
for phase in ("plain", "cake", "intent"):
    rows.append(json.loads((root / f"{phase}_summary.json").read_text()))

def value(row, key):
    item = row.get(key, "n/a")
    return f"{item:.2f}" if isinstance(item, (float, int)) else str(item)

lines = [
    "",
    "======================================================================",
    "              CAKE BASELINE COMPARISON             ",
    "======================================================================",
    f"WAN bottleneck: {wan_rate}   plain/CAKE phases: {phase_duration}s   intent phase: {intent_duration}s",
    "Traffic model: 500 kbit/s UDP video call + four TCP bulk streams",
    "",
    "PLAIN vs CAKE vs CAKE + INTENT",
    "----------------------------------------------------------------------",
    "Phase       p95 RTT   p99 RTT   call jitter   call loss   call Mbps   bulk Mbps   Voice tin   qdisc drops",
]
for row in rows:
    lines.append(
        f"{row['phase']:<11} {value(row, 'ping_p95_ms'):>8}ms {value(row, 'ping_p99_ms'):>8}ms "
        f"{value(row, 'call_jitter_ms'):>11}ms {value(row, 'call_loss_percent'):>9}% "
        f"{value(row, 'call_mbps'):>10} {value(row, 'bulk_mbps'):>10} "
        f"{value(row, 'voice_tin_packets'):>10} {value(row, 'cake_drops'):>11}"
    )

plain = rows[0]
cake = rows[1]
intent = rows[2]
if all(isinstance(row.get("ping_p95_ms"), (int, float)) for row in (plain, cake, intent)):
    plain_to_cake = plain["ping_p95_ms"] - cake["ping_p95_ms"]
    cake_to_intent = cake["ping_p95_ms"] - intent["ping_p95_ms"]
    lines += [
        "",
        "INTERPRETATION",
        "----------------------------------------------------------------------",
        f"CAKE vs plain p95 RTT: {plain_to_cake:+.2f} ms "
        f"({'improvement' if plain_to_cake > 0 else 'no improvement'}).",
        f"Intent vs CAKE p95 RTT: {cake_to_intent:+.2f} ms "
        f"({'improvement' if cake_to_intent > 0 else 'no additional improvement'}).",
        f"Intent Voice-tin packets: {value(intent, 'voice_tin_packets')} "
        f"({'classification confirmed' if isinstance(intent.get('voice_tin_packets'), int) and intent['voice_tin_packets'] > 100 else 'WARNING: verify classification'}).",
        "The call is prioritized without removing the competing bulk transfer.",
    ]
else:
    lines += ["", "No complete ping comparison was available; inspect the phase files."]

lines += ["", "======================================================================"]
output = "\n".join(lines) + "\n"
(root / "summary.txt").write_text(output)
print(output)

PY

log "Baseline demo complete"
