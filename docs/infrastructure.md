# Infrastructure Documentation

## Overview
This repository provisions a **Talos‑based Kubernetes cluster** running on **Proxmox** virtual machines. The infrastructure is defined using **OpenTofu** (Terraform compatible) and managed via **Flux** for GitOps.

### Core Components
- **Proxmox** – VM hypervisor used to host the Talos nodes.
- **Talos** – Minimal, immutable OS for Kubernetes nodes.
- **OpenTofu** – Used for provisioning Proxmox VMs, networking, and storage resources.
- **Flux** – GitOps controller that applies the manifests stored in this repository.
- **Cilium** – CNI for networking and network policies.
- **Istio** – Service mesh for traffic management and security.
- **Cloudflare** – DNS and tunnel integration for external access.
- **SOPS + Age** – Encryption of secrets.

## Directory Structure
```
infra/
  ├─ cert‑manager/      # Cert‑manager HelmRelease and configuration
  ├─ istio-system/    # Istio components (istiod, ztunnel, etc.)
  ├─ kube‑system/   # Core system components (cilium, metrics‑server, etc.)
  └─ monitoring/   # Observability stack (Grafana, Prometheus, Loki, Tempo)
```

## Provisioning Workflow
1. **Configure** `bootstrap/vars/*.yaml` with your environment values.
2. Run `task init` to generate configuration files.
3. Run `task configure` – renders all manifests and encrypts secrets.
4. Run `task flux:reconcile` to apply the configuration to the cluster.

For detailed steps see `docs/terraform.md` and `docs/networking.md`.
