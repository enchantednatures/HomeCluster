# Austin apps

This is the second fixed Flux path: the Kustomization `austin-apps`
(`kubernetes/apps/austin/apps/ks.yaml`) applies every manifest in this
directory into `austin-ci` with `serviceAccountName: austin-flux`.

The directory is intentionally empty (`resources: []`). It exists so the owner
can approve additional `HelmRelease` objects for `austin-ci` without creating
another Flux Kustomization. Austin gets `get/update/patch` on the two fixed
Kustomizations only; he cannot create or delete Kustomizations.

## What belongs here

- `HelmRelease` objects for charts that are not GitHub Actions runner scale
  sets (those go in `../runners/app/` with the `github-auth-secret` copy).
- Supporting namespaced objects the chart needs, such as a `Secret` copy or a
  `ConfigMap`, when the chart cannot render them itself.

## Rules

1. Every `HelmRelease` must set `serviceAccountName: austin-helm`. The
   `austin-ci-helmrelease-guard` Kyverno policy denies any other value.
2. The chart `serviceAccountName` is namespace-scoped: it can only create
   namespaced resources in `austin-ci`. Cluster-scoped chart content will fail.
3. Pin every chart version and every container image tag. No `latest`, no
   untagged images, no floating branches.
4. Set resource requests and limits on every container.
5. `austin-ci` is `pod-security.kubernetes.io/enforce: privileged`, so a
   privileged pod here is permitted by policy but has node-level trust. Keep the
   set of installed charts small and reviewed.
6. Put secrets only in `*.sops.yaml` files and encrypt with `make sops-encrypt`.
   Never commit a plaintext Secret or a token.
7. Add each new file to `kustomization.yaml` under `resources`, then open a PR.

## Adding an object

```sh
# create the manifest in this directory
$EDITOR my-app.yaml

# add it to the resource list
$EDITOR kustomization.yaml

# validate before committing
kustomize build kubernetes/apps/austin/apps/app
make kubernetes-kubeconform
make sops-encrypt
```

After the PR merges:

```sh
flux reconcile kustomization austin-apps -n flux-system --with-source
kubectl -n austin-ci get helmrelease,pods
```
