# Austin VM (`austin-vm`)

A persistent Arch Linux workstation for Austin, running as a KubeVirt
`VirtualMachine` in the `vms` namespace. It exists so Austin can run
`kubectl`, `helm`, `flux`, `gh`, and Docker to build and tune GitHub Actions
runner scale sets without holding cluster-admin.

| Item | Value |
| --- | --- |
| Hostname | `austin-vm.${SECRET_DOMAIN}` (the existing `*.${SECRET_DOMAIN}` wildcard resolves to the Cloudflare Tunnel) |
| Compute | 4 vCPU, 8 GiB guest memory |
| Root disk | 120 GiB `DataVolume` named `austin-vm-root` on `ceph-block-ssd` |
| Image | Pinned Arch Linux `cloudimg` qcow2 imported by CDI |
| SSH Service | `austin-vm-ssh.vms.svc.cluster.local:22` (ClusterIP) |
| Flux Kustomization | `arch-vm` in `flux-system` (path `./kubernetes/apps/vms/arch-vm/app`) |
| Kubernetes identity | ServiceAccount `vms/austin`, surfaced as `system:serviceaccount:vms:austin` |

`${SECRET_DOMAIN}` is the Flux substitution used throughout this repository.
Substitute the real cluster domain wherever it appears in a command you run.

Access is SSH through the existing Cloudflare Tunnel. There is no public
Kubernetes API endpoint for this VM, no public SSH port, no password login, and
no root login. The `austin` user is key-only and gets passwordless `sudo`.

## Prerequisites on Austin's machine

- `cloudflared` installed and on `PATH`.
- Your Ed25519 private key (the matching public key is in
  `kubernetes/apps/vms/arch-vm/app/austin-ssh-key.sops.yaml`).
- An SSH client. `kubectl` is only needed if you want to drive the cluster from
  your own machine rather than from inside the VM.

If the Cloudflare Tunnel is behind a Cloudflare Access application, the first
connection opens a browser prompt. Complete it, then retry the command. The
`cloudflared` client caches the Access token until it expires.

## SSH

Add this to `~/.ssh/config`:

```sshconfig
Host austin-vm.${SECRET_DOMAIN}
  User austin
  IdentityFile ~/.ssh/id_ed25519
  ProxyCommand cloudflared access ssh --hostname %h
```

SSH does not expand `${SECRET_DOMAIN}` itself, so replace it with the cluster
domain before saving the file, for example `Host austin-vm.example.com`. After
that, a normal `ssh` invocation works:

```sh
ssh austin-vm.<cluster-domain>
```

If you do not want to edit `~/.ssh/config`, run a local TCP proxy in one
terminal and SSH through it in another:

```sh
cloudflared access tcp --hostname austin-vm.${SECRET_DOMAIN} --url localhost:2222
```

```sh
ssh -p 2222 austin@localhost
```

Both forms tunnel over the Cloudflare Tunnel. Nothing listens on the public
internet, and the VM's SSH Service is a cluster-internal `ClusterIP`.

## Kubernetes access inside the VM

The VM image only creates `/home/austin/.kube` (mode `0700`, owned by
`austin`). It does not contain a kubeconfig at first boot. After the change is
merged, the owner generates a bound token for `vms/austin`, writes the
kubeconfig to `/home/austin/.kube/config` over SSH (mode `0600`, owned by
`austin`), and verifies it. Until that step is done, `kubectl` inside the VM has
no credentials.

The resulting kubeconfig has:

- Server: the cluster API endpoint, reachable from inside the VM.
- Identity: `system:serviceaccount:vms:austin`.
- Default context namespace: `austin-ci`.

Check it with:

```sh
kubectl auth whoami
# system:serviceaccount:vms:austin
kubectl config view --minify -o jsonpath='{.contexts[0].context.namespace}'
# austin-ci
```

The token is never committed. It is not stored in Git, not in a SOPS file, and
not printed in logs.

### RBAC matrix

