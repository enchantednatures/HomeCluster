# AGENTS.md - HomeCluster Repository Guidelines

## Architecture Overview

**Infrastructure**: Talos Kubernetes cluster on Proxmox VMs, managed via Terraform/Tofu
**Service Mesh**: Istio ambient mode with Cilium CNI
**DNS**: external-dns with Cloudflare, Ingress via Cloudflare Tunnels
**Serverless**: KNative for serverless workloads
**Storage**: Rook-Ceph for block/object, OpenEBS for volumes, external MinIO
**Observability**: kube-prometheus-stack (Grafana, Prometheus, AlertManager), Tempo, Loki
**Operators**: CloudNative-PG (PostgreSQL), Strimzi (Kafka), ArangoDB, DragonflyDB, Elastic

## Build/Test/Lint Commands

- `task` or `task default` - List all available tasks
- `task configure` - Template, encrypt secrets, and validate all manifests
- `task kubernetes:kubeconform` - Validate Kubernetes manifests with kubeconform
- `task flux:reconcile` - Force Flux to pull latest changes from git
- `task flux:apply path=<namespace>/<app>` - Apply specific app (e.g., `path=default/open-webui`)
- `task sops:encrypt` - Encrypt all `*.sops.yaml` files with Age
- `task kubernetes:resources` - List cluster resources (pods, helmreleases, kustomizations, etc.)
- `task kubernetes:ceph:health` - Check Ceph cluster status via toolbox pod

## Code Style Guidelines

**YAML Formatting**: 2-space indent, LF endings, UTF-8, trim trailing whitespace, final newline
**File Naming**: kebab-case (`helmrelease.yaml`, `db-user.sops.yaml`, `kustomization.yaml`)
**Schema Validation**: Always include `# yaml-language-server: $schema=<url>` comment at top
**App Directory Structure**: `/kubernetes/{apps,core,infra,operators}/<namespace>/<app>/`
  - Each app has: `namespace.yaml`, `kustomization.yaml`, `ks.yaml`, `app/` subdirectory
  - Multi-component apps use subdirs: `app/`, `db/`, `dragonfly/` (each with own kustomization)
**Secrets**: Files named `*.sops.yaml`, encrypted with SOPS/Age before commit, never plain text
  - SOPS encrypts only `^(data|stringData)$` fields in Secrets
**HelmReleases**: Pin versions, include `maxHistory: 2`, remediation `retries: 3`, `cleanupOnFail: true`
**Resource Names**: Use anchor pattern (`name: &app myapp`), reference in labels (`app.kubernetes.io/name: *app`)
**Kustomizations (Flux)**: Place in `flux-system` namespace, set `targetNamespace`, `prune: true`, `interval: 30m`
**Dependencies**: Use `dependsOn` in Kustomizations to enforce ordering
**Istio Service Discovery**: Use FQDNs (`service.namespace.svc.cluster.local:port`), explicit ports required

## Critical Operational Requirements

**GitOps Workflow**: ALL changes via git commit/push, NO direct `kubectl apply` to cluster
**Flux Reconciliation**: Changes apply only after Flux syncs (use `task flux:reconcile` to force)
**Secret Handling**: Encrypt with `task sops:encrypt` before committing, verify with pre-commit hooks
**Validation**: Run `task kubernetes:kubeconform` before committing to catch schema errors
**Istio Compatibility**: New services may need VirtualService, ServiceEntry, or AuthorizationPolicy configs
**Substitution Vars**: `${SECRET_DOMAIN}` and other vars injected via Flux `postBuild.substituteFrom`
