# How to Add an Application

This guide adds a new application or service to the `apps` layer. It covers the standard single-service case. Optional components have their own guides: [database](how-to-add-a-database.md), [backups](how-to-add-backups.md), and [external exposure](how-to-expose-an-app.md).

## Prerequisites

- A checkout of this repository with push access.
- A Helm chart for the application, or a container image to run with the `bjw-s` `app-template` chart (the default for simple services).
- If the chart's repository is not already defined: permission to add a `HelmRepository` under `kubernetes/flux/repositories/`.
- For secrets: a working SOPS/Age setup (`~/.config/sops/age/keys.txt` or `$SOPS_AGE_KEY_FILE`).
- If the app needs a database or cache: the operator is already deployed (CloudNative-PG, DragonflyDB, MariaDB, and so on).

## Step 1: Choose the namespace

Applications live in `kubernetes/apps/<namespace>/`. Reuse an existing namespace when the app belongs with its neighbors, or create a new one.

To create a new namespace, add `kubernetes/apps/<namespace>/namespace.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/v1/namespace.json
---
apiVersion: v1
kind: Namespace
metadata:
  name: <namespace>
  labels:
    kustomize.toolkit.fluxcd.io/prune: disabled
    istio-injection: enabled
    goldilocks.fairwinds.com/enabled: "true"
```

and `kubernetes/apps/<namespace>/kustomization.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./<app>/ks.yaml
```

Notes:

- Do **not** add a `kustomization.yaml` at `kubernetes/apps/` root. Flux generates the top-level index; the namespace index is the registration point.
- `kustomize.toolkit.fluxcd.io/prune: disabled` prevents Flux from deleting the Namespace when app manifests are removed. Delete namespaces manually when they are no longer needed.
- Use `istio-injection: enabled` if the app will be exposed through the mesh; otherwise the label can be omitted.

## Step 2: Ensure the chart source exists

List the existing repositories:

```bash
ls kubernetes/flux/repositories/helm/
ls kubernetes/flux/repositories/oci/
```

If the chart's repository is missing, add a `HelmRepository` manifest in the matching directory (namespace `flux-system`).

HTTP repository example, modeled on `kubernetes/flux/repositories/helm/authentik.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/helmrepository_v1.json
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: <repo-name>
  namespace: flux-system
spec:
  interval: 1h
  url: https://<chart-repo-host>/
```

OCI repository example, modeled on `kubernetes/flux/repositories/helm/immich.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/helmrepository_v1.json
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: <repo-name>
  namespace: flux-system
spec:
  type: oci
  interval: 5m
  url: oci://<registry>/<path>
```

**Register the new file** in the directory's `kustomization.yaml` — `kubernetes/flux/repositories/helm/kustomization.yaml` or `kubernetes/flux/repositories/oci/kustomization.yaml`:

```yaml
resources:
  - ./<repo-name>.yaml
```

Without that entry, Flux never applies the repository.

> The `bjw-s` chart repository used by most simple apps already exists at `kubernetes/flux/repositories/oci/bjw-s.yaml` (url `oci://ghcr.io/bjw-s/helm`). Use it directly when deploying the `app-template` chart.

## Step 3: Create the application skeleton

Create the component directory and its index:

```
kubernetes/apps/<namespace>/<app>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    └── helmrelease.yaml
```

`app/kustomization.yaml` lists the resources in the component:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./virtualservice.yaml   # only when the app is exposed
```

Create `app/helmrelease.yaml`. The minimal shape, modeled on `kubernetes/apps/gatus/gatus/app/helmrelease.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app>
spec:
  driftDetection:
    mode: enabled
  maxHistory: 2
  interval: 30m
  chart:
    spec:
      chart: <chart-name>
      version: <pinned-version> # datasource=helm depName=<chart-name> repository=<repo-url>
      sourceRef:
        kind: HelmRepository
        name: <repo-name>
        namespace: flux-system
  timeout: 15m
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      strategy: rollback
      retries: 3
  uninstall:
    keepHistory: false
  values:
    # chart values; see the chart's documentation
```

Pin the chart version explicitly and keep the Renovate annotation next to it. Do not copy upstream chart versions from tutorials without checking the available tags.

## Step 4: Write the Flux Kustomization

Create `kubernetes/apps/<namespace>/<app>/ks.yaml`, modeled on `kubernetes/apps/gatus/gatus/ks.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <app>
  namespace: flux-system
spec:
  targetNamespace: <namespace>
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/<namespace>/<app>/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

Key fields:

| Field | Meaning |
|-------|---------|
| `metadata.namespace` | Always `flux-system`; Flux Kustomizations are controller objects, not workload objects. |
| `spec.targetNamespace` | The namespace the rendered resources are applied to. |
| `spec.path` | Repository-relative path to the component (the directory containing a `kustomization.yaml`). |
| `spec.prune` | Delete resources that disappear from Git when `true`. |
| `spec.dependsOn` | Other Flux Kustomization names that must be ready first (omit when nothing is needed). |
| `spec.wait` | Wait for the applied resources to become healthy before reporting ready. |

