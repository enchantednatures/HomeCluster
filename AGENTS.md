# AGENTS.md - HomeCluster Repository Guidelines

This document provides comprehensive guidelines for AI coding agents working in this Kubernetes GitOps repository.

## Architecture Overview

**Infrastructure**: Talos Kubernetes cluster on Proxmox VMs, managed via Terraform/OpenTofu
**GitOps**: FluxCD v2 with Kustomize overlays, Git as source of truth
**Service Mesh**: Istio ambient mode with Cilium CNI for advanced networking
**DNS**: external-dns with Cloudflare provider, ingress via Cloudflare Tunnels
**Serverless**: KNative for event-driven and serverless workloads
**Storage**: Rook-Ceph (block/object), OpenEBS (local volumes), external MinIO
**Observability**: kube-prometheus-stack (Grafana, Prometheus, AlertManager), Tempo, Loki
**Databases**: CloudNative-PG (PostgreSQL), Strimzi (Kafka), ArangoDB, DragonflyDB, Elastic
**Secrets**: SOPS with Age encryption for all sensitive data in Git

## Build/Test/Lint Commands

### Essential Task Commands
- `task` or `task default` - List all available tasks
- `task configure` - Template, encrypt secrets, and validate all manifests (run before commit)
- `task kubernetes:kubeconform` - Validate Kubernetes manifests with kubeconform
- `task sops:encrypt` - Encrypt all `*.sops.yaml` files with Age (REQUIRED before commit)
- `task sops:decrypt` - Decrypt all SOPS encrypted files for inspection

### Flux Operations
- `task flux:reconcile` - Force Flux to pull latest changes from git immediately
- `task flux:apply path=<namespace>/<app>` - Apply specific app (e.g., `path=immich/immich`)
- `task flux:bootstrap` - Bootstrap Flux into cluster (initial setup only)

### Cluster Inspection
- `task kubernetes:resources` - List common cluster resources (pods, helmreleases, kustomizations, etc.)
- `task kubernetes:ceph:health` - Check Ceph cluster health via toolbox pod
- `task kubernetes:ceph:status` - Get detailed Ceph cluster status
- `task kubernetes:ceph:validate` - Validate Rook-Ceph configuration

### Terraform/Infrastructure
- `task terraform:proxmox:plan` - Preview Proxmox VM changes
- `task terraform:proxmox:apply` - Apply Proxmox VM configuration
- `task terraform:proxmox:init` - Initialize Terraform providers

### Debugging Commands
```bash
# Check Flux resource status
flux get sources git -A
flux get sources oci -A
flux get kustomizations -A
flux get helmreleases -A

# Inspect pod logs
kubectl -n <namespace> logs <pod-name> -f
stern -n <namespace> <partial-name>  # tail multiple pods

# Check events in namespace
kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'

# Describe resource for troubleshooting
kubectl -n <namespace> describe <resource-type> <resource-name>
```

## Code Style Guidelines

### YAML Formatting
- **Indentation**: 2 spaces (never tabs)
- **Line Endings**: LF (Unix), never CRLF
- **Encoding**: UTF-8
- **Whitespace**: Trim trailing whitespace, insert final newline
- **Separators**: Use `---` document separator at start of each YAML file

### File Naming Conventions
- **Format**: kebab-case for all files
- **Standard Names**: `helmrelease.yaml`, `kustomization.yaml`, `namespace.yaml`, `ks.yaml`
- **Secrets**: Always suffix with `.sops.yaml` (e.g., `db-credentials.sops.yaml`)
- **Components**: `virtualservice.yaml`, `serviceentry.yaml`, `pvc.yaml`

### Schema Validation
- **REQUIRED**: Include `# yaml-language-server: $schema=<url>` comment as first line
- **Sources**: Use schemas from `https://kubernetes-schemas.pages.dev/` or `https://kubernetes-schemas.zinn.ca/`
- **Examples**:
  ```yaml
  # yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
  # yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/networking.istio.io/virtualservice_v1.json
  ```

### Directory Structure Pattern
```
kubernetes/
├── apps/              # User-facing applications
├── core/              # Core platform services (Tekton, Harbor, etc.)
├── infra/             # Infrastructure components (monitoring, networking)
├── operators/         # Kubernetes operators (Rook, CloudNative-PG, etc.)
└── flux/              # Flux system configuration
    ├── config/        # Flux GitRepository and Kustomization
    ├── repositories/  # HelmRepository and OCIRepository definitions
    └── vars/          # Cluster-wide variables and secrets

# Standard app structure:
kubernetes/apps/<namespace>/<app-name>/
├── namespace.yaml         # Namespace definition
├── kustomization.yaml     # Root kustomization (lists subdirs)
├── ks.yaml               # Flux Kustomization(s) - may define multiple components
├── app/                  # Main application component
│   ├── helmrelease.yaml
│   ├── kustomization.yaml
│   └── pvc.yaml (optional)
├── db/                   # Database component (if needed)
│   ├── cluster.yaml
│   └── kustomization.yaml
└── dragonfly/            # Cache/Redis component (if needed)
    ├── dragonfly.yaml
    └── kustomization.yaml
```

### HelmRelease Standards
```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app my-app  # Use anchor for DRY principle
spec:
  interval: 30m
  chart:
    spec:
      chart: my-app
      version: 1.2.3  # ALWAYS pin versions explicitly
      sourceRef:
        kind: HelmRepository
        name: my-repo
        namespace: flux-system
  maxHistory: 2  # Limit stored releases
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      retries: 3
  uninstall:
    keepHistory: false
  values:
    # Chart values here
```

