# AGENTS.md - Flux Configuration

## Overview

Flux GitOps system configuration, repositories, variables, and kustomizations. Root of all cluster state.

## Structure

```
kubernetes/flux/
├── config/           # Root Flux Kustomizations (cluster, infra, core, operators, apps)
├── repositories/     # Helm and OCI repositories
│   ├── helm/         # 60+ HelmRepository manifests
│   └── oci/          # OCI artifact repositories
└── vars/             # Cluster variables and secrets
    ├── cluster-settings.yaml
    └── cluster-secrets.sops.yaml
```

## Where to Look

| Task | Location |
|------|----------|
| Add Helm repo | `repositories/helm/<name>.yaml` |
| Add OCI repo | `repositories/oci/<name>.yaml` |
| Change cluster vars | `vars/cluster-settings.yaml` |
| Change secrets | `vars/cluster-secrets.sops.yaml` |
| Deployment layers | `config/` (infra → core → operators → apps) |

## Conventions

- `config/cluster.yaml` is the root Kustomization
- `infrastructure.yaml`, `core.yaml`, `operators.yaml`, `apps.yaml` define layers
- Repositories referenced by `sourceRef` in HelmReleases
- Variables substituted via Flux post-build

## Anti-Patterns

- Never store plaintext secrets in `vars/`
- Never add repos outside `repositories/helm/` or `repositories/oci/`