| Scope | Access | Notes |
| --- | --- | --- |
| `vms` | Read-only (`austin-vm-view`) | `get/list/watch` on KubeVirt `virtualmachines`/`virtualmachineinstances`, CDI `datavolumes`, pods, services, endpoints, events, configmaps, PVCs, pod logs, and NetworkPolicies. No pod create/exec, no Secret access. |
| `testing` | Read-only (`austin-workload-view`) | `get/list/watch` on pods, services, endpoints, events, configmaps, PVCs, pod logs, Deployments/StatefulSets/ReplicaSets/DaemonSets, Jobs/CronJobs, Ingresses, NetworkPolicies, and PodDisruptionBudgets. No pod create/exec, no Secret access. |
| `austin-ci` | `austin-ci-operator` plus ARC CRUD | Full CRUD on HelmReleases; read-only on Helm sources and workloads; `create` on Secrets only (no read/update/delete). No pod create/exec. `austin-arc-admin` adds CRUD on `actions.github.com` resources. |
| `actions-runner-system` | Read-only | `view` plus read-only ARC resources. The controller and existing runner scale sets cannot be changed. |
| `flux-system` | Limited | `get/list/watch` on Kustomizations and GitRepositories. `update/patch` only on `austin-runners` and `austin-apps`. No GitRepository write, no `create`, no `delete`, no Secret access. |
| Cluster-scoped resources | None | `kubectl get nodes`, `kubectl create namespace`, and similar calls return `Forbidden`. |

The cluster-scoped denials are deliberate. `austin-helm` and `austin-flux` are
namespace-scoped ServiceAccounts, so a chart or Kustomization that tries to
create a ClusterRole, CRD, or other cluster-scoped object fails at admission or
apply time.

The ARC controller/chart runtime identities are separate from Austin's own
ServiceAccount: `austin-flux` (Kustomize controller) and `austin-helm` (the
ServiceAccount impersonated by every HelmRelease) keep namespace `admin` plus
`austin-arc-admin` in `austin-ci` because they must create runner pods, exec
into them, and read chart-provided Secrets. `vms/austin` cannot.

### Flux workflow

All durable changes go through a pull request. Direct pushes to the cluster are
not part of this workflow.

- Runner scale sets: `kubernetes/apps/austin/runners/app`
- Everything else that installs into `austin-ci`:
  `kubernetes/apps/austin/apps/app`

Two owner-created Kustomizations carry those paths:

| Kustomization | Path | Target | Service account |
| --- | --- | --- | --- |
| `austin-runners` | `./kubernetes/apps/austin/runners/app` | `austin-ci` | `austin-flux` |
| `austin-apps` | `./kubernetes/apps/austin/apps/app` | `austin-ci` | `austin-flux` |

Austin can `get/update/patch` those two objects. He cannot create, rename,
delete, or repoint them. The path, `targetNamespace`, `sourceRef`, and
`serviceAccountName` are checked by the `austin-kustomization-guard` Kyverno
policy, so an edited value is denied.

Every `HelmRelease` must live in `austin-ci` and set
`spec.serviceAccountName: austin-helm`. The
`austin-ci-helmrelease-guard` Kyverno policy denies a HelmRelease that omits it
or uses another ServiceAccount. The `austin-helm` ServiceAccount only has
permissions in `austin-ci`, which keeps a chart from creating cluster-scoped
resources.

After a PR merges, reconcile:

```sh
flux reconcile kustomization austin-runners -n flux-system
flux reconcile kustomization austin-apps -n flux-system
kubectl -n austin-ci get helmrelease,pods
```

Without `--with-source`, Flux applies the revision already fetched by the
`flux-system` GitRepository. If a just-merged commit is not visible yet, wait for
the GitRepository interval or ask the owner to reconcile the source; Austin has
no write access to the GitRepository.

## Rotating the SSH key

The SSH public key is stored in
`kubernetes/apps/vms/arch-vm/app/austin-ssh-key.sops.yaml`. The VM consumes it
through KubeVirt `accessCredentials` with `propagationMethod.qemuGuestAgent`, so
the live guest updates `/home/austin/.ssh/authorized_keys` when the Secret
changes. No reboot is needed.

1. Replace the key in the decrypted Secret and re-encrypt:

   ```sh
   sops kubernetes/apps/vms/arch-vm/app/austin-ssh-key.sops.yaml
   make sops-encrypt
   ```

2. Open a PR and merge it.
3. Reconcile the VM:

   ```sh
   # Austin's ServiceAccount cannot reconcile arch-vm; run this as the cluster owner.
   flux reconcile kustomization arch-vm -n flux-system
   ```

4. Confirm the guest picked up the key:

   ```sh
   ssh austin-vm.<cluster-domain> 'cat ~/.ssh/authorized_keys'
   ```

To remove a key, delete only that line from the Secret and repeat the same
steps. The guest agent removes it from `authorized_keys`.

Rotating the key does not touch the Kubernetes token, and rotating the token
does not touch the SSH key.

## Rotating the Kubernetes token

Run these steps as the cluster owner from a context with access to `vms`. The
token is short-lived and bound to the `vms/austin` ServiceAccount.

