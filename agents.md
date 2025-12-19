# Agent Guidelines for `tool` Repository

Welcome! This file captures repository-wide expectations for agents.

NEVER COMMIT OR PUSH CHANGES!!!

## About the Tools

- **Delphi-BFT**: The name of this toolchain. It is designed for simplifying and automating large-scale simulations of real BFT protocol implementations.
- **Shadow (also known as Phantom)**: A discrete-event network simulator used by Delphi-BFT. It allows running real applications in a simulated network environment (latency, bandwidth) on a single machine, mimicking large-scale deployments without the need for hundreds of physical or virtual machines.
  > **Note**: In this simulation model, CPU time and processing overhead are **not measured** and are considered **irrelevant**. Only **network time** (latency and bandwidth) matters for the simulation results.

## Project Structure

This repository contains multiple sub-projects, including:
- `themis-lego-bft`: Contains specific agent guidelines in `themis-lego-bft/AGENTS.md`.
- `themis`: Another core component.
- `themis-v2`, `bullshark`, `narwhal`, `libhotstuff`: Other consensus/blockchain components.

## Key Directories

- **`src/`**: Contains the core logic of the Delphi-BFT toolchain, including:
    - `orchestrator.js`: The main entry point for running simulations.
    - `connectors/`: Protocol-specific connectors that adapt BFT implementations to the simulation environment.
- **`scripts/`**: Utilities for analyzing simulation results (e.g., `analyze_logs.sh`, `analyze_pcaps.sh`).
- **`examples/`**: meaningful experiment configuration files (YAML) for various protocols.
- **`experiments/`**: The output directory where simulation results and artifacts are stored.

## Architecture Highlights

- **Orchestrator**: Manages the simulation lifecycle, preparing the environment, and invoking protocol connectors.
- **Protocol Connectors**: Bridges between the generic Orchestrator and specific BFT protocol implementations (e.g., configuring keys, generating config files).