Add `dependsOn` when the app needs an operator or a sibling component:

```yaml
spec:
  dependsOn:
    - name: cloudnative-pg       # operator Kustomization (see the database how-to)
```

or, for a multi-component app, define one Kustomization document per component in the same `ks.yaml` and chain them — the `immich` pattern: `immich` depends on `immich-db` and `immich-dragonfly`; `immich-db` depends on `cloudnative-pg`; `immich-dragonfly` depends on `dragonflydb-operator`.

Do **not** add `decryption` or `postBuild` blocks. The `cluster-apps` parent injects SOPS decryption and variable substitution into every app Kustomization (see [How Applications Deploy](explanation-flux-deployment-model.md)).

## Step 5: Register the app

Add the new `ks.yaml` to the namespace index:

```yaml
# kubernetes/apps/<namespace>/kustomization.yaml
resources:
  - ./namespace.yaml
  - ./<app>/ks.yaml
```

If a component has its own `ks.yaml` file (for example `backup/ks.yaml`), register that file too:

```yaml
resources:
  - ./namespace.yaml
  - ./<app>/ks.yaml
  - ./<app>/backup/ks.yaml
```

Components whose Kustomization lives inside the app's `ks.yaml` need no separate entry.

## Step 6: Add secrets (only if the app needs them)

Create the Secret with a `.sops.yaml` suffix, for example `app/secret.sops.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/v1/secret.json
---
apiVersion: v1
kind: Secret
metadata:
  name: <app>-secret
type: Opaque
stringData:
  <KEY>: <value>
```

Encrypt before committing:

```bash
make sops-encrypt
```

Reference the Secret from the HelmRelease (`envFrom.secretRef`, `env.valueFrom.secretKeyRef`, or chart-specific values). Never commit plaintext values; the SOPS config in `.sops.yaml` encrypts only `data` and `stringData`.

## Step 7: Add optional components

| Need | Guide |
|------|-------|
| PostgreSQL database | [How to Add a PostgreSQL Database](how-to-add-a-database.md) |
| Volume backups | [How to Add Backups](how-to-add-backups.md) |
| External hostname / HTTPS | [How to Expose an Application](how-to-expose-an-app.md) |
| DragonflyDB cache | Model on `kubernetes/apps/immich/immich/dragonfly/`; depends on the DragonflyDB operator Kustomization. |

## Step 8: Validate

```bash
make kubernetes-kubeconform     # renders kubernetes/flux + kubernetes/apps
make flate-test                 # optional: render the whole Flux tree offline
pre-commit run --all-files      # whitespace, line endings, secret check
```

`make kubernetes-kubeconform` does not scan `kubernetes/operators`, `kubernetes/core`, or `kubernetes/infra`. A clean run is not proof that an operator change is valid.

## Step 9: Commit and open a pull request

```bash
git add kubernetes/apps/<namespace>/<app> kubernetes/apps/<namespace>/kustomization.yaml
git add kubernetes/flux/repositories/helm/ kubernetes/flux/repositories/oci/  # only if you added a repository
git commit -m "feat(<namespace>): add <app>"
git push
```

CI runs on pull requests to `main`:

- **Kubeconform** — validates manifests under `kubernetes/` (path-filtered to `kubernetes/**`).
- **Flux Diff** — renders the Flux tree and posts the diff of changed HelmReleases/Kustomizations as a PR comment.
- **Lint** — yamllint via reviewdog.

Merge when the checks pass.

## Step 10: Verify after merge

```bash
flux get kustomizations | grep <app>
flux get helmreleases -n <namespace>
kubectl get pods -n <namespace>
```

To force reconciliation instead of waiting for the interval:

```bash
make flux-reconcile
```

For failures, inspect the specific objects:

```bash
kubectl -n <namespace> describe helmrelease <app>
kubectl -n <namespace> get events --sort-by=.metadata.creationTimestamp
```

More troubleshooting commands are in [Flux GitOps Workflow](../flux-gitops.md).

## Removing an application

1. Remove `./<app>/ks.yaml` (and any component `ks.yaml` entries) from `kubernetes/apps/<namespace>/kustomization.yaml`.
2. Delete `kubernetes/apps/<namespace>/<app>/`.
3. Commit and push. Flux prunes the HelmRelease and the resources it created.
4. Delete the namespace manually if it is no longer used. The `kustomize.toolkit.fluxcd.io/prune: disabled` label means Flux does not remove it.
5. Remove the HelmRepository only if no other app uses it (and remove its entry from the repository `kustomization.yaml`).

## Related documents

- [Tutorial: Deploy Your First Application](tutorial-deploy-first-app.md)
- [How to Add a PostgreSQL Database](how-to-add-a-database.md)
- [How to Add Backups](how-to-add-backups.md)
- [How to Expose an Application](how-to-expose-an-app.md)
- [Application Anatomy Reference](reference-app-anatomy.md)
- [Application Conventions Reference](reference-conventions.md)
- [How Applications Deploy: The Flux Deployment Model](explanation-flux-deployment-model.md)
