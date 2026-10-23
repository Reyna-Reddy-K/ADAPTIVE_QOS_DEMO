#!/usr/bin/env bash
# =============================================================================
# setup_cake.sh — Apply CAKE as baseline enforcement for the QoS engine
# Teliport S4 | Case Study 3
#
# Usage:
#   sudo ./setup_cake.sh [--iface wlp0s20f3] [--bandwidth 50mbit] [--remove]
#
# CAKE flags used here and why:
#   bandwidth <X>   — shape to X, queue forms in YOUR router not ISP's
#   diffserv4       — enables 4-tier DSCP priority: Bulk/BestEffort/Video/Voice
#   dual-srchost    — fair share per source device (prevents one device monopolising)
#   nat             — handles NAT'd home networks correctly
#   wash            — scrubs DSCP on ingress (prevents apps gaming the system)
#   ingress         — applies on download direction (via IFB redirect)
# =============================================================================

set -euo pipefail

IFACE="${IFACE:-wlp0s20f3}"
BANDWIDTH="50mbit"   # set to ~95% of your real measured link speed
LOG_DIR="$(dirname "$0")/../logs"
LOG_FILE="$LOG_DIR/setup_cake.log"
IFB_DEV="ifb0"

ts()  { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root"
mkdir -p "$LOG_DIR"

remove_cake() {
    log "Removing CAKE from $IFACE..."
    tc qdisc del dev "$IFACE" root 2>/dev/null && log "Egress CAKE removed" || log "No egress CAKE to remove"
    tc qdisc del dev "$IFB_DEV" root 2>/dev/null && log "Ingress CAKE (IFB) removed" || true
    tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
    ip link set "$IFB_DEV" down 2>/dev/null || true
    log "CAKE fully removed. Interface back to default."
}

apply_cake() {
    log "Applying CAKE on $IFACE at $BANDWIDTH (diffserv4)..."

    # ── Egress (upload) ───────────────────────────────────────────────────────
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc add dev "$IFACE" root cake \
        bandwidth "$BANDWIDTH" \
        diffserv4 \
        dual-srchost \
        nat \
        wash \
        split-gso
    log "Egress CAKE applied: $BANDWIDTH diffserv4 dual-srchost"

    # ── Ingress (download) via IFB redirect ───────────────────────────────────
    modprobe ifb numifbs=1 2>/dev/null || true
    ip link set "$IFB_DEV" up 2>/dev/null || true

    tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
    tc qdisc add dev "$IFACE" ingress

    # Redirect all ingress to IFB
    tc filter add dev "$IFACE" parent ffff: \
        matchall action mirred egress redirect dev "$IFB_DEV"

    # Apply CAKE on IFB (ingress shaping)
    tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
    tc qdisc add dev "$IFB_DEV" root cake \
        bandwidth "$BANDWIDTH" \
        diffserv4 \
        dual-dsthost \
        nat \
        ingress
    log "Ingress CAKE applied on $IFB_DEV (via IFB redirect)"

    log "──────────────────────────────────────────"
    log "CAKE active. Verify with: tc -s qdisc show dev $IFACE"
    log "DSCP tiers (diffserv4):"
    log "  Tin 1 (Bulk)       — CS1, LE         — background downloads"
    log "  Tin 2 (BestEffort) — CS0, default    — normal browsing"
    log "  Tin 3 (Video)      — CS3/4, AF3x     — streaming"
    log "  Tin 4 (Voice)      — EF, CS5/6/7     — calls, gaming [HIGHEST]"
    log "──────────────────────────────────────────"
}

# Entry point
COMMAND="${1:-apply}"
shift || true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iface)     IFACE="$2";     shift 2 ;;
        --bandwidth) BANDWIDTH="$2"; shift 2 ;;
        *) die "Unknown arg: $1" ;;
    esac
done

case "$COMMAND" in
    apply|--apply) apply_cake ;;
    remove|--remove) remove_cake ;;
    *) echo "Usage: $0 {apply|remove} [--iface DEV] [--bandwidth Xmbit]"; exit 1 ;;
esac
