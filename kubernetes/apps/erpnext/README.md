# ERPNext Stack

ERPNext v16 (Frappe) on MariaDB + Valkey, deployed via Flux in the `erpnext` namespace and exposed at `https://erpnext.${SECRET_DOMAIN}` through the existing Cloudflare Tunnel → `istio-ingress/external-gateway` path, with Authentik OIDC as the single sign-on provider.

## Components

| Component | Source | Notes |
|---|---|---|
| ERPNext | Official Frappe Helm chart `erpnext` 8.0.84 (image `frappe/erpnext:v16.50.0`) | Full bench stack: gunicorn, nginx, socket.io, scheduler, workers default/short/long. All bundled DB/cache subcharts are disabled except Valkey |
| MariaDB | mariadb-operator `MariaDB` CR `erpnext-db` | Single instance, MariaDB 12.3.3, `utf8mb4` / `utf8mb4_unicode_ci`, 20Gi on `ceph-block-ssd`, root secret `erpnext-db-root` |
| Cache / queue | Chart-bundled Valkey subcharts (`valkey-cache`, `valkey-queue`) | `erpnext-valkey-cache` / `erpnext-valkey-queue` on port 6379, passwordless |
| Sites volume | PVC `erpnext-sites` | 20Gi, `ReadWriteMany`, `ceph-filesystem`. Shared by every app pod and the one-shot jobs |
| create-site job | `erpnext-create-site-v2` Job | One-shot `bench new-site`. Immutable, bump `-vN` to re-run |
| SSO job | `erpnext-sso-v3` Job | One-shot: sets the site `host_name`, then creates the Authentik Social Login Key idempotently |
| Exposer | Istio `VirtualService` `erpnext` | Websocket-safe route (no request timeout) |

## Architecture

The Frappe chart renders the whole bench as Kubernetes workloads: a gunicorn web tier, an nginx front proxy on port 8080, a socket.io server for realtime, a scheduler for background jobs, and three queue workers (default, short, long). Only the chart's bundled Valkey cache and queue subcharts are enabled; every MariaDB and PostgreSQL subchart is disabled because the database is provided out of band by mariadb-operator.

MariaDB is a single `MariaDB` CR managed by the mariadb-operator installed under `kubernetes/operators/mariadb-operator/`. The operator was given an egress rule to reach managed instances in the `erpnext` namespace on TCP 3306 (see `kubernetes/operators/mariadb-operator/operator/app/networkpolicy.yaml`).

Cache and queue are the chart's bundled Valkey subcharts (`erpnext-valkey-cache`, `erpnext-valkey-queue`, both port 6379, no auth). The chart plugs them into the bench config automatically; `common_site_config.json` ends up pointing `redis_cache`, `redis_queue`, and `redis_socketio` at those Services. This replaced an earlier Dragonfly design on purpose: Frappe v16 uses Redis client-side caching (`CLIENT TRACKING`), which requires RESP3, and Dragonfly rejects those commands. Valkey is the upstream-recommended backend and avoids the incompatibility.

All site data (database rows plus uploaded files) is durable and split across two storage locations: MariaDB rows live on the `storage-erpnext-db-0` PVC (`ceph-block-ssd`, RWO), and the files live on `erpnext-sites` (`ceph-filesystem`, RWX, 20Gi). The RWX volume is required because the running pods and the one-shot Jobs all mount the same `sites/` tree.

In-cluster endpoints:

| Service | URL |
|---|---|
| ERPNext site | `https://erpnext.${SECRET_DOMAIN}` |
| nginx Service (VirtualService target) | `erpnext.erpnext.svc.cluster.local:8080` |
| MariaDB | `erpnext-db.erpnext.svc.cluster.local:3306` |
| Valkey cache | `erpnext-valkey-cache:6379` |
| Valkey queue | `erpnext-valkey-queue:6379` |
| Authentik OIDC issuer | `https://auth.${SECRET_DOMAIN}/application/o/erpnext/` |

Flux Kustomization dependency graph (all in the `flux-system` namespace, deploying to `erpnext`):

```
mariadb-operator ─► erpnext-db ─► erpnext ─► erpnext-setup
                                     │  └──► erpnext-sso
                                     └─────► erpnext-backup  (also depends on volsync)
```

