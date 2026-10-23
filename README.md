# ADAPTIVE_QOS_DEMO
Edge Gateway QoS with Temporary Intent, Fairness Safeguards, and Automated Rollback
# Temporary Intent Module

An interactive, browser-based simulation demo showcasing how temporary quality-of-service (QoS) boosts (such as prioritizing a work call) can be safely integrated into network traffic management without destabilizing other users[cite: 1].

## Features
* **Bounded Strength Policy Rules:** Limits weight shifts to interactive traffic[cite: 1].
* **Automated Verification & Rollback:** Evaluates candidate policies against strict safety guardrails (latency, jitter, packet loss, and background service floors) and rolls back instantly if criteria fail[cite: 1].
* **Fairness Safeguards:** Tracks fairness debt to prevent permanent starvation of background traffic[cite: 1].
* **Auto-Expiry:** Automatically clears temporary boosts and restores baseline policies when timers expire[cite: 1].

## Quick Start
1. Download `simulation_demo.html`.
2. Open the file in any modern web browser[cite: 1].
3. Use the interactive controls to apply intents, change traffic scenarios, test time acceleration, or inject deliberate failure tests[cite: 1].
