# Application Anatomy Reference

Structural reference for application directories under `kubernetes/apps/`. It describes the files that exist, where they live, and how Flux discovers them. For the reasoning behind this layout, see [Flux Deployment Model Explained](explanation-flux-deployment-model.md).

## Directory layout

Canonical tree for a namespace directory. Optional files are marked in their role text.

```text
kubernetes/apps/<namespace>/
├── namespace.yaml                  # Namespace object and namespace-level labels
├── kustomization.yaml              # Namespace registration: namespace.yaml plus app and component ks.yaml files
└── <app>/
    ├── ks.yaml                     # Flux Kustomization definitions for the app and its inline components
    ├── app/                        # Main workload component
    │   ├── kustomization.yaml      # Lists the resources in app/
    │   ├── helmrelease.yaml        # HelmRelease for the application chart
    │   ├── virtualservice.yaml     # Istio VirtualService for external access
    │   ├── pvc.yaml                # PersistentVolumeClaim, when storage is needed
    │   └── secret.sops.yaml        # SOPS-encrypted application Secret, when needed
    ├── db/                         # CloudNative-PG database component, when the app uses PostgreSQL
    │   ├── kustomization.yaml
    │   ├── cluster.yaml
    │   ├── database.yaml
    │   ├── pooler.yaml
    │   ├── scheduled-backup.yaml
    │   ├── podmonitor.yaml
    │   └── *.sops.yaml
    ├── dragonfly/                  # DragonflyDB component, when the app uses Dragonfly
    │   ├── kustomization.yaml
    │   └── dragonfly.yaml
    └── backup/                     # VolSync backup component
        ├── ks.yaml                 # Separate Flux Kustomization for the backup component
        ├── kustomization.yaml
        ├── replicationsource.yaml
        ├── replicationdestination.yaml
        └── <app>-backup-secret.sops.yaml
```

`app/`, `db/`, and `dragonfly/` have no `ks.yaml` of their own. Their Flux Kustomizations are additional documents inside `<app>/ks.yaml`. `backup/` has its own `ks.yaml`, and the namespace-level `kustomization.yaml` lists it explicitly.

## File roles

| File | Contains | Exists when |
|------|----------|-------------|
| `namespace.yaml` | `v1` Namespace with `metadata.name` equal to the namespace directory, plus namespace labels | Always |
| `kustomization.yaml` (namespace level) | `kustomize.config.k8s.io/v1beta1` Kustomization listing `./namespace.yaml`, each app `ks.yaml`, and each component `ks.yaml` stored separately | Always |
| `<app>/ks.yaml` | One or more `kustomize.toolkit.fluxcd.io/v1` Kustomization documents, one per component defined inline | Always |
| `app/kustomization.yaml` | Kustomization listing the resources in `app/` | Always |
| `app/helmrelease.yaml` | `helm.toolkit.fluxcd.io/v2` HelmRelease, chart version, `sourceRef`, and chart values | Always |
| `app/virtualservice.yaml` | `networking.istio.io/v1beta1` VirtualService for external host routing | When the app is exposed through the external gateway |
| `app/pvc.yaml` | One or more `v1` PersistentVolumeClaims, sometimes alongside `existingClaim` values in the HelmRelease | When the chart does not create its own storage |
| `app/secret.sops.yaml` | SOPS-encrypted `v1` Secret referenced by the HelmRelease | When the app needs a Secret supplied from Git |
| `app/ingress.yaml` | Optional Ingress, for example a Tailscale-only endpoint | When a non-Istio endpoint is required |
| `app/ciliumnetworkpolicy.yaml` | Optional CiliumNetworkPolicy | When the app needs explicit network policy |
| `db/cluster.yaml` | `postgresql.cnpg.io/v1` Cluster | When the app uses CloudNative-PG |
| `db/database.yaml` | `postgresql.cnpg.io/v1` Database | When the app uses CloudNative-PG |
| `db/pooler.yaml` | `postgresql.cnpg.io/v1` Pooler | When connections go through a pooler |
| `db/scheduled-backup.yaml` | `postgresql.cnpg.io/v1` ScheduledBackup | When database backups are scheduled |
| `db/podmonitor.yaml` | `monitoring.coreos.com/v1` PodMonitor | When database metrics are scraped |
| `db/*.sops.yaml` | Encrypted role, superuser, and operator Secrets | When the database needs credentials |
| `dragonfly/dragonfly.yaml` | `dragonflydb.io/v1alpha1` Dragonfly | When the app uses Dragonfly |
| `backup/ks.yaml` | Flux Kustomization for the backup component | When VolSync backups are configured |
| `backup/replicationsource.yaml` | `volsync.backube/v1alpha1` ReplicationSource | When VolSync backs up a PVC |
| `backup/replicationdestination.yaml` | `volsync.backube/v1alpha1` ReplicationDestination | When a restore destination is defined |
| `backup/<app>-backup-secret.sops.yaml` | Encrypted repository credentials for VolSync | When VolSync accesses a remote repository |

