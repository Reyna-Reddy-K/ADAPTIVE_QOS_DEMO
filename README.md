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
