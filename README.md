# HomeCluster

A GitOps-managed Kubernetes home lab cluster running [Talos](https://www.talos.dev/) on [Proxmox](https://www.proxmox.com/) VMs, with [Flux](https://fluxcd.io/) driving all cluster state from this Git repository.

## Overview

This repository contains the complete infrastructure-as-code for a production-grade Kubernetes cluster designed for home lab use. All changes are committed to Git and automatically reconciled by Flux -- no manual `kubectl apply` needed.

### Tech Stack

| Component | Tool |
|---|---|
| **OS** | [Talos](https://www.talos.dev/) (immutable, minimal Kubernetes OS) |
| **Hypervisor** | [Proxmox VE](https://www.proxmox.com/) |
| **Provisioning** | [OpenTofu](https://opentofu.org/) (Terraform-compatible) |
| **GitOps** | [Flux CD v2](https://fluxcd.io/) |
| **CNI** | [Cilium](https://cilium.io/) (eBPF-based networking) |
| **Service Mesh** | [Istio](https://istio.io/) (ambient mode) |
| **Storage** | [Rook-Ceph](https://rook.io/) (block/object) + [OpenEBS](https://openebs.io/) (local PV) |
| **DNS** | [external-dns](https://github.com/kubernetes-sigs/external-dns) + Cloudflare |
| **Ingress** | [Cloudflare Tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) |
| **Secrets** | [SOPS](https://github.com/getsops/sops) + [Age](https://github.com/FiloSottile/age) |
| **Monitoring** | Prometheus, Grafana, Loki, Tempo |
| **Databases** | CloudNative-PG, Strimzi (Kafka), ArangoDB, DragonflyDB, Elastic |
| **Serverless** | [KNative](https://knative.dev/) |
| **CI/CD** | [Tekton](https://tekton.dev/), GitHub Actions |
| **Registry** | [Harbor](https://goharbor.io/) |
| **Identity** | [Authentik](https://goauthentik.io/) |
| **Updates** | [Renovate](https://www.mend.io/renovate) |

## Repository Structure

```
/
├── kubernetes/              # All Kubernetes manifests
│   ├── apps/               # User-facing applications
│   ├── core/               # Core platform services (Authentik, Harbor, Tekton)
│   ├── infra/              # Infrastructure (networking, monitoring, storage)
│   ├── operators/          # Kubernetes operators (CNPG, Rook-Ceph, etc.)
│   └── flux/               # Flux configuration, repositories, and variables
├── provision/              # Infrastructure provisioning
│   ├── terraform/          # OpenTofu/Terraform configs for Proxmox VMs
│   └── certs/              # Certificate files
├── scripts/                # Utility and automation scripts
├── .taskfiles/             # Task runner modules
├── docs/                   # Extended documentation
└── specs/                  # Feature specification documents
```

### Deployment Layers

Flux deploys resources in a dependency-ordered layer system:

```
Infrastructure (no deps)
    ├── Core (depends on Infrastructure)
    ├── Operators (depends on Core + Infrastructure)
    └── Apps (depends on Core + Infrastructure)
```

| Layer | Path | Contents |
|---|---|---|
| **Infrastructure** | `kubernetes/infra/` | Cilium, Istio, cert-manager, monitoring, OpenEBS, Rook-Ceph, networking |
| **Core** | `kubernetes/core/` | Authentik, Harbor, Tekton |
| **Operators** | `kubernetes/operators/` | CloudNative-PG, Strimzi, ArangoDB, DragonflyDB, Elastic, KubeVirt, Rook-Ceph, Flink, RabbitMQ, Redpanda |
| **Apps** | `kubernetes/apps/` | Immich, Home Assistant, Open WebUI, SearXNG, Atuin, Kafka, PostgreSQL, and more |

## Getting Started

### Prerequisites

- [Proxmox VE](https://www.proxmox.com/) hypervisor
- [task](https://taskfile.dev/) (task runner)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [flux](https://fluxcd.io/flux/installation/)
- [sops](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)
- [OpenTofu](https://opentofu.org/) or [Terraform](https://www.terraform.io/)
- A domain managed on [Cloudflare](https://cloudflare.com)

### Setup

1. **Provision VMs** -- Use OpenTofu to create Talos VMs on Proxmox:

   ```sh
   task terraform:proxmox:init
   task terraform:proxmox:plan
   task terraform:proxmox:apply
   ```

2. **Configure secrets** -- Create an Age key and encrypt secrets:

   ```sh
   age-keygen -o age.key
   # Update .sops.yaml with your public key
   task sops:encrypt
   ```

3. **Bootstrap Flux** -- Install Flux and point it at this repository:

   ```sh
   task flux:bootstrap
   ```

4. **Verify** -- Check that resources are deploying:

   ```sh
   task kubernetes:resources
   flux get kustomizations -A
   flux get helmreleases -A
   ```

## Daily Operations

### Common Tasks

```sh
task                          # List all available tasks
task configure                # Template, encrypt, and validate all manifests
task flux:reconcile           # Force Flux to sync from Git immediately
task kubernetes:resources     # List common cluster resources
task kubernetes:kubeconform   # Validate manifests with kubeconform
task sops:encrypt             # Encrypt all *.sops.yaml files
```

### Debugging

```sh
# Check Flux sync status
flux get sources git -A
flux get kustomizations -A
flux get helmreleases -A

# Inspect pods and logs
kubectl -n <namespace> get pods -o wide
kubectl -n <namespace> logs <pod-name> -f
stern -n <namespace> <partial-name>

# Check events
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'

# Storage health
task kubernetes:ceph:health
task kubernetes:ceph:status
```

### Upgrading Talos and Kubernetes

```sh
# Upgrade Talos (run on each node)
task talos:upgrade node=<ip> image=factory.talos.dev/installer/<schematic_id>:v<version>

# Upgrade Kubernetes (run once against a controller)
task talos:upgrade-k8s controller=<ip> to=<version>
```

## GitOps Workflow

All changes to the cluster go through Git:

1. Edit manifests in this repository
2. Run `task configure` to validate
3. Commit and push
4. Flux automatically reconciles (or run `task flux:reconcile` to speed it up)

### Secrets

Secrets are encrypted with SOPS/Age and stored in Git. Files must end with `.sops.yaml`:

```sh
# Encrypt before committing
task sops:encrypt

# Decrypt for inspection
task sops:decrypt
```

Pre-commit hooks verify that no plaintext secrets are committed.

## Documentation

See the [docs/](docs/) directory for detailed documentation:

- [Architecture](docs/architecture.md) -- System architecture and component relationships
- [Kubernetes Infrastructure](docs/kubernetes-infrastructure.md) -- Infrastructure components
- [Kubernetes Applications](docs/kubernetes-applications.md) -- Application deployments
- [Flux GitOps](docs/flux-gitops.md) -- GitOps workflow and configuration
- [Terraform Provisioning](docs/terraform.md) -- Infrastructure provisioning
- [Deployment Guide](docs/deployment-guide.md) -- Complete deployment instructions
- [Networking](docs/networking.md) -- Network configuration and service mesh
- [Ceph NVMe Setup](docs/ceph-nvme-setup.md) -- NVMe drive setup and optimization

## Acknowledgments

Originally based on the [onedr0p/flux-cluster-template](https://github.com/onedr0p/flux-cluster-template). Heavily modified for Talos on Proxmox with Istio ambient mode, Rook-Ceph, and an expanded application stack.

Community resources:
- [Home Operations](https://discord.gg/home-operations) Discord
- [Kubesearch](https://kubesearch.dev) -- Search Flux HelmReleases across community repos
