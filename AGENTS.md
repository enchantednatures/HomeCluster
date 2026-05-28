# AGENTS.md - HomeCluster Repository Guidelines

**Generated:** 2026-05-28 13:42:32 UTC
**Commit:** 91cf63164
**Branch:** main

## Architecture

Talos Kubernetes cluster on Proxmox VMs, provisioned via OpenTofu. GitOps with FluxCD v2. Cilium CNI + Istio ambient mode. Rook-Ceph (block/object) + OpenEBS (local). SOPS/Age for secrets. Renovate for dependency updates.

**Key components**: CloudNative-PG, Strimzi, ArangoDB, DragonflyDB, Elastic, KNative, kube-prometheus-stack, Grafana, Loki, Tempo, external-dns + Cloudflare Tunnels, Tailscale.

## Commands

```bash
make configure                    # Template + encrypt + validate (run before every commit)
make kubernetes-kubeconform     # Schema-validate manifests
make sops-encrypt                 # Encrypt *.sops.yaml files (REQUIRED before commit)
make sops-decrypt                 # Decrypt for inspection
make flux-reconcile               # Force git sync
make flux-apply path=ns/app     # Apply specific app
make kubernetes-resources         # List pods, helmreleases, kustomizations
make kubernetes-ceph-health       # Ceph cluster health
make terraform-proxmox-plan       # Preview VM changes
make terraform-proxmox-apply      # Apply VM config
```

**Debugging**: `flux get kustomizations -A`, `flux get helmreleases -A`, `stern -n <ns> <name>`, `kubectl -n <ns> get events --sort-by=.metadata.creationTimestamp`

## Flux Deployment Order

```
cluster-infrastructure  (no deps — deploys first)
  ├─► cluster-core       (depends on infra)
  │     ├─► cluster-operators  (depends on core + infra)
  │     └─► cluster-apps       (depends on core + infra)
```

Operators and apps are independent of each other at the Flux level. Individual apps declare `dependsOn` to specific operators in their `ks.yaml`.

## Repository Layout

```
kubernetes/
├── apps/       # User-facing applications
├── core/       # Core platform (Tekton, Harbor)
├── infra/      # Infrastructure (monitoring, networking, cert-manager, kyverno)
├── operators/  # Operators (rook-ceph, cnpg, dragonfly, strimzi, elastic, kubevirt, flink, etc.)
└── flux/       # Flux config, repositories, vars
provision/terraform/  # OpenTofu/Terraform for Proxmox VMs
scripts/              # Utility scripts (kubeconform, ceph ops, standardization)
```

## Where to Look

| Task | Location | Notes |
|------|----------|-------|
| Add new app | `kubernetes/apps/<ns>/<app>/` | See `kubernetes/apps/immich/immich/` for multi-component example |
| Add operator | `kubernetes/operators/<name>/` | Operator + CRD/app subdirs |
| Infra changes | `kubernetes/infra/<component>/` | Cilium, Istio, monitoring, networking |
| Flux config | `kubernetes/flux/` | Repos, vars, kustomizations |
| Terraform | `provision/terraform/` | Proxmox VMs, Authentik OAuth |
| Validation scripts | `scripts/` | kubeconform, standardization |
| Secrets/vars | `kubernetes/flux/vars/` | `cluster-settings.yaml`, `cluster-secrets.sops.yaml` |
| Bootstrap | `kubernetes/bootstrap/` | Flux install, deploy key |

## Code Style

### YAML

- 2-space indent, LF line endings, UTF-8, trim trailing whitespace, final newline
- Start every file with `---` document separator
- **Schema comment required** as first line: `# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/...`
- Kebab-case filenames: `helmrelease.yaml`, `kustomization.yaml`, `ks.yaml`, `namespace.yaml`
- Secrets: `*.sops.yaml` suffix always
- Use YAML anchors for DRY: `name: &app my-app` then `*app` in labels
- Pin chart versions explicitly, set `maxHistory: 2`, `install.remediation.retries: 3`, `upgrade.cleanupOnFail: true`

### yamllint Rules (`.github/yamllint.config.yaml`)

- Brackets forbidden (use multi-line lists)
- Truthy: only `"true"` / `"false"` allowed
- Comments: min 1 space from content
- Line length: disabled
- Braces: 0-1 spaces inside
- Indentation: 2 spaces, consistent indent-sequences

### Shell Scripts

- 4-space indent (per `.editorconfig`)
- Always `set -o errexit -o pipefail`

### Istio Patterns

- Always use FQDNs: `service.namespace.svc.cluster.local`
- Always specify explicit port numbers
- Use `${SECRET_DOMAIN}` for external hosts
- Gateway: `istio-ingress/external-gateway`

## Secrets Management

- Files MUST end with `.sops.yaml`
- SOPS encrypts only `^(data|stringData)$` per `.sops.yaml` config
- Run `make sops-encrypt` before every commit
- Pre-commit hook (`forbid-secrets`) blocks plaintext secrets
- Age key: `~/.config/sops/age/keys.txt` or `$SOPS_AGE_KEY_FILE`

## Variable Substitution

Flux substitutes `${SECRET_DOMAIN}`, `${CLUSTER_NAME}`, etc. from:
- `kubernetes/flux/vars/cluster-settings.yaml` (ConfigMap)
- `kubernetes/flux/vars/cluster-secrets.sops.yaml` (Secret)

## CI Pipeline (GitHub Actions on PRs to `main`)

- **Kubeconform**: validates manifests under `kubernetes/` against schemas
- **Flux Diff**: shows rendered diff of HelmRelease/Kustomization changes as PR comments
- **Lint**: yamllint review via reviewdog
- **Flux Image Updates**: auto-creates PRs from `flux-image-updates` branch

## Renovate

- Semantic commits: `feat(container)!:` (major), `feat(helm):` (minor), `fix(container):` (patch)
- Auto-merges minor/patch GitHub Actions updates
- Groups Flux and Talos packages together
- Runs on weekends, ignores `*.sops.*` files
- Custom regex manager for inline `# datasource=... depName=...` comments

## Pre-Commit Checklist

1. `make configure` — template, encrypt, validate
2. `make kubernetes-kubeconform` — schema validation
3. `make sops-encrypt` — encrypt secrets
4. Verify `git diff` shows encrypted fields only
5. `pre-commit run --all-files` — trailing whitespace, line endings, tabs, smartquotes, secret check

## Anti-Patterns

- **NEVER** `kubectl apply` directly — all changes go through Git
- **NEVER** commit plaintext secrets — use `.sops.yaml` and encrypt
- **NEVER** use brackets in YAML — multi-line lists only
- **NEVER** use unquoted truthy values — only `"true"` / `"false"`
- **NEVER** skip `make configure` before committing
- **NEVER** remove more than one Ceph OSD at a time
- **NEVER** edit auto-generated files in `clusters/*/flux-system/`

## Critical Rules

- **ALL changes go through Git** — never `kubectl apply` directly
- **Never commit plaintext secrets**
- **Always validate before committing** (`make configure`)
- Flux Kustomizations live in `flux-system` namespace, deploy to `targetNamespace`
- Use `dependsOn` to enforce ordering (app → operator → core → infra)
