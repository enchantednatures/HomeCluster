# Flux Image Automation

This directory contains the configuration for automated container image updates using Flux.

## Overview

Flux Image Automation automatically:
1. Scans container registries for new image tags
2. Selects the latest tag based on defined policies (semver, alphabetical, etc.)
3. Updates image references in Kubernetes manifests
4. Commits changes to a git branch (`flux-image-updates`)
5. A GitHub Action creates a PR for review

## Components

### Image Automation Controllers
- **image-reflector-controller**: Scans container registries and reflects image metadata
- **image-automation-controller**: Updates git repositories with new image references

Installed via HelmRelease: `kubernetes/infra/flux-system/image-automation/app/helmrelease.yaml`

### ImageRepository Resources
Located in `image-repositories.yaml`, these define which container registries to scan:

- `open-webui` - ghcr.io/open-webui/open-webui
- `open-webui-pipelines` - ghcr.io/open-webui/pipelines
- `immich-server` - ghcr.io/immich-app/immich-server
- `immich-machine-learning` - ghcr.io/immich-app/immich-machine-learning

**Scan Interval**: 10 minutes

### ImagePolicy Resources
Located in `image-policies.yaml`, these define version selection strategies:

#### Following Latest Tags (with digest pinning)
- `open-webui-main` - Follows `main` tag with digest updates every 10m
- `open-webui-pipelines-main` - Follows `main` tag with digest updates every 10m

#### Semantic Versioning
- `immich-server` - Selects latest stable version (>=1.0.0)
- `immich-machine-learning` - Selects latest stable version (>=1.0.0)

### ImageUpdateAutomation
Located in `image-update-automation.yaml`, this configures how updates are written to git:

- **Update Interval**: 30 minutes
- **Source Branch**: main
- **Target Branch**: flux-image-updates
- **Update Path**: ./kubernetes

## Adding Image Automation to Your App

### Step 1: Create ImageRepository
Add to `image-repositories.yaml`:

```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImageRepository
metadata:
  name: myapp
  namespace: flux-system
spec:
  image: ghcr.io/myorg/myapp
  interval: 10m
  exclusionList:
    - "^.*\\.sig$"  # Exclude signature tags
```

### Step 2: Create ImagePolicy

Choose a policy strategy:

#### For Semantic Versioning
```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: myapp
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: myapp
  policy:
    semver:
      range: '>=1.0.0'
  digestReflectionPolicy: IfNotPresent
```

#### For Following Latest Tag
```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: myapp-main
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: myapp
  filterTags:
    pattern: '^main$'
  policy:
    alphabetical: {}
  digestReflectionPolicy: Always
```

#### For CalVer or Build Tags
```yaml
---
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: myapp
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: myapp
  filterTags:
    pattern: '^main-[a-fA-F0-9]+-(?P<ts>[1-9][0-9]*)$'
    extract: '$ts'
  policy:
    numerical:
      order: asc
```

### Step 3: Add Markers to Manifests

#### For Deployments
```yaml
spec:
  containers:
    - name: myapp
      image: ghcr.io/myorg/myapp:v1.0.0 # {"$imagepolicy": "flux-system:myapp"}
```

#### For HelmReleases (separate fields)
```yaml
spec:
  values:
    image:
      repository: ghcr.io/myorg/myapp # {"$imagepolicy": "flux-system:myapp:name"}
      tag: v1.0.0 # {"$imagepolicy": "flux-system:myapp:tag"}
```

#### For HelmReleases (with digest)
```yaml
spec:
  values:
    image:
      repository: ghcr.io/myorg/myapp # {"$imagepolicy": "flux-system:myapp:name"}
      tag: v1.0.0 # {"$imagepolicy": "flux-system:myapp:tag"}
      digest: sha256:abc123... # {"$imagepolicy": "flux-system:myapp:digest"}
```

## Workflow

1. **Every 10 minutes**: ImageRepository resources scan container registries
2. **Every 30 minutes**: ImageUpdateAutomation checks for new images matching policies
3. **On update detected**: 
   - Updates manifest files with new image references
   - Commits to `flux-image-updates` branch
   - Pushes to GitHub
4. **GitHub Action triggers**:
   - Creates PR from `flux-image-updates` to `main`
   - Adds labels: `automated`, `dependencies`, `flux`
5. **Manual review**:
   - Review changes in PR
   - Check upstream release notes
   - Merge when ready
6. **Flux reconciles**:
   - Deploys updated images to cluster

## Checking Status

```bash
# View all image automation resources
flux get images all -A

# Check image repositories
flux get image repository -A

# Check image policies
flux get image policy -A

# Check image update automation
flux get image update -A

# View logs
kubectl logs -n flux-system deploy/image-reflector-controller
kubectl logs -n flux-system deploy/image-automation-controller
```

## Suspending Automation

### Suspend all image updates
```bash
flux suspend image update flux-system
```

### Suspend specific image repository
```bash
flux suspend image repository myapp
```

### Resume automation
```bash
flux resume image update flux-system
flux resume image repository myapp
```

## Policy Examples

### Latest patch version in 1.x range
```yaml
policy:
  semver:
    range: '>=1.0.0 <2.0.0'
```

### Include pre-releases
```yaml
policy:
  semver:
    range: '>=1.0.0-0'
```

### Latest release candidate
```yaml
filterTags:
  pattern: '.*-rc.*'
policy:
  semver:
    range: '^1.x-0'
```

### Redis version pattern (e.g., 7.2.4-alpine3.19)
```yaml
filterTags:
  pattern: '^(?P<semver>[0-9]*\\.[0-9]*\\.[0-9]*)-(alpine[0-9]*\\.[0-9]*)'
  extract: '$semver'
policy:
  semver:
    range: '>=1.0.0'
```

### Minio RELEASE pattern
```yaml
filterTags:
  pattern: '^RELEASE\\.(?P<timestamp>.*)Z$'
  extract: '$timestamp'
policy:
  alphabetical:
    order: asc
```

## Private Registry Authentication

For private registries, create a Kubernetes secret and reference it:

```bash
kubectl create secret docker-registry myregistry \
  --docker-server=ghcr.io \
  --docker-username=myuser \
  --docker-password=mytoken \
  -n flux-system
```

Then reference it in ImageRepository:
```yaml
spec:
  secretRef:
    name: myregistry
```

## Troubleshooting

### Images not being updated
1. Check ImageRepository status: `flux get image repository myapp`
2. Verify policy matches tags: `kubectl describe imagepolicy -n flux-system myapp`
3. Check automation logs: `kubectl logs -n flux-system deploy/image-automation-controller`

### Updates committed but not applied
1. Check if branch was pushed: `git fetch && git branch -a | grep flux-image-updates`
2. Verify GitHub Action ran: Check Actions tab in GitHub
3. Check PR was created: Check Pull Requests in GitHub

### Policy not selecting expected version
1. List scanned tags: `kubectl describe imagerepository -n flux-system myapp`
2. Test regex patterns: Use regex101.com
3. Verify semver range: Check semantic versioning specification

## Security Considerations

- Image automation requires write access to your git repository
- Review PRs before merging to prevent malicious image updates
- Use digest pinning for production-critical workloads
- Consider using signed images and verifying signatures
- Regularly audit ImagePolicy configurations

## References

- [Flux Image Automation Guide](https://fluxcd.io/flux/guides/image-update/)
- [ImageRepository API](https://fluxcd.io/flux/components/image/imagerepositories/)
- [ImagePolicy API](https://fluxcd.io/flux/components/image/imagepolicies/)
- [ImageUpdateAutomation API](https://fluxcd.io/flux/components/image/imageupdateautomations/)
