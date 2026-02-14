# Infrastructure Documentation

## Overview
This repository provisions a **Talos-based Kubernetes cluster** running on **Proxmox** virtual machines. The infrastructure is defined using **OpenTofu** (Terraform-compatible) and managed via **Flux** for GitOps.

## Core Components

| Component | Purpose |
|---|---|
| **Proxmox** | VM hypervisor hosting the Talos nodes |
| **Talos** | Immutable, minimal OS purpose-built for Kubernetes |
| **OpenTofu** | Provisioning Proxmox VMs, networking, and storage resources |
| **Flux CD** | GitOps controller applying manifests from this repository |
| **Cilium** | CNI for networking, security policies, and eBPF-based observability |
| **Istio** | Ambient mode service mesh for traffic management and mTLS |
| **Rook-Ceph** | Distributed block and object storage on NVMe drives |
| **OpenEBS** | Local persistent volumes for high-performance workloads |
| **Cloudflare** | DNS management and tunnel-based external ingress |
| **Tailscale** | Private network connectivity |
| **SOPS + Age** | Secret encryption at rest in Git |
| **Kyverno** | Policy engine for Kubernetes resource validation |

## Directory Structure
```
kubernetes/infra/
├── cert-manager/          # TLS certificate management
│   └── cert-manager/
│       ├── app/           # HelmRelease
│       └── issuers/       # ClusterIssuer definitions
├── flux-system/           # Flux addons and image automation
│   ├── addons/            # Monitoring, notifications, webhooks
│   ├── image-automation/  # Flux image update automation
│   └── weave-gitops/      # GitOps UI
├── istio-ingress/         # External gateway configuration
├── istio-system/          # Istio components
│   ├── base/              # Istio CRDs
│   ├── istiod/            # Control plane
│   ├── cni/               # Istio CNI plugin
│   ├── ztunnel/           # Ambient mesh data plane
│   ├── kiali/             # Service mesh UI
│   └── ambient-config/    # Ambient mode configuration
├── kafka/                 # Schema registry and Strimzi infra
├── keda/                  # Event-driven autoscaling
├── knative/               # Serverless operator
├── knative-eventing/      # Event-driven architecture
├── knative-serving/       # Serverless workload serving
├── kube-system/           # Core system components
│   ├── cilium/            # CNI
│   ├── coredns/           # Cluster DNS
│   ├── csi-driver-nfs/    # NFS CSI driver
│   ├── goldilocks/        # Resource recommendations
│   ├── metrics-server/    # Resource metrics
│   ├── nvme-labeler/      # NVMe device labeling
│   ├── reloader/          # ConfigMap/Secret reload watcher
│   ├── snapshot-controller/ # Volume snapshot controller
│   └── spegel/            # P2P container image registry
├── kyverno-system/        # Policy engine
│   └── kyverno/
│       ├── app/           # Kyverno HelmRelease
│       └── policies/      # ClusterPolicy definitions
├── monitoring/            # Observability stack
│   ├── grafana/           # Dashboards and visualization
│   ├── influxdb/          # Time-series database
│   ├── kube-prometheus-stack/ # Prometheus + AlertManager
│   ├── kube-state-metrics/   # Kubernetes state metrics
│   ├── loki-stack/        # Log aggregation
│   ├── node-exporter/     # Node-level metrics
│   ├── prometheus-operator-crds/ # Prometheus CRDs
│   ├── promtail/          # Log shipping agent
│   └── tempo/             # Distributed tracing
├── networking/            # Network services
│   ├── cloudflared/       # Cloudflare Tunnel
│   ├── external-dns/      # DNS record management
│   ├── k8s-gateway/       # Split DNS for home network
│   ├── services/          # Network service definitions
│   ├── tailscale-connector/ # Tailscale subnet router
│   └── tailscale-operator/  # Tailscale Kubernetes operator
└── openebs-system/        # Local persistent volume storage
```

## Provisioning Workflow

1. **Provision VMs**: Use OpenTofu to create Talos VMs on Proxmox
   ```sh
   task terraform:proxmox:init
   task terraform:proxmox:plan
   task terraform:proxmox:apply
   ```

2. **Configure secrets**: Encrypt cluster secrets with SOPS/Age
   ```sh
   task sops:encrypt
   ```

3. **Validate manifests**: Template and validate all configurations
   ```sh
   task configure
   ```

4. **Bootstrap Flux**: Install Flux and sync from Git
   ```sh
   task flux:bootstrap
   ```

5. **Reconcile**: Force sync if needed
   ```sh
   task flux:reconcile
   ```

For detailed provisioning steps see [Terraform Provisioning](terraform.md) and [Deployment Guide](deployment-guide.md).