`erpnext` waits on `erpnext-db`; the three one-shots (`erpnext-setup`, `erpnext-sso`, `erpnext-backup`) each depend on `erpnext`. `erpnext-sso` depends on `erpnext-setup` so the site exists before the Social Login Key is inserted. `erpnext-backup` additionally depends on the `volsync` Kustomization.

The `erpnext` namespace NetworkPolicies are `allow-all` (namespace-wide ingress and egress) plus a Cilium `allow-node-egress` policy for kube-apiserver/host/remote-node on 443 and 6443. The backup bundle adds a pod-scoped `allow-volsync-mover` policy so the restic mover can reach MinIO and DNS. The namespace is not on the Kyverno `require-pod-resources` exclusion list, so every pod, including the one-shot job pods and the VolSync mover, must declare CPU/memory requests and a memory limit.

Secret material is SOPS/Age encrypted in git and never plaintext:
- `erpnext-db-root` (MariaDB root) at `kubernetes/apps/erpnext/erpnext/db/erpnext-db-root.sops.yaml`
- `erpnext-secret` (`admin-password`) at `kubernetes/apps/erpnext/erpnext/app/erpnext-secret.sops.yaml`
- `erpnext-oidc` (`client-id`, `client-secret`) at `kubernetes/apps/erpnext/erpnext/app/erpnext-oidc.sops.yaml`
- `erpnext-backup-secret` (S3 + restic credentials) at `kubernetes/apps/erpnext/erpnext/backup/erpnext-backup-secret.sops.yaml`

## Backups

Two independent schedules protect the two data locations. They are staggered so they do not contend:

| Target | Mechanism | Schedule (UTC) | Destination |
|---|---|---|---|
| MariaDB rows | mariadb-operator `Backup` CR `erpnext-db-backup` | `15 1 * * *` | `s3://cloudnative-pg/erpnext/` on MinIO, secret `pg-backup-secret` |
| Site files (`erpnext-sites`) | VolSync `ReplicationSource` `erpnext-backup` | `40 2 * * *` | `s3:http://minio-service.networking.svc.cluster.local:9768/volsync-backups/erpnext-sites`, secret `erpnext-backup-secret` |

The MariaDB `Backup` CR is a logical dump. It keeps `maxRetention: 720h` (30 days), writes objects under the `erpnext` prefix of the shared `cloudnative-pg` bucket, and authenticates with the Kyverno-replicated `pg-backup-secret` (`aws-access-key-id` / `aws-secret-access-key`).

The VolSync `ReplicationSource` backs up `erpnext-sites` with `copyMethod: Direct` (crash-consistent, reads the live volume, no snapshot clone). Retention is 7 daily / 4 weekly / 12 monthly, `pruneIntervalDays: 7`. The mover scratch and cache volumes both use `ceph-block` (10Gi cache). A paused `ReplicationDestination` `erpnext-restore` is committed alongside it for the restore drill.

Staggering note: the DB logical dump runs at 01:15 and the files snapshot at 02:40, more than an hour apart. A restore therefore cannot assume the two captured the exact same instant; see Restore for how to pick a consistent-enough set.

Health-check one-liners (all run against the live cluster; outputs in `.omo/evidence/erpnext-install/task-6-db-backup.txt`, `task-12-volsync.txt`, and `task-15-readme.txt`):

```sh
# MariaDB backup: scheduled CR, CronJob, and its embedded resources
kubectl -n erpnext get backup erpnext-db-backup
kubectl -n erpnext get backups.k8s.mariadb.com
kubectl -n erpnext get cronjob erpnext-db-backup -o wide
kubectl -n erpnext get cronjob erpnext-db-backup -o jsonpath='{.spec.jobTemplate.spec.template.spec.containers[0].resources}'

# VolSync files backup: source, destination, and last sync status
kubectl -n erpnext get replicationsource erpnext-backup
kubectl -n erpnext get replicationsource erpnext-backup -o jsonpath='{.status.latestMoverStatus.result}'
kubectl -n erpnext get replicationdestination erpnext-restore
```

To confirm the MinIO object the logical dump produced, run an AWS CLI pod with the backup secret (this exact pattern was used in `wave2-verify-backup-recheck.txt`; `minio/mc` was removed from Docker Hub so `amazon/aws-cli` is pinned instead):