```sh
# 1. Issue a new bound token. Fall back to 720h if 8760h is rejected.
TOKEN="$(kubectl -n vms create token austin --duration=8760h)"

# 2. Build a kubeconfig locally.
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
CA="$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
kubectl config set-cluster austin-vm --server="$SERVER" \
  --certificate-authority-data="$CA" --embed-certs=true \
  --kubeconfig=/tmp/austin.kubeconfig
kubectl config set-credentials austin --token="$TOKEN" \
  --kubeconfig=/tmp/austin.kubeconfig
kubectl config set-context austin-vm --cluster=austin-vm --user=austin \
  --namespace=austin-ci --kubeconfig=/tmp/austin.kubeconfig
kubectl config use-context austin-vm --kubeconfig=/tmp/austin.kubeconfig
chmod 600 /tmp/austin.kubeconfig

# 3. Write it to the VM over SSH without printing it.
ssh austin-vm.<cluster-domain> 'umask 077; mkdir -p ~/.kube; cat > ~/.kube/config' \
  < /tmp/austin.kubeconfig

# 4. Verify, then delete the local copy.
ssh austin-vm.<cluster-domain> 'kubectl auth whoami'
shred -u /tmp/austin.kubeconfig 2>/dev/null || rm -f /tmp/austin.kubeconfig
```

Never commit the token or the kubeconfig. Do not paste them into a PR, an
issue, or chat. To revoke a token immediately, delete and recreate the
`vms/austin` ServiceAccount: deleting the ServiceAccount invalidates every
outstanding bound token for it. Otherwise the token expires at the requested
duration.

## Cleanup and removal

Deleting the VM disk is destructive and there is **no VolSync backup** for this
VM. Copy anything you need off the guest before you start.

Stop the reconcilers first, so Flux does not recreate objects while you remove
them:

```sh
flux suspend kustomization austin-runners -n flux-system
flux suspend kustomization austin-apps -n flux-system
flux suspend kustomization arch-vm -n flux-system
```

Remove the VM through Git (preferred), then reconcile:

1. Delete `virtualmachine.yaml`, `datavolume.yaml`, `service.yaml`,
   `cloud-init.sops.yaml`, and `austin-ssh-key.sops.yaml` from
   `kubernetes/apps/vms/arch-vm/app/`, and remove them from that directory's
   `kustomization.yaml`.
2. Open a PR and merge it, then resume `arch-vm` so Flux prunes the objects.
   `arch-vm` has `prune: true`, so the `VirtualMachine`, `DataVolume`, and
   `Service` are removed.

For an emergency removal, suspend the Kustomizations and delete the objects
directly:

```sh
kubectl -n vms delete virtualmachine austin-vm
kubectl -n vms delete datavolume austin-vm-root
```

Deleting the `austin-vm-root` DataVolume deletes its PVC and the underlying
`ceph-block-ssd` volume. The 120 GiB of data is gone and cannot be recovered
from this repository. If the PVC survives, remove it explicitly:

```sh
kubectl -n vms delete pvc austin-vm-root
```

Finally, remove the fixed Flux Kustomizations (`austin-runners`, `austin-apps`,
and optionally `austin-rbac`), the `austin-ci` namespace, and the
`austin-vm.${SECRET_DOMAIN}` ingress rule from
`kubernetes/infra/networking/cloudflared/app/configs/config.yaml`. All of those
changes go through a PR.

## Residual risk

This is a scoped delegation, not cluster-admin, but it is not risk-free.

- `austin-ci` is `pod-security.kubernetes.io/enforce: privileged` because the
  ARC runner uses privileged `docker:dind`. A HelmRelease in that namespace can
  therefore create a privileged pod, which has node-level trust.
- HelmReleases can create privileged pods by design. The `austin-helm`
  ServiceAccount prevents cluster-scoped resources, not privileged namespaced
  workloads.
- Austin's own `vms/austin` ServiceAccount cannot create pods, exec, or read
  Secrets anywhere. The node-level trust comes from the `austin-flux`/`austin-helm`
  runtime identities that install and run the chart, not from Austin's identity.
- The owner's GitHub App private key is not copied into `austin-ci`. Austin
  creates and owns a separate GitHub App Secret, so a compromise of his identity
  does not expose the owner's credential.
- There is no chart allowlist yet. Every chart added to `austin-ci` needs a
  real review, not just a version bump.
- The two fixed Kustomizations apply whatever is in their fixed paths. PR
  review of `kubernetes/apps/austin/**` is the control that keeps that content
  safe.
- The VM has no backup. A lost PVC or a deleted DataVolume cannot be restored
  from this repository.
