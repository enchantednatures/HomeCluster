# Multi-Tenancy Implementation

## Overview

This implementation provides environment-based multi-tenancy for the HomeCluster using Kustomize overlays. It supports both production and local development environments.

## Directory Structure

```
kubernetes/
├── environments/
│   ├── production/               # Production environment
│   │   ├── kustomization.yaml    # Main production overlay
│   │   ├── README.md             # Production documentation
│   │   └── overlays/
│   │       ├── foundation/       # Production foundation components
│   │       ├── system/           # Production system components
│   │       └── platform/         # Production platform components
│   └── local/                    # Local development environment
│       ├── kustomization.yaml    # Main local overlay
│       ├── README.md             # Local development documentation
│       └── overlays/
│           ├── foundation/       # Local foundation components
│           ├── system/           # Local system components
│           └── platform/         # Local platform components
└── flux/
    └── config/
        ├── cluster.yaml          # Original cluster config
        └── cluster-multitenant.yaml  # New multi-tenant config
```

## Environment Configuration

### Production Environment

**Includes:**
- Complete system services (Cilium, CoreDNS, metrics, Istio)
- Full monitoring stack (Prometheus, Grafana, Loki, Tempo)
- External services (Cloudflare tunnels, external-DNS)
- Application workloads (Immich, Harbor, Flink, Atuin)
- Production storage (OpenEBS, external MinIO)
- Production optimizations (Goldilocks, Spegel)

**External Dependencies:**
- MinIO at 192.168.1.241:9768
- Cloudflare tunnels and DNS
- Proxmox infrastructure

### Local Development Environment

**Includes:**
- Core system services (simplified Cilium, CoreDNS, metrics)
- Istio service mesh (for KNative testing)
- Lightweight monitoring (Prometheus, Grafana only)
- Local Istio gateway (NodePort)

**Excludes:**
- External services (cloudflared, external-dns)
- Production applications (Immich, Harbor, Flink)
- Heavy monitoring (Loki, Tempo, Promtail)
- Production storage optimizations

## Usage

### Switching to Multi-Tenant Configuration

1. **For Production** (enhanced version):
   ```bash
   kubectl apply -f kubernetes/flux/config/cluster-production.yaml
   ```

2. **For Local Development**:
   ```bash
   kubectl apply -f kubernetes/flux/config/cluster-local.yaml
   ```

### Reverting to Original Configuration

To revert to the original configuration:
```bash
kubectl apply -f kubernetes/flux/config/cluster.yaml
```

### Configuration Files

- `cluster.yaml` - Original single-tenant configuration
- `cluster-production.yaml` - Production multi-tenant overlay
- `cluster-local.yaml` - Local development overlay

## Environment Variables

The configuration uses the following substitutions:

- All existing cluster settings from ConfigMaps/Secrets
- User-specific settings for applications

No additional environment variables are required for basic operation.

## Architecture Benefits

1. **Shared Base**: Common configurations in bootstrap/ are reused
2. **Environment Isolation**: Clear separation between prod and local
3. **Minimal Duplication**: Overlays only specify differences
4. **Easy Testing**: Local environment suitable for minikube/kind
5. **Production Safety**: External services excluded from local
6. **Flexible**: Easy to add new environments (staging, testing)

## Migration Notes

- Current production setup remains unchanged when using production overlay
- Local environment provides minimal viable cluster for development
- All existing secrets and configurations are preserved
- Bootstrap phases maintain dependency ordering

## Validation

All manifests have been validated with kubeconform:
```bash
task kubernetes:kubeconform
```

Schema validation warnings for Flux CRDs are expected and can be ignored.