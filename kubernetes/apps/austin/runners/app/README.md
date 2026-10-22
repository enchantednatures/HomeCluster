# Austin runners

This directory is reconciled by the fixed Flux Kustomization `austin-runners`
(`kubernetes/apps/austin/runners/ks.yaml`) into the `austin-ci` namespace with
`serviceAccountName: austin-flux`. It ships one object: the encrypted
`github-auth-secret`, which is a byte-for-byte copy of
`kubernetes/apps/actions-runner-system/runners/app/github-auth-secret.sops.yaml`
with only `metadata.namespace` changed. A `HelmRelease` in `austin-ci` cannot
reference a Secret in `actions-runner-system`, so the copy is required.

Do not edit, decrypt, or re-encrypt the Secret. `make sops-encrypt` is the only
write path, and the owner rotates the GitHub App credentials.

## Adding a runner scale set

1. Copy the example below into a new file here, for example
   `my-repo-runner.yaml`, replacing `REPLACE_SCALE_SET_NAME` and
   `https://github.com/OWNER/REPO`.
2. Add the file to `kustomization.yaml` under `resources`.
3. Open a PR. After it merges, reconcile:

   ```sh
   flux reconcile kustomization austin-runners -n flux-system --with-source
   kubectl -n austin-ci get helmrelease,pods
   ```

The chart is pulled from the owner-managed `OCIRepository/gha-runner-scale-set`
in `flux-system`, pinned to chart `0.15.0`. The ARC controller itself stays in
`actions-runner-system`; `controllerServiceAccount` is what lets the chart's
RoleBindings in `austin-ci` grant that controller access here.

## Example `HelmRelease`

```yaml
# yaml-language-server: $schema=https://kubernetesjsonschema.dev/master-standalone-strict/_definitions.json
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &name REPLACE_SCALE_SET_NAME
  namespace: austin-ci
spec:
  # Required by the austin-ci-helmrelease-guard Kyverno policy.
  serviceAccountName: austin-helm
  driftDetection:
    mode: enabled
  chartRef:
    kind: OCIRepository
    name: gha-runner-scale-set
    namespace: flux-system
  interval: 15m
  maxHistory: 2
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
    nameOverride: *name
    runnerScaleSetName: *name
    # Replace with the repository that should receive this scale set.
    githubConfigUrl: https://github.com/OWNER/REPO
    githubConfigSecret: github-auth-secret
    minRunners: 0
    maxRunners: 4
    listenerTemplate:
      spec:
        containers:
          - name: listener
            resources:
              requests:
                cpu: 100m
                memory: 128Mi
              limits:
                memory: 256Mi
    containerMode:
      type: kubernetes
      kubernetesModeWorkVolumeClaim:
        accessModes:
          - ReadWriteOnce
        storageClassName: ceph-block-ssd
        resources:
          requests:
            storage: 30Gi
    controllerServiceAccount:
      name: actions-runner-controller
      namespace: actions-runner-system
    template:
      spec:
        # The actions-runner image runs as uid 1001; the work PVC must be
        # group-writable or the runner cannot create /home/runner/_work/_tool.
        securityContext:
          fsGroup: 1001
          fsGroupChangePolicy: OnRootMismatch
        containers:
          - name: runner
            image: ghcr.io/actions/actions-runner:2.338.0
            command:
              - /home/runner/run.sh
            volumeMounts:
              - name: certs
                mountPath: /certs
            resources:
              requests:
                cpu: 1000m
                memory: 2Gi
              limits:
                cpu: 4000m
                memory: 6Gi
            env:
              - name: ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER
                value: "false"
              - name: DOCKER_TLS_CERTDIR
                value: /certs
              - name: DOCKER_HOST
                value: tcp://localhost:2376
              - name: DOCKER_TLS_VERIFY
                value: "1"
              - name: DOCKER_CERT_PATH
                value: /certs/client
              - name: DOCKER_CLI_EXPERIMENTAL
                value: enabled
          - name: dind
            image: docker:28.5.2-dind
            securityContext:
              privileged: true
            resources:
              requests:
                cpu: 100m
                memory: 512Mi
              limits:
                cpu: 1000m
                memory: 2Gi
            env:
              - name: DOCKER_TLS_CERTDIR
                value: /certs
              - name: DOCKER_DRIVER
                value: overlay2
            volumeMounts:
              - name: work
                mountPath: /__w
              - name: certs
                mountPath: /certs
              - name: docker-graph-storage
                mountPath: /var/lib/docker
        volumes:
          - name: certs
            emptyDir: {}
          - name: docker-graph-storage
            emptyDir: {}
```

## Constraints

- Every `HelmRelease` in `austin-ci` must set `serviceAccountName: austin-helm`;
  the `austin-ci-helmrelease-guard` Kyverno policy denies anything else.
- `austin-ci` is `pod-security.kubernetes.io/enforce: privileged` because the ARC
  runner uses privileged `docker:dind`. A chart installed here can therefore
  create node-level-trust pods. Only install charts you actually need.
- The chart version is pinned by the `flux-system` `OCIRepository`; do not add a
  second chart source unless the owner asks for one.
- Keep the runner image pinned to a release tag. `latest` and untagged images
  are not allowed in this repository.
