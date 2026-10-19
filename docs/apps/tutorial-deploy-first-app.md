# Tutorial: Deploy Your First Application

This tutorial walks through the complete onboarding path for an application: create a namespace, write a HelmRelease, define the Flux Kustomization that delivers it, register it in Git, and watch Flux reconcile it into the cluster.

You will deploy a throwaway demo application (`podinfo`) into a new `demo` namespace. The app has no database, no external hostname, and no secrets. The goal is to learn the file layout and the Git → Flux → workload flow.

> **This is a learning exercise.** It creates real resources in the cluster. Clean up when you are done.

## Prerequisites

- A checkout of this repository with push access
- `kubectl` configured against the cluster
- The `flux` CLI
- `make` — all repository commands are Makefile targets (`make help` lists them)
- A working Flux installation (see the [Deployment Guide](../deployment-guide.md) for a fresh bootstrap)

No SOPS/Age key is needed because the demo app has no secrets.

## Step 1: Create the namespace

Create `kubernetes/apps/demo/namespace.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/v1/namespace.json
---
apiVersion: v1
kind: Namespace
metadata:
  name: demo
  labels:
    kustomize.toolkit.fluxcd.io/prune: disabled
    goldilocks.fairwinds.com/enabled: "true"
```

The `kustomize.toolkit.fluxcd.io/prune: disabled` label stops Flux from deleting the Namespace object when the manifests disappear from Git. You will still delete it manually during cleanup.

## Step 2: Create the namespace index

Create `kubernetes/apps/demo/kustomization.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./namespace.yaml
  - ./podinfo/ks.yaml
```

This file is the registration point. Flux discovers `kubernetes/apps/demo/` because the directory contains a `kustomization.yaml`, and this file tells Flux which Kustomizations exist in the namespace. Nothing under `kubernetes/flux/` needs to change.

> The file references `./podinfo/ks.yaml` before it exists. That is expected; the next steps create it.

## Step 3: Create the application directory

Create `kubernetes/apps/demo/podinfo/app/kustomization.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
```

## Step 4: Write the HelmRelease

Create `kubernetes/apps/demo/podinfo/app/helmrelease.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/helm.toolkit.fluxcd.io/helmrelease_v2.json
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: podinfo
spec:
  driftDetection:
    mode: enabled
  maxHistory: 2
  interval: 30m
  chart:
    spec:
      chart: app-template
      version: 3.7.3 # datasource=helm depName=app-template repository=oci://ghcr.io/bjw-s/helm
      sourceRef:
        kind: HelmRepository
        name: bjw-s
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
    controllers:
      podinfo:
        containers:
          app:
            image:
              repository: ghcr.io/stefanprodan/podinfo
              # datasource=docker depName=ghcr.io/stefanprodan/podinfo
              tag: 6.9.2
    service:
      app:
        controller: podinfo
        ports:
          http:
            port: 9898
```

What matters here:

- `chart.spec.version` is pinned, with a Renovate annotation so upgrades arrive through chart bumps.
- `sourceRef` points at the `bjw-s` HelmRepository in `flux-system`; the repository is defined in `kubernetes/flux/repositories/oci/bjw-s.yaml`.
- The `app-template` chart turns the `values` block into a Deployment and a Service. The demo image answers on port 9898.
- No `metadata.namespace` is set; the Flux Kustomization's `targetNamespace` supplies it.

## Step 5: Write the Flux Kustomization

Create `kubernetes/apps/demo/podinfo/ks.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app podinfo
  namespace: flux-system
spec:
  targetNamespace: demo
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./kubernetes/apps/demo/podinfo/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  interval: 30m
  retryInterval: 1m
  timeout: 5m
```

This object lives in `flux-system`, deploys into `demo`, and applies everything under the `path`. There is no `dependsOn` because the app needs no operator or sibling component. There is no `decryption` or `postBuild` block; the `cluster-apps` parent injects those into every app Kustomization (see [How Applications Deploy](explanation-flux-deployment-model.md)).

## Step 6: Validate

Run:

```bash
make kubernetes-kubeconform
```

Expected: the command finishes without schema errors. The target renders every `kustomization.yaml` under `kubernetes/apps`, so it catches broken resource paths and schema mistakes in the new files.

> `make kubernetes-kubeconform` does not scan `kubernetes/operators`, `kubernetes/core`, or `kubernetes/infra`.

## Step 7: Commit and push

```bash
git add kubernetes/apps/demo
git commit -m "feat(demo): add podinfo tutorial app"
git push
```

## Step 8: Watch Flux reconcile

Force the root Kustomization to pick up the new commit:

```bash
make flux-reconcile
flux get kustomizations --watch
```

Wait until a `podinfo` Kustomization appears with `READY=True`:

```
NAME            REVISION        SUSPENDED   READY   MESSAGE
cluster         main@sha1:...   False       True    Applied revision: main@sha1:...
cluster-apps    main@sha1:...   False       True    Applied revision: main@sha1:...
podinfo         main@sha1:...   False       True    Applied revision: main@sha1:...
```

Press `Ctrl+C` to stop watching. Then confirm the Helm release and the pod:

```bash
flux get helmreleases -n demo
kubectl get pods -n demo
```

Expected, abridged:

```
NAME      AGE   READY   STATUS
podinfo   ...   True    Release reconciliation succeeded

NAME                       READY   STATUS    RESTARTS   AGE
podinfo-...                1/1     Running   0          ...
```

## Step 9: Reach the demo app (optional)

The chart created a Service. Look it up and forward a port:

```bash
kubectl -n demo get svc
kubectl -n demo port-forward svc/<service-name> 9898:9898
```

In a second shell:

```bash
curl -s http://localhost:9898 | head -n 5
```

You should see the demo app's response. This confirms the whole path worked: Git commit → Flux Kustomization → HelmRelease → pod.

## What you learned

- Applications live under `kubernetes/apps/<namespace>/<app>/` with an `app/` component.
- A namespace `kustomization.yaml` is the registration point; a new namespace directory is discovered automatically.
- `ks.yaml` connects a repository path to the cluster through Flux, and `targetNamespace` decides where resources land.
- Secrets, variables, and SOPS decryption are inherited; a simple app does not repeat them.

## Clean up

Remove the demo from Git:

```bash
rm -rf kubernetes/apps/demo
git add -A kubernetes/apps/demo
git commit -m "chore(demo): remove podinfo tutorial app"
git push
make flux-reconcile
```

Flux prunes the HelmRelease and the resources it created. Because the Namespace carries `kustomize.toolkit.fluxcd.io/prune: disabled`, delete it explicitly when it is no longer needed:

```bash
kubectl delete namespace demo
```

## Related documents

- [How to Add an Application](how-to-add-an-application.md)
- [Application Anatomy Reference](reference-app-anatomy.md)
- [Application Conventions Reference](reference-conventions.md)
- [How Applications Deploy: The Flux Deployment Model](explanation-flux-deployment-model.md)