### Flux Kustomization Standards
```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app my-app
  namespace: flux-system  # Always in flux-system
spec:
  targetNamespace: my-namespace  # Where resources deploy
  dependsOn:  # Enforce ordering
    - name: prerequisite-app
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app  # Use anchor reference
  path: ./kubernetes/apps/my-namespace/my-app/app
  prune: true  # Enable automatic cleanup
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

### Resource Naming Pattern
Use YAML anchors for DRY (Don't Repeat Yourself):
```yaml
metadata:
  name: &app immich
  labels:
    app.kubernetes.io/name: *app
    app.kubernetes.io/instance: *app
```

### Secrets Management
- **Naming**: Files MUST end with `.sops.yaml` or `.sops.yml`
- **Encryption**: SOPS encrypts only `^(data|stringData)$` fields per `.sops.yaml` config
- **Before Commit**: Always run `task sops:encrypt` to encrypt unencrypted secrets
- **Verification**: Pre-commit hooks check for unencrypted secrets
- **Example**:
  ```yaml
  ---
  # yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/v1/secret.json
  apiVersion: v1
  kind: Secret
  metadata:
    name: db-credentials
  type: Opaque
  stringData:  # This field will be encrypted by SOPS
    username: myuser
    password: ENC[AES256_GCM,data:encrypted...]
  ```

### Istio Service Mesh Patterns
- **FQDNs Required**: Always use fully qualified domain names: `service.namespace.svc.cluster.local`
- **Explicit Ports**: Always specify port numbers in destination rules
- **VirtualService**:
  ```yaml
  spec:
    hosts:
      - myapp.${SECRET_DOMAIN}  # Use substitution vars
    gateways:
      - istio-ingress/external-gateway
    http:
      - route:
          - destination:
              host: myapp.mynamespace.svc.cluster.local  # Full FQDN
              port:
                number: 8080  # Explicit port
  ```

### Variable Substitution
Flux performs post-build substitution from ConfigMaps/Secrets:
- Common vars: `${SECRET_DOMAIN}`, `${CLUSTER_NAME}`, etc.
- Defined in: `kubernetes/flux/vars/cluster-settings.yaml` and `cluster-secrets.sops.yaml`

## Error Handling and Validation

### Pre-Commit Checklist
1. Run `task configure` to template and validate all manifests
2. Run `task kubernetes:kubeconform` to catch schema errors
3. Run `task sops:encrypt` to encrypt any new/modified secrets
4. Verify no plaintext secrets: `git diff` should show encrypted fields
5. Check pre-commit hooks pass: `pre-commit run --all-files`

### Common Issues
- **"oldString not found"**: Ensure exact whitespace matching when editing
- **Flux reconciliation fails**: Check `flux get kustomizations -A` for errors
- **Pod CrashLoopBackOff**: Check logs with `kubectl logs` and describe pod
- **Ceph issues**: Run `task kubernetes:ceph:health` for cluster status

## Critical Operational Requirements

### GitOps Workflow (NON-NEGOTIABLE)
- **ALL changes MUST go through Git**: Never `kubectl apply` directly to cluster
- **Flux is the source of truth**: Changes only apply after Flux reconciles
- **Force reconciliation**: Use `task flux:reconcile` to expedite sync (max every 30m by default)
- **Validation first**: Always run `task configure` before committing

### Security Requirements
- **Never commit plaintext secrets**: All secrets MUST be SOPS-encrypted
- **Encrypt before commit**: Run `task sops:encrypt` as final step
- **Age key location**: `~/.config/sops/age/keys.txt` or set `SOPS_AGE_KEY_FILE`
- **Pre-commit hooks**: Automatically verify secrets are encrypted

### Istio Integration
- New external services may require `VirtualService`, `Gateway`, or `DestinationRule`
- Internal cross-namespace communication may need `ServiceEntry` or `AuthorizationPolicy`
- Always use FQDNs with explicit ports for service mesh compatibility

### Dependencies and Ordering
- Use `dependsOn` in Flux Kustomizations to enforce deployment order
- Example: App depends on database, database depends on operator
- Common dependencies: `cloudnative-pg`, `dragonflydb-operator`, `rook-ceph`

## Repository Layout Reference

```
/
├── kubernetes/           # All Kubernetes manifests
│   ├── apps/            # Application deployments (user-facing)
│   ├── core/            # Core platform services
│   ├── infra/           # Infrastructure (monitoring, networking)
│   ├── operators/       # Kubernetes operators
│   └── flux/            # Flux CD configuration
├── provision/           # Infrastructure provisioning
│   ├── terraform/       # Terraform/OpenTofu configs
│   └── certs/           # Certificate files
├── .taskfiles/          # Task definition modules
├── scripts/             # Utility scripts
├── .sops.yaml          # SOPS encryption config
├── Taskfile.yaml       # Main task definitions
└── .editorconfig       # Editor formatting rules
```

## Quick Reference

### Most Common Tasks
```bash
# Daily development workflow
task configure              # Validate everything
task flux:reconcile         # Sync changes immediately
task kubernetes:resources   # Check cluster state

# Troubleshooting
flux get kustomizations -A  # Check Flux sync status
kubectl get pods -A         # Check all pods
task kubernetes:ceph:health # Check storage health
```

### File Templates
See existing apps in `kubernetes/apps/` for working examples:
- `kubernetes/apps/immich/immich/` - Multi-component app (app + db + cache)
- `kubernetes/apps/atuin/atuin/` - Simple app with HelmRelease
- `kubernetes/core/harbor/harbor/` - Complex app with Istio VirtualService
