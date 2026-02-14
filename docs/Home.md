# Home Cluster

A GitOps-managed Kubernetes home lab running **Talos** on **Proxmox** VMs, provisioned with **OpenTofu** and managed by **Flux CD**.

## Quick Links

- [Architecture](architecture.md) -- System design and component overview
- [Deployment Guide](deployment-guide.md) -- How to set up the cluster
- [Flux GitOps](flux-gitops.md) -- GitOps workflow and configuration
- [Infrastructure](infrastructure.md) -- Infrastructure components
- [Applications](kubernetes-applications.md) -- Deployed applications
- [Networking](networking.md) -- Network stack and service mesh

## Current Status

The cluster infrastructure has been migrated from the original OpenTofu configuration to a fully GitOps-driven model where all manifests are stored in this repository and reconciled by Flux.

See the [main README](../README.md) for an overview and getting started instructions.