```sh
kubectl -n erpnext run erpnext-backup-objcheck --rm -i --restart=Never \
  --image=amazon/aws-cli:2.32.7 \
  --overrides='{"spec":{"containers":[{"name":"erpnext-backup-objcheck","image":"amazon/aws-cli:2.32.7","args":["--endpoint-url","http://minio-service.networking.svc.cluster.local:9768","s3","ls","--recursive","s3://cloudnative-pg/erpnext/"],"env":[{"name":"AWS_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"pg-backup-secret","key":"aws-access-key-id"}}},{"name":"AWS_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"pg-backup-secret","key":"aws-secret-access-key"}}}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"},"limits":{"cpu":"500m","memory":"256Mi"}}}]}}'
```

To list the restic snapshots for the files repository, run a restic pod with the backup secret (this is the repository VolSync writes to). Verified 2026-10-14, it prints the two snapshots and exits 0:

```sh
kubectl -n erpnext run erpnext-restic-list --rm -i --restart=Never \
  --image=quay.io/backube/volsync:0.16.0 \
  --overrides='{"spec":{"containers":[{"name":"erpnext-restic-list","image":"quay.io/backube/volsync:0.16.0","command":["restic","snapshots","--no-lock"],"envFrom":[{"secretRef":{"name":"erpnext-backup-secret"}}],"resources":{"requests":{"cpu":"100m","memory":"128Mi"},"limits":{"cpu":"500m","memory":"256Mi"}}}]}}'
```

Files backup state (verified 2026-10-14): the VolSync mover runs with declared resources and both cache PVCs (`volsync-src-erpnext-backup-cache`, `volsync-dst-erpnext-restore-cache`) bind `ReadWriteOnce` on `ceph-block`. The restic repository `volsync-backups/erpnext-sites` is initialized, and the listing command above returns two snapshots (`4a074151`, `8ea0483e`). A fresh manual sync produced `8ea0483e` with `.status.latestMoverStatus.result` reading `Successful`, and a restore drill against a scratch PVC succeeded the same day (see Restore). The MariaDB logical dump remains the DB backup of record.

Mover spec rationale:

- `restic.moverResources` (requests `cpu: 100m` / `memory: 256Mi`, limits `cpu: 500m` / `memory: 512Mi`): `erpnext` is not on the Kyverno `require-pod-resources` exclusion list, so the mover pod must declare CPU/memory requests plus a memory limit, or the admission webhook denies it. The missing field was the original blocker.
- `cacheAccessModes: [ReadWriteOnce]`: the source `erpnext-sites` PVC is `ReadWriteMany` (`ceph-filesystem`), but the cache PVC lands on `ceph-block` (RBD), which only supports RWO. Without pinning the mode, VolSync derives RWX from the source PVC and the cache PVC fails to bind.
- `moverSecurityContext` (`runAsUser` / `runAsGroup` / `fsGroup: 1000`): set on the `ReplicationDestination` only. A restore writes into the `erpnext-sites` tree, which is owned by uid 1000, so the mover runs as that uid; `fsGroup` keeps a fresh restore target writable. The `ReplicationSource` doesn't need it because the live site files are world-readable (`755` dirs / `644` files).

Manual-trigger note: patching `spec.trigger.manual` on the live `ReplicationSource` starts a sync, but Flux reverts the field on its next reconcile interval. That is expected, not a failure. Track completion through `.status.latestMoverStatus.result` (`Successful`) and `.status.lastSyncTime`, not through the trigger field.

## Restore

There are two restore paths, one per data location. Do the files restore and the database restore as a pair, because ERPNext records (for example, uploaded file attachments) link the two.

### VolSync files restore

The committed `ReplicationDestination` `erpnext-restore` is `paused: true` on purpose; restores are deliberate and manual. Two forms are used, depending on whether you are drilling or replacing the live volume.

Scratch drill (executed and verified 2026-10-14; safe, touches no production data): restore the latest snapshot into a throwaway PVC, mount it, confirm a known path exists, then delete the scratch resources. The full flow is written up in `docs/backup-restore.md` (section 3); the ERPNext-specific variant is:

1. Create a scratch 20Gi PVC (`erpnext-sites-restore-test`, `ceph-filesystem`).
2. Apply a scratch `ReplicationDestination` (copy the committed one) with `destinationPVC: erpnext-sites-restore-test`, `paused: false`, and a unique `trigger.manual` value such as `restore-<unix-ts>`.
3. Poll `kubectl -n erpnext get replicationdestination <scratch> -o json` until `.status.latestMoverStatus.result` is `Successful`.
4. Mount the scratch PVC in a temp pod and confirm the site tree exists. The `erpnext-sites` volume root IS the frappe `sites/` directory (the app mounts it at `/home/frappe/frappe-bench/sites`), so the verified path is `<root>/<site>/site_config.json` with no extra `sites/` prefix. Expect `apps.txt`, a symlink `assets`, `common_site_config.json`, and one `<site>/` directory containing `site_config.json` plus `locks`, `logs`, `private`, and `public`.
5. Delete the scratch PVC and the scratch ReplicationDestination once the evidence is captured.

The 2026-10-14 drill restored snapshot `8ea0483e` into `erpnext-sites-restore-test`, and the mounted tree matched the live volume's layout (`apps.txt`, symlink `assets`, `common_site_config.json`, `<site>/site_config.json`). A wrong `RESTIC_PASSWORD` probe also fails closed (`exit 12`, `Fatal: wrong password or no key found`), so the committed secret is the only working credential.

Restore over the live PVC (procedure, not yet exercised; only when replacing production files):

1. Pause the VolSync source so the scheduled cron does not snapshot the volume mid-restore, and scale the app tier to zero (`kubectl -n erpnext scale deploy erpnext-nginx erpnext-gunicorn erpnext-socketio --replicas=0`) so nothing writes the volume.
2. Un-pause `erpnext-restore` and set a unique `trigger.manual`, in one change. Per `docs/backup-restore.md`, patch `paused` and `trigger` together, never the trigger alone, or Flux reverting `paused` mid-flight wedges the mover Job.
3. Wait for `.status.latestMoverStatus.result: Successful`.
4. Scale the app back up, re-pause `erpnext-restore`, and un-pause the source.
5. Confirm the site loads and `bench --site erpnext.${SECRET_DOMAIN} list-apps` still reports `erpnext`.

The mover restores the latest snapshot by default. A new restic password means a new repository; restic cannot open the old repo with a new password, so never rotate `RESTIC_PASSWORD` in `erpnext-backup-secret` against an existing repository (`docs/backup-restore.md`, section 4).

### MariaDB dump restore (procedure)

The logical dump is a plain SQL file. To restore it:

1. List the available dumps in MinIO with the AWS CLI pod above and pick a timestamp (`erpnext/backup.2026-10-14T06:15:38Z.sql` format).
2. Extract the object and load it into the running MariaDB. Two equivalent routes:
   - `bench --site erpnext.${SECRET_DOMAIN} restore <path-to-sql>` from a pod that mounts the dump, or
   - pipe the file into the `mariadb` client via `kubectl -n erpnext exec erpnext-db-0 -c mariadb -- ...` using the root credentials from the `erpnext-db-root` secret (read the password from the container environment like the charset check does, and never echo it).
3. Because the dump is a schema-level restore, take a fresh backup first if the current data still matters, and coordinate with the files restore so the two are consistent enough.

Consistency ordering: the DB dump runs at 01:15 and the files snapshot at 02:40. If you need a matched set, prefer the files snapshot at 02:40 and the DB dump from the same night at 01:15 (the 85-minute gap means the DB reflects slightly earlier state than the files). Neither VolSync nor `bench backup` quiesces the database, and the VolSync mover reads the live volume (`copyMethod: Direct`), so both are crash-consistent, not application-consistent.

## Upgrade / migrate

Upgrading ERPNext means bumping the chart and image, then running the schema migration exactly once as a Job.

