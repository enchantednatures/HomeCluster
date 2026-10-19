# Application Conventions Reference

Reference for the file-level conventions used by applications under `kubernetes/apps/`. For the directory structure and file roles, see [Application Anatomy Reference](reference-app-anatomy.md). For the reasoning behind the conventions, see [How Applications Deploy: The Flux Deployment Model](explanation-flux-deployment-model.md).

## File envelope

Every YAML file begins with a schema directive followed by a document separator:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
---
```

Schema URLs used in this repository:

| Kind | Schema URL |
|------|------------|
| Flux Kustomization | `https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json` |
| HelmRelease | `https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json` |
| Namespace | `https://kubernetes-schemas.pages.dev/v1/namespace.json` |
| Kustomization (kustomize) | `https://kubernetes-schemas.pages.dev/kustomize.config.k8s.io/kustomization_v1beta1.json` |
| VirtualService | `https://kubernetes-schemas.pages.dev/networking.istio.io/virtualservice_v1.json` |
| HelmRepository | `https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/helmrepository_v1.json` |
| Secret | `https://kubernetes-schemas.pages.dev/v1/secret.json` |
| CloudNative-PG Cluster | `https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/cluster_v1.json` |
| CloudNative-PG Database | `https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/database_v1.json` |
| CloudNative-PG Pooler | `https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/pooler_v1.json` |
| CloudNative-PG ScheduledBackup | `https://kubernetes-schemas.pages.dev/postgresql.cnpg.io/scheduledbackup_v1.json` |

A few existing files place `---` before the schema comment. New files should put the schema comment first.

## Naming

- Files and directories use kebab-case.
- Fixed filenames: `ks.yaml`, `kustomization.yaml`, `namespace.yaml`, `helmrelease.yaml`, `virtualservice.yaml`.
- Secret files always end in `.sops.yaml`. The root `.sops.yaml` matches `kubernetes/.*\.sops\.ya?ml`, and the pre-commit `forbid-secrets` hook enforces encrypted content.
- Flux Kustomization names match the app or component: `<app>`, `<app>-db`, `<app>-dragonfly`, `<app>-backup`.

## YAML anchors and labels

Multi-component files use anchors to keep labels consistent:

```yaml
metadata:
  name: &app immich
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
```

In a multi-component `ks.yaml`, each document uses its own anchor (`&app`, `&app-db`, `&app-dragonfly`).

Namespace labels in use:

| Label | Purpose | Example |
|-------|---------|---------|
| `kustomize.toolkit.fluxcd.io/prune: disabled` | Prevents Flux from pruning the Namespace object | `gatus`, `immich`, most namespaces |
| `istio-injection: enabled` | Enables Istio sidecar injection for exposed apps | `gatus`, `atuin`, `immich` |
| `istio-injection: disabled` | Opts the namespace out of injection | `erpnext`, `kellnr` |
| `goldilocks.fairwinds.com/enabled: "true"` | Enables Goldilocks VPA recommendations | All namespace files |

Quoting rules: truthy values are quoted (`"true"`), numeric strings may be quoted (`"25"`), and lists use block style in new files. A few existing files use flow-style lists (`resources: [./namespace.yaml, ./app/ks.yaml]`); do not copy that form.

## Flux Kustomization (ks.yaml) fields

| Field | Typical value | Notes |
|-------|---------------|-------|
| `apiVersion` | `kustomize.toolkit.fluxcd.io/v1` | |
| `kind` | `Kustomization` | |
| `metadata.name` | `<app>` or `<component>` | Anchored with `&app` when labels reference it |
| `metadata.namespace` | `flux-system` | Always; these are controller objects |
| `spec.targetNamespace` | workload namespace | Where rendered resources are applied |
| `spec.dependsOn` | list of `{name: <flux-kustomization>}` | Names must match sibling or operator Kustomizations; `namespace` defaults to `flux-system` |
| `spec.commonMetadata.labels` | `app.kubernetes.io/name: *app` | Propagated to rendered resources |
| `spec.path` | `./kubernetes/apps/<ns>/<app>/<component>` | Leading `./`; directory containing a `kustomization.yaml` |
| `spec.prune` | `true` | Garbage-collect removed resources |
| `spec.sourceRef` | `{kind: GitRepository, name: flux-system}` | |
| `spec.wait` | `true` for simple/db components; `false` for a multi-component main app and backups | |
| `spec.interval` | `10m` for multi-component apps, `30m` for simple apps | |
| `spec.retryInterval` | `1m` | |
| `spec.timeout` | `5m` | |
| `spec.decryption` / `spec.postBuild` | omitted | Injected by the `cluster-apps` parent |

`dependsOn` targets operator Kustomizations by name. Common anchors: `cloudnative-pg`, `dragonflydb-operator`, `mariadb-operator`, `volsync`. Platform-level dependencies can also target `kyverno-policies`, which is defined in `kubernetes/infra/kyverno-system/kyverno/ks.yaml`.

## HelmRelease fields

