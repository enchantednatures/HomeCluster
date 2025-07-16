# Tekton OpenTofu Pipelines

This directory contains Tekton pipelines for automating OpenTofu operations triggered by GitHub webhooks.

## Overview

The setup includes:
- **OpenTofu Plan Pipeline**: Triggered on PR creation/updates, runs `tofu plan` and comments results on the PR
- **OpenTofu Apply Pipeline**: Triggered on push to main branch, runs `tofu apply`

## Components

### Tasks
- `opentofu-cli`: Runs OpenTofu commands (init, plan, apply)
- `github-pr-comment`: Posts plan output as GitHub PR comments

### Pipelines
- `opentofu-plan-pipeline`: Clone → Plan → Comment on PR
- `opentofu-apply-pipeline`: Clone → Apply

### Triggers
- GitHub PR events (opened/synchronize) → Plan pipeline
- GitHub push to main → Apply pipeline

## Setup Instructions

### 1. Configure Secrets

You need to encrypt and configure the following secrets:

```bash
# GitHub Personal Access Token (with repo scope)
kubectl create secret generic github-token \
  --from-literal=token='your-github-pat' \
  --namespace=tekton-pipelines --dry-run=client -o yaml | \
  sops --encrypt --in-place /dev/stdin > secrets/github-token.sops.yaml

# MinIO credentials for OpenTofu state backend
kubectl create secret generic minio-credentials \
  --from-literal=AWS_ACCESS_KEY_ID='your-minio-access-key' \
  --from-literal=AWS_SECRET_ACCESS_KEY='your-minio-secret-key' \
  --namespace=tekton-pipelines --dry-run=client -o yaml | \
  sops --encrypt --in-place /dev/stdin > secrets/minio-credentials.sops.yaml
```

### 2. Update Backend Configuration

Edit `config/opentofu-backend-config.yaml` to match your MinIO setup:
- Update bucket name
- Update state file path
- Verify MinIO service endpoint

### 3. Configure Repository-Specific Settings

In `triggers/opentofu-triggers.yaml`, update:
- `tofudir` parameter to point to your OpenTofu directory (default: "provision")
- Webhook filters if needed

### 4. GitHub Webhook Setup

1. Get the webhook URL:
   ```bash
   kubectl get virtualservice tekton-opentofu-webhook -n tekton-pipelines
   ```

2. In your GitHub repository:
   - Go to Settings → Webhooks → Add webhook
   - Payload URL: `https://tekton-webhook.hcasten.dev`
   - Content type: `application/json`
   - Events: Select "Pull requests" and "Pushes"

### 5. Deploy

The pipelines will be deployed automatically via Flux when you commit these changes.

## Usage

### For Pull Requests
1. Create a PR with OpenTofu changes
2. Pipeline automatically runs `tofu plan`
3. Plan output is posted as a PR comment

### For Main Branch
1. Merge PR to main branch
2. Pipeline automatically runs `tofu apply`
3. Infrastructure changes are applied

## Monitoring

View pipeline runs:
```bash
# List recent pipeline runs
kubectl get pipelineruns -n tekton-pipelines

# View logs for a specific run
kubectl logs -f pipelinerun/opentofu-plan-run-xxxxx -n tekton-pipelines

# View Tekton dashboard (if enabled)
kubectl port-forward svc/tekton-dashboard -n tekton-pipelines 9097:9097
```

## Troubleshooting

### Common Issues

1. **Authentication failures**: Verify git-credentials secret is properly configured
2. **MinIO connection issues**: Check minio-credentials secret and backend config
3. **GitHub API failures**: Verify github-token secret has proper permissions
4. **Webhook not triggering**: Check GitHub webhook delivery logs

### Debug Commands

```bash
# Check EventListener logs
kubectl logs -l eventlistener=opentofu-listener -n tekton-pipelines

# Check trigger interceptor logs
kubectl logs -l app.kubernetes.io/name=tekton-triggers-core-interceptors -n tekton-pipelines

# Verify secrets are properly mounted
kubectl describe pipelinerun <run-name> -n tekton-pipelines
```

## Security Considerations

- All secrets are encrypted with SOPS
- GitHub token has minimal required permissions
- MinIO credentials are scoped to specific bucket
- Pipelines run in isolated workspaces
- Network policies restrict inter-namespace communication