1. Take a fresh backup first. Confirm a recent logical dump exists (`kubectl -n erpnext get backup erpnext-db-backup`) and a recent restic snapshot (see the restic listing command in Backups). Do not migrate without a restorable backup.
2. Bump the versions in `kubernetes/apps/erpnext/erpnext/app/helmrelease.yaml`: `spec.chart.spec.version` (chart `erpnext`) and `spec.values.image.tag` (image `frappe/erpnext`). Renovate opens these as `feat(helm):` / `fix(container):` pull requests.
3. Run the migration. The chart ships `templates/job-migrate-site.yaml` (gated by `jobs.migrate.enabled`, which stays `false` in the HelmRelease). Render it with `helm template` using the chart version and the values extracted from the HelmRelease, then commit the rendered Job into the existing `kubernetes/apps/erpnext/erpnext/setup/` directory (or a sibling job directory) under a versioned name, for example `erpnext-migrate-v1`, bumping the suffix (`-vN`) for each re-run.
4. Reconcile and watch: `kubectl -n erpnext get job erpnext-migrate-v1` and `kubectl -n erpnext logs job/erpnext-migrate-v1` show the `bench migrate` progress and any schema errors.
5. Rollback: app rollback is `git revert` of the version bump plus `flux reconcile kustomization erpnext -n flux-system`. Data rollback is a restore from the backup taken in step 1 (SQL dump plus the files snapshot).

This migrate flow has not been exercised yet in this cluster; it is the documented procedure based on the chart's `job-migrate-site.yaml` template and matches the create-site rendering convention. Treat the first real migration as a drill: do it on a fresh backup and watch the Job logs.

## SSO

ERPNext signs users in through Authentik as a "Custom" social login provider named `authentik`. The OIDC provider and application are declared in the Authentik blueprint `kubernetes/core/authentik/authentik/app/blueprint-erpnext.sops.yaml` (Secret `authentik-blueprint-erpnext`); the matching client credentials for ERPNext live in `kubernetes/apps/erpnext/erpnext/app/erpnext-oidc.sops.yaml` (Secret `erpnext-oidc`).

Login flow:

1. A user opens `https://erpnext.${SECRET_DOMAIN}/login` and picks "Login with authentik".
2. ERPNext redirects to `https://auth.${SECRET_DOMAIN}/application/o/authorize/` (Authentik, provider `erpnext`).
3. Authentik authenticates the user and redirects back to the registered callback `/api/method/frappe.integrations.oauth2_logins.custom/authentik`.
4. ERPNext exchanges the code at `/application/o/token/`, reads the userinfo at `/application/o/userinfo/`, and links or creates the local user by the `sub` claim.

The Social Login Key is created by the one-shot `erpnext-sso-v3` Job (`kubernetes/apps/erpnext/erpnext/sso/job-erpnext-sso.yaml`). It waits for the site, sets the site `host_name` to `https://erpnext.${SECRET_DOMAIN}` (so Frappe emits an `https://` `redirect_uri`), then inserts a `Social Login Key` doc with `social_login_provider: Custom`, `provider_name: authentik`, `base_url: https://auth.${SECRET_DOMAIN}`, `custom_base_url: 1`, and `sign_ups: Allow`. It reads `client-id` and `client-secret` from `erpnext-oidc` and skips the insert when the `authentik` key already exists, so re-runs are idempotent.

Admin email linkage caveat: SSO links an Authentik identity to a local ERPNext user by email. The site's first administrator is created by `bench new-site` with the admin password from `erpnext-secret`; until that administrator's email matches the Authentik user's email (or a user is created for the SSO identity), the first SSO login will create or link a separate user rather than logging in as the site administrator. Set the administrator email (or use Authentik's `akadmin` email) before relying on SSO for admin access. Local password login keeps working alongside SSO.

Rotating the client secret: the secret exists in two places and must stay in parity. Edit both, in the same commit, then encrypt and push:

- `kubernetes/core/authentik/authentik/app/blueprint-erpnext.sops.yaml` (the blueprint's `client_secret`)
- `kubernetes/apps/erpnext/erpnext/app/erpnext-oidc.sops.yaml` (the `client-secret` key)

```sh
make sops-encrypt
```

Then reconcile the Authentik and `erpnext` Kustomizations so both copies land together. A mismatch is the top SSO failure mode and shows up as a token-exchange error on the callback.

Disabling SSO: turn `enable_social_login` off, or delete the `Social Login Key` doc for provider `authentik` (for example `bench --site erpnext.${SECRET_DOMAIN} execute frappe.client.delete --kwargs '{"doctype":"Social Login Key","name":"authentik"}'`). Local email/password login is unaffected.

Status (verified 2026-10-14): SSO is ACTIVE. The one-shot `erpnext-sso-v3` Job is `Complete 1/1`, the `authentik` Social Login Key exists, and the login page renders a "Login with authentik" button whose authorize hop returns HTTP 302 into the Authentik flow; local admin login returns HTTP 200. The authorize hop is the SSO health check.

History: v1 failed with `TypeError: insert() got an unexpected keyword argument 'doctype'` because `bench execute frappe.client.insert` expects the document wrapped as `{"doc": {...}}`, not the fields at the top level. v2 corrected the payload but the authorize hop returned HTTP 400 (`invalid, or mismatching redirection URI`) because the site's `host_name` was unset, so Frappe built the `redirect_uri` with an `http://` scheme against the blueprint's strict `https://` registration. v3 bakes in the `host_name` fix and the idempotency guard, so a rebuild is reproducible. Local email/password login keeps working alongside SSO.

## Health checks

Run these to confirm the stack is healthy. Outputs are captured in `.omo/evidence/erpnext-install/task-15-readme.txt`.

```sh
# Flux: all five Kustomizations should be Ready True
flux get ks -n flux-system | grep erpnext

# Helm release and all Deployments
kubectl -n erpnext get hr erpnext
kubectl -n erpnext get deploy

# Site is live (expect HTTP/2 200) and apps are installed
curl -sSI https://erpnext.${SECRET_DOMAIN}/login | head -1
kubectl -n erpnext exec deploy/erpnext-gunicorn -- bench --site erpnext.${SECRET_DOMAIN} list-apps

# Data layer
kubectl -n erpnext get mariadb erpnext-db -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
kubectl -n erpnext get pvc erpnext-sites
kubectl -n erpnext exec deploy/erpnext-valkey-cache -- valkey-cli ping     # expect PONG
kubectl -n erpnext exec deploy/erpnext-valkey-queue -- redis-cli ping      # expect PONG

# Server charset (read the root password from the container env; never echo it)
kubectl -n erpnext exec erpnext-db-0 -c mariadb -- sh -c \
  'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot -N -e "SHOW VARIABLES LIKE \"character_set_server\"; SHOW VARIABLES LIKE \"collation_server\";"'

# Backups (see Backups section for the full commands)
kubectl -n erpnext get backup erpnext-db-backup
kubectl -n erpnext get replicationsource erpnext-backup
```

## Caveats

- Jobs are immutable. To re-run `erpnext-create-site-v2` or `erpnext-sso-v3`, bump the version suffix (`-v2` → `-v3`, `-v3` → `-v4`), commit, and push. Flux creates a new Job with the new name; re-applying the identical committed Job is a no-op and will not create a second site.
- After `create-site`, gunicorn does not restart itself (the chart has no pod-template checksum annotation or restart hook). If the site was just created and `/login` unexpectedly returns 404 or 500, restart gunicorn once: `kubectl -n erpnext delete pod -l app.kubernetes.io/name=erpnext-gunicorn`. The ReplicaSet recreates it from the unchanged spec. This is an operational restart only; no manifest change.
- The Authentik blueprint uses no-delete semantics: removing the blueprint entry does not delete the provider or application in Authentik. Clean those up in the Authentik UI/API if you retire SSO.
- `host_name`: the `erpnext-sso-v3` Job sets the site `host_name` to `https://erpnext.${SECRET_DOMAIN}` so the authorize hop emits an `https://` `redirect_uri` matching the blueprint's strict registration. If the public URL ever changes, update that value (or run `bench --site erpnext.${SECRET_DOMAIN} set-config host_name https://erpnext.${SECRET_DOMAIN}`) and re-run the SSO Job.
- No Prometheus alerting rules were added for ERPNext on purpose. Backup and health visibility is via the status-check commands above, not alerts.
- `bench execute frappe.db.get_value --doctype ...` (used in the plan's acceptance criteria) is not a valid bench invocation in v16; use a `bench --site ... execute <method> --kwargs '<json>'` form instead.
- Ceph volumes are not encrypted at rest; accepted for home use.
