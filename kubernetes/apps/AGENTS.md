# AGENTS.md - Applications Layer

## Overview

User-facing applications. Each app lives in `apps/<namespace>/<name>/` with optional `db/` and `dragonfly/` sidecars.

## Structure

```
kubernetes/apps/<namespace>/<app-name>/
├── ks.yaml               # Flux Kustomization(s)
├── kustomization.yaml     # Root kustomization
├── namespace.yaml
├── app/
│   ├── helmrelease.yaml
│   └── kustomization.yaml
├── db/                    # Optional CloudNative-PG cluster
└── dragonfly/             # Optional DragonflyDB cache
```

## Where to Look

| Task | Location | Example |
|------|----------|---------|
| Simple app | `apps/<ns>/<name>/` | `apps/atuin/atuin/` |
| App + db + cache | `apps/<ns>/<name>/` | `apps/immich/immich/` |
| Complex with Istio | `apps/<ns>/<name>/` | `core/harbor/harbor/` |

## Conventions

- `ks.yaml` declares `dependsOn` to operator kustomizations
- `namespace.yaml` defines the target namespace
- `helmrelease.yaml` pins chart version, sets `maxHistory: 2`, `install.remediation.retries: 3`
- Use YAML anchors: `name: &app my-app` then `*app` in labels
- Secrets in `*.sops.yaml` files

## Anti-Patterns

- Never skip `dependsOn` — apps need their backing operators first
- Never put app manifests directly in `apps/<ns>/` — always use `apps/<ns>/<name>/`
- Never use hardcoded domains — use `${SECRET_DOMAIN}`
