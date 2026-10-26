# Adaptive QoS Engine

A small Linux networking toolkit for evaluating and applying adaptive quality of service (QoS) to interactive traffic such as voice or video calls.

The project uses:

- **CAKE** (`tc`) as the baseline traffic shaper for upload and download traffic.
- **nftables** to mark traffic to and from a selected call peer with DSCP **EF**.
- CAKE's `diffserv4` tins to place marked traffic in the highest-priority Voice class.
- A repeatable latency test to compare no QoS, CAKE-only, and CAKE-plus-intent behavior.

This is primarily a system-level experiment and demonstration. The scripts change live traffic-control and firewall state on the host, so they should be run only on a test machine or with an understanding of the impact on the active network connection.

## Repository layout

```text
scripts/
├── setup_cake.sh       # Apply or remove baseline CAKE shaping
├── intent_api.sh       # Start, stop, or inspect temporary call prioritization
└── baseline_test.sh    # Compare latency across three QoS conditions

logs/                   # Runtime logs (created or appended to by the scripts)
results/                # Ping and iperf3 output from baseline tests
```

## How it works

`setup_cake.sh` applies CAKE to the selected interface at the configured bandwidth. Egress traffic is shaped directly on the interface. Ingress traffic is redirected to an `ifb0` device and shaped there. The default `diffserv4` classes are intended to separate bulk, best-effort, video, and voice traffic.

`intent_api.sh` provides a time-bounded prioritization intent:

1. Confirm that CAKE is active.
2. Add nftables rules for the selected IPv4 or IPv6 peer.
3. Set DSCP EF on packets sent to and received from that peer.
4. Keep the intent active for the requested duration.
5. Remove the rules automatically when the duration expires, or earlier with `stop`.

The state and timer are stored in `/tmp/qos_intent_state` and `/tmp/qos_intent_timer.pid`. The action log is written to `logs/intent_api.log`.

## Requirements

The scripts target a Linux system with:

- Bash
- `iproute2` (`tc`, `ip`)
- CAKE support in the kernel and `tc`
- `nftables` (`nft`)
- `iproute2` IFB support and the `ifb` kernel module
- `ping`
- `iperf3` (required by the benchmark)
- Python 3 (used to calculate ping statistics)

Root privileges are required because the scripts modify qdiscs, interfaces, and nftables rules.

## Quick start

Make the scripts executable if needed:

```bash
chmod +x scripts/*.sh
```

### 1. Apply baseline shaping

Replace the interface and bandwidth with values appropriate for the host. The bandwidth should generally be below the measured real link speed so the local CAKE queue becomes the bottleneck.

```bash
sudo ./scripts/setup_cake.sh apply \
  --iface wlp0s20f3 \
  --bandwidth 50mbit
```

Verify the qdisc configuration and statistics:

```bash
sudo tc -s qdisc show dev wlp0s20f3
sudo tc -s qdisc show dev ifb0
```

Remove the configuration when finished:

```bash
sudo ./scripts/setup_cake.sh remove --iface wlp0s20f3
```

### 2. Start a temporary call-priority intent

CAKE must already be active on the interface.

```bash
sudo ./scripts/intent_api.sh start \
  --ip 192.0.2.10 \
  --duration 3600 \
  --iface wlp0s20f3
```

The peer may be an IPv4 or IPv6 address. Inspect or stop the active intent with:

```bash
sudo ./scripts/intent_api.sh status
sudo ./scripts/intent_api.sh stop
```

The intent only marks traffic matching the specified peer address. It does not discover a call peer or identify application traffic by itself.

### 3. Run the latency comparison

Run this from the client while an `iperf3` server is listening at the remote address:

```bash
# On the remote machine
iperf3 -s

# On the client
sudo ./scripts/baseline_test.sh \
  --server 192.0.2.10 \
  --iface wlp0s20f3 \
  --bandwidth 50mbit \
  --duration 30
```

The benchmark runs these phases in sequence:

1. No QoS: raw traffic with CAKE and intent removed.
2. CAKE only: baseline shaping without peer prioritization.
3. CAKE + intent: the server peer is marked DSCP EF while the bulk flood runs.

It starts a ping stream and a four-stream `iperf3` transfer in each phase, then prints average, p95, p99, maximum latency, and jitter. Raw output and timestamped logs are saved under `results/` and `logs/`. The script removes CAKE at the end of the test.


## Safety and limitations

- Run the scripts as root and review the target interface before applying changes.
- Applying or removing qdiscs can affect all traffic on the interface and may temporarily disrupt connectivity.
- `intent_api.sh stop` removes the project's `qos_intent` nftables table. Do not use the same table name for unrelated rules.
- The benchmark is intended for a controlled test environment. It generates sustained traffic and can consume significant bandwidth.
- DSCP marking may be changed or ignored by intermediate routers, VPNs, access points, or the remote host; the prioritization is enforced locally by CAKE.
- The latency thresholds printed by the benchmark are reference targets, not proof of end-to-end call quality.


## Standards and design references

The implementation comments reference:

- RFC 3246 for Expedited Forwarding (DSCP EF).
- ITU-T G.114 as a voice-delay reference.
- CAKE's `diffserv4` queue tins for traffic-class prioritization.

