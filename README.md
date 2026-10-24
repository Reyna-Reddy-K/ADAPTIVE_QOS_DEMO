# ADAPTIVE_QOS_DEMO
Edge Gateway QoS with Temporary Intent, Fairness Safeguards, and Automated Rollback
# Temporary Intent Module

An interactive, browser-based simulation demo showcasing how temporary quality-of-service (QoS) boosts (such as prioritizing a work call) can be safely integrated into network traffic management without destabilizing other users.

## Features
* **Bounded Strength Policy Rules:** Limits weight shifts to interactive traffic.
* **Automated Verification & Rollback:** Evaluates candidate policies against strict safety guardrails (latency, jitter, packet loss, and background service floors) and rolls back instantly if criteria fail
* **Fairness Safeguards:** Tracks fairness debt to prevent permanent starvation of background traffic.
* **Auto-Expiry:** Automatically clears temporary boosts and restores baseline policies when timers expire.

## Quick Start
1. Download `simulation_demo.html`.
2. Open the file in any modern web browser.
3. Use the interactive controls to apply intents, change traffic scenarios, test time acceleration, or inject deliberate failure tests.


## Linux CAKE Implementation Demo

In addition to the browser-based simulation, this repository includes a Linux-based prototype exploring real traffic shaping and temporary intent-based prioritisation using **CAKE, `tc`, and `nftables`**.

The CAKE demo provides a foundation for testing how user-requested traffic prioritisation can interact with Linux network traffic management.

### Components

| Component | File | Description |
|---|---|---|
| CAKE setup | `CAKE_Layer_demo/setup_cake.sh` | Configures CAKE for outgoing traffic and attempts to configure incoming traffic shaping through an IFB device. Supports configurable bandwidth and DiffServ traffic classes. |
| Intent API | `CAKE_Layer_demo/intent_api.sh` | Provides `start`, `stop`, and `status` commands for time-bounded prioritisation of traffic to and from a specified IP address. Uses `nftables` to mark matching packets with DSCP EF. |
| Baseline experiment | `CAKE_Layer_demo/baseline_test.sh` | Runs three test conditions: no QoS, CAKE only, and CAKE with intent marking. Uses `iperf3` to generate bulk traffic and `ping` to collect RTT samples. |

### How It Works

1. **Baseline:** Network traffic is tested without CAKE.
2. **CAKE enforcement:** CAKE is configured with a bandwidth limit and DiffServ-based traffic classification.
3. **Temporary intent:** A selected IP-based traffic flow is marked with DSCP EF, intended to place eligible packets in CAKE's high-priority Voice tin.
4. **Measurement:** Ping RTT samples are collected while bulk traffic is generated using `iperf3`.
5. **Comparison:** The resulting measurements can be used to compare the three configurations.

### Requirements

- Linux system with suitable kernel and traffic-control support
- Root privileges (`sudo`)
- `iproute2` tools, including `tc`
- `nftables`
- `iproute2` IFB support for the download-shaping configuration
- `iperf3` and `ping` for baseline testing
- Python 3 for ping-statistics processing

### Running the Demo

#### 1. Configure CAKE

```bash
cd CAKE_Layer_demo
sudo ./setup_cake.sh apply --iface <INTERFACE> --bandwidth 50mbit
```

Choose an interface and bandwidth appropriate for your test environment.

#### 2. Start a Temporary Prioritisation Intent

```bash
sudo ./intent_api.sh start \
  --ip <CALL_PEER_IP> \
  --duration 3600 \
  --iface <INTERFACE>
```

Check or stop the active intent:

```bash
sudo ./intent_api.sh status
sudo ./intent_api.sh stop
```

#### 3. Run the Baseline Experiment

Start an `iperf3` server on a separate, reachable test machine:

```bash
iperf3 -s
```

Then, on the Linux test machine, run:

```bash
sudo ./baseline_test.sh \
  --server <IPERF_SERVER_IP> \
  --iface <INTERFACE> \
  --bandwidth 50mbit
```

The script saves ping and `iperf3` logs under the repository's `results/` and `logs/` directories.

#### 4. Remove CAKE When Finished

```bash
sudo ./setup_cake.sh remove --iface <INTERFACE>
```

### Current Scope and Limitations

- This is a prototype of Linux traffic shaping and IP-based intent marking, not yet a complete adaptive QoS controller.
- The baseline script currently marks traffic to and from the `iperf3` server IP in its intent phase. For a valid call-prioritisation experiment, the call flow should be separated from the bulk-test flow.
- The baseline experiment measures ping RTT statistics; its reported standard deviation is a variability measure, not a dedicated real-time voice jitter measurement.
- The scripts do not, by themselves, demonstrate automatic link-capacity estimation, dynamic rate adaptation, or performance-triggered rollback.
- The download-prioritisation path requires further validation to ensure DSCP marking occurs before packets reach the IFB CAKE queue.
- Performance improvements have not been established by the scripts alone. They must be evaluated using actual experimental results under controlled conditions.

**Safety note:** These scripts modify Linux network configuration and require root privileges. Run them on a test machine or controlled test network, verify the selected interface, and ensure you can restore your original network configuration.

### Relationship to the Browser Simulation

The browser-based demo illustrates the proposed temporary-intent policy, simulated performance verification, and rollback workflow. The Linux CAKE demo explores real traffic shaping and DSCP-based prioritisation.

Together, they represent two parts of the project:

- **Policy-logic prototyping:** Browser-based simulation of temporary intent, performance verification, and rollback.
- **Linux networking experimentation:** Real traffic shaping and DSCP-based prioritisation using CAKE, `tc`, and `nftables`.


## Known Limitations & Production Requirements

While the simulation demo successfully validates the core state machine, policy verification, and fairness logic in a zero-dependency web environment, transitioning this concept into a production network architecture requires addressing several hardware, scale, and integration challenges:

### 1. Hardware & Kernel-Level Enforcement
* **Simulation vs. Reality:** The demo calculates latency, jitter, and packet loss via a simple mathematical model. Real-world enforcement requires low-level kernel integration using Linux traffic control (`tc`), hierarchical token bucket (`HTB`), and code algorithmic queueing `CAKE` to manage live queue lengths and packet scheduling.
* **Hardware Acceleration:** Enterprise-grade deployments require network interface card (NIC) offloading, eBPF (Extended Berkeley Packet Filter) integration, or switch-level ASIC programming to execute packet marking and prioritization at line-rate without introducing CPU bottlenecks.

### 2. High-Scale Concurrency & Distributed State
* **Multi-Node Synchronization:** The demo maintains a single, centralized state. In a production environment with thousands of concurrent users across multiple gateways, edge routers, and access points, temporary intents must synchronize securely and instantly across a distributed control plane.
* **Race Conditions:** Real-world traffic management at scale must handle overlapping intents, rapid successive requests, and high-frequency state changes without introducing control-plane jitter or processing lag.

### 3. Certification, Security, and Policy Governance
* **Authentication & Authorization:** Production systems require robust cryptographic identity verification (e.g., OAuth2, mTLS, or enterprise IAM integration) to ensure that users can only submit intents for their own authenticated sessions or authorized devices.
* **Regulatory & Compliance Auditing:** While the demo logs actions locally in memory, enterprise deployment demands tamper-proof, append-only distributed ledger or secure syslog integrations to meet compliance standards for enterprise networks or telecommunications providers.
* **Proprietary Integration:** Integrating with existing Software-Defined Networking (SDN) controllers, carrier-grade NAT (CGNAT), or proprietary enterprise firewalls requires custom API adaptors and strict adherence to vendor-specific management protocols.