| Field | Typical value | Notes |
|-------|---------------|-------|
| `apiVersion` | `helm.toolkit.fluxcd.io/v2` | |
| `metadata.name` | `<app>` | `metadata.namespace` may be omitted; `targetNamespace` supplies it |
| `spec.driftDetection.mode` | `enabled` | |
| `spec.maxHistory` | `2` | |
| `spec.interval` | `30m` | |
| `spec.chart.spec.chart` | chart name | |
| `spec.chart.spec.version` | pinned version | Includes a Renovate annotation |
| `spec.chart.spec.sourceRef` | `{kind: HelmRepository, name: <repo>, namespace: flux-system}` | |
| `spec.timeout` | `15m` | |
| `spec.install.remediation.retries` | `3` | |
| `spec.upgrade.cleanupOnFail` | `true` | |
| `spec.upgrade.remediation` | `{strategy: rollback, retries: 3}` | |
| `spec.uninstall.keepHistory` | `false` | |

Most simple applications use the `bjw-s` `app-template` chart (chart `app-template`, repository `bjw-s` defined in `kubernetes/flux/repositories/oci/bjw-s.yaml`).

## HelmRepository conventions

- HTTP repositories: `kubernetes/flux/repositories/helm/<name>.yaml`
- OCI repositories: `kubernetes/flux/repositories/oci/<name>.yaml`
- Namespace: `flux-system`
- Every file is listed explicitly in the directory's `kustomization.yaml`; a new repository must be added there or Flux never applies it.

Examples:

```yaml
# HTTP (kubernetes/flux/repositories/helm/authentik.yaml)
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: authentik
  namespace: flux-system
spec:
  interval: 1h
  url: https://charts.goauthentik.io
```

```yaml
# OCI (kubernetes/flux/repositories/helm/immich.yaml)
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: immich
  namespace: flux-system
spec:
  type: oci
  interval: 5m
  url: oci://ghcr.io/immich-app/immich-charts
```

The `bjw-s` repository at `kubernetes/flux/repositories/oci/bjw-s.yaml` uses `oci://ghcr.io/bjw-s/helm`.

## Istio VirtualService conventions

- `apiVersion: networking.istio.io/v1beta1`, `kind: VirtualService`.
- `spec.hosts`: `<app>.${SECRET_DOMAIN}`.
- `spec.gateways`: `istio-ingress/external-gateway`.
- `spec.http[].route[].destination.host`: fully qualified `<service>.<namespace>.svc.cluster.local`.
- Always specify an explicit port number.
- The VirtualService lives in the application namespace; the gateway is referenced cross-namespace.
- Template: [`docs/templates/virtualservice-template.yaml`](../templates/virtualservice-template.yaml).

## Secret files (SOPS)

- Filename must match `kubernetes/.*\.sops\.ya?ml`.
- The root `.sops.yaml` encrypts only `^(data|stringData)$`; metadata stays readable.
- Run `make sops-encrypt` before committing. The pre-commit `forbid-secrets` hook rejects plaintext secrets.
- Flux decrypts with the `sops-age` Secret; the decryption block is injected into app Kustomizations by the `cluster-apps` parent, so app `ks.yaml` files omit it.

## Renovate annotations

Annotations used in this repository:

```yaml
# Helm chart version
version: 3.7.3 # datasource=helm depName=app-template repository=oci://ghcr.io/bjw-s/helm

# Container image tag
tag: v5.37.0 # datasource=docker depName=ghcr.io/twin/gatus

# Operator image (line above the field)
# renovate: datasource=docker depName=ghcr.io/cloudnative-pg/postgresql versioning=redhat
imageName: ghcr.io/cloudnative-pg/postgresql:17.1-1

# Flux image automation pins
tag: v3.1.0 # {"$imagepolicy": "flux-system:immich-server:tag"}
```

Versions are pinned explicitly; Renovate opens pull requests for updates.

## Validation and formatting

| Command | What it does |
|---------|--------------|
| `make kubernetes-kubeconform` | Renders every `kustomization.yaml` under `kubernetes/flux` and `kubernetes/apps` and validates with kubeconform (`-strict -ignore-missing-schemas -skip Secret`, schemas from `kubernetes-schemas.pages.dev`). Does not scan `operators`, `core`, or `infra`. |
| `make flate-test` | Renders and validates the full Flux tree offline. |
| `make flate-diff ref=main` | Diffs the rendered manifests against a baseline ref. |
| `pre-commit run --all-files` | Trailing whitespace, line endings, smart quotes, tabs, and the secret check. |

yamllint configuration lives in `.github/yamllint.config.yaml` (brackets forbidden, truthy values limited to `true`/`false`, 2-space indentation, line length disabled).

The `README.md` and `CLAUDE.md` files still show `task ...` commands from the previous task runner; the Makefile is authoritative. Use `make ...`.

## Related documents

- [Application Anatomy Reference](reference-app-anatomy.md)
- [How to Add an Application](how-to-add-an-application.md)
- [Flux GitOps Workflow](../flux-gitops.md)
