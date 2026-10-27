# CAKE QoS Baseline Demo

This repository contains the reproducible baseline for the  adaptive QoS project. It simulates a home gateway carrying a video call alongside a large download and compares plain shaping, CAKE, and CAKE-based call prioritization.

## Demo implementation

```text
scripts/
└── cake_baseline_demo.sh    # Complete isolated baseline test
```

The script creates three Linux network namespaces:

```text
client → gateway with bottleneck → server
```

The simulated traffic is:

- 500 kbit/s UDP flow representing a video call
- Four TCP streams representing a bulk download
- A 20 Mbit/s constrained WAN link by default

The three test phases are:

1. Plain `netem` bottleneck without traffic classification
2. CAKE `diffserv4` without call intent
3. CAKE with the UDP call flow marked DSCP EF for a bounded intent period

The real Wi-Fi or Ethernet interface is not modified.

## Requirements

Linux with Bash, `iproute2` (`ip`, `tc`), `nftables`, `iperf3`, `ping`, Python 3, and root privileges.

Fedora/RHEL:

```bash
sudo dnf install -y iproute iperf3 nftables iputils python3 kmod
```

Debian/Ubuntu:

```bash
sudo apt install -y iproute2 iperf3 nftables iputils-ping python3 kmod
```

## Run the demo

```bash
chmod +x scripts/cake_baseline_demo.sh
```

To run:

```bash
sudo ./scripts/cake_baseline_demo.sh \
  --phase-duration 60 \
  --intent-duration 60 \
  --wan-rate 20mbit
```

## Results

Raw results and the final summary are saved under:

```text
results/cake_baseline_<timestamp>/
```

View the saved summary with:

```bash
cat results/cake_baseline_*/summary.txt
```