## Component directories

Files observed in the reference applications.

| Directory | Typical files | Purpose |
|-----------|---------------|---------|
| `app/` | `kustomization.yaml`, `helmrelease.yaml`, `virtualservice.yaml`, plus any of `pvc.yaml`, `secret.sops.yaml`, `ingress.yaml`, `ciliumnetworkpolicy.yaml` | Main workload |
| `db/` | `kustomization.yaml`, `cluster.yaml`, `database.yaml`, `pooler.yaml`, `scheduled-backup.yaml`, `podmonitor.yaml`, role and superuser `*.sops.yaml` files. `atuin` also has `service.yaml`; `immich` also has `cloudnative-pg-secret.sops.yaml` | CloudNative-PG database |
| `dragonfly/` | `kustomization.yaml`, `dragonfly.yaml` | DragonflyDB cache |
| `backup/` | `kustomization.yaml`, `ks.yaml`, `replicationsource.yaml`, `replicationdestination.yaml`, `<app>-backup-secret.sops.yaml` | VolSync backup and restore |
| `sso/`, `setup/`, `bootstrap/`, `warehouse/`, `schema/` | Varies by application | Application-specific setup components. Examples: `erpnext/erpnext/sso` and `setup`, `lakehouse/gravitino/bootstrap`, `warehouse`, and `schema` |

Additional directories appear where an application needs them. The component name is not restricted to the set above.

## Namespace labels

| Label | Purpose | Used by |
|-------|---------|---------|
| `kustomize.toolkit.fluxcd.io/prune: disabled` | Tells the Flux kustomize-controller not to prune the Namespace object | 13 of 15 namespace files, including `immich`, `gatus`, `atuin`, `default`, and `lakehouse`. Absent from `actions-runner-system` and `postgres` |
| `istio-injection: enabled` | Enables Istio sidecar injection in the namespace | `immich`, `gatus`, `atuin`, `kiali`, `renovate` |
| `istio-injection: disabled` | Disables Istio sidecar injection in the namespace | `erpnext`, `kellnr` |
| `goldilocks.fairwinds.com/enabled: "true"` | Enables Goldilocks VPA recommendations for workloads in the namespace | All 15 namespace files |

Namespaces use a subset as needed. For example, `actions-runner-system` and `postgres` set only the Goldilocks label. `default`, `dns`, `home-automation`, `lakehouse`, `lancache`, and `netboot` set the prune and Goldilocks labels without an Istio injection label.

## Registration and discovery

| Location | Registration |
|----------|--------------|
| `kubernetes/apps/<namespace>/kustomization.yaml` | Lists `./namespace.yaml`, each application's `ks.yaml`, and each component `ks.yaml` that lives in a separate file. `immich` lists `./namespace.yaml`, `./immich/ks.yaml`, and `./immich/backup/ks.yaml` |
| `kubernetes/apps/<namespace>/<app>/ks.yaml` | Defines one Flux Kustomization per component whose manifests have no separate `ks.yaml`. `immich/immich/ks.yaml` defines `immich`, `immich-db`, and `immich-dragonfly` |
| `kubernetes/apps/` | Has no root `kustomization.yaml`. The `cluster-apps` Kustomization in `kubernetes/flux/apps.yaml` sets `spec.path: ./kubernetes/apps`, and Flux builds the tree it finds |
| `kubernetes/operators/kustomization.yaml` | Explicit list of operator directories |

A namespace directory with a `kustomization.yaml` is discovered through the `cluster-apps` Kustomization without a root-level entry. Additional namespace-level files, such as `networkpolicy.yaml` in `home-automation` and `sa.yaml` in `default`, are listed in the namespace `kustomization.yaml` alongside the application entries.

## Examples

| Application | Path | Components | Flux Kustomizations |
|-------------|------|------------|---------------------|
| `gatus` | `kubernetes/apps/gatus/gatus/` | `app` | `gatus`, defined in `gatus/ks.yaml` |
| `atuin` | `kubernetes/apps/atuin/atuin/` | `app`, `db` | `atuin`, `atuin-db`, defined in `atuin/ks.yaml` |
| `immich` | `kubernetes/apps/immich/immich/` | `app`, `db`, `dragonfly`, `backup` | `immich`, `immich-db`, `immich-dragonfly` in `immich/ks.yaml`; `immich-backup` in `immich/backup/ks.yaml` |

## Related documents

- [Application Conventions Reference](reference-conventions.md)
- [Flux Deployment Model Explained](explanation-flux-deployment-model.md)
- [How to Add an Application](how-to-add-an-application.md)
