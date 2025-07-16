# Authentik Forward Auth with Istio

This setup provides forward authentication for Istio services using Authentik as the identity provider.

## Architecture

1. **Authentik Provider**: Terraform-managed forward auth provider in Authentik
2. **Istio Extension Provider**: Configured in istiod to use Authentik outpost
3. **Authorization Policies**: Per-service policies to enable authentication

## Deployment Steps

### 1. Deploy Authentik Provider (Terraform)

```bash
cd provision/terraform/authentik
terraform plan
terraform apply
```

This creates:
- Forward auth provider in Authentik
- Outpost for Istio integration
- Application configuration

### 2. Update Istio Configuration

The Istio extension provider is configured in `kubernetes/apps/istio-system/istiod/app/helmrelease.yaml`.

Apply changes:
```bash
task flux:reconcile
```

### 3. Enable Authentication for Services

To protect a service, create an AuthorizationPolicy in the service namespace:

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: my-service-auth
  namespace: my-namespace
spec:
  selector:
    matchLabels:
      app: my-service
  action: CUSTOM
  provider:
    name: authentik
  rules:
    - to:
        - operation:
            hosts:
              - my-service.example.com
            notPaths:
              - /health
              - /metrics
```

## Configuration Details

### Authentik Provider Settings

- **Mode**: `forward_single` - Single domain forward auth
- **External Host**: Points to your Authentik instance
- **Skip Path Regex**: Excludes health checks and system paths

### Istio Extension Provider

- **Service**: `ak-outpost-istio-forward-auth.authentik.svc.cluster.local:9000`
- **Path Prefix**: `/outpost.goauthentik.io/auth/envoy`
- **Headers**: Forwards authentication headers to upstream services

### Headers Forwarded

**To Upstream Services:**
- `x-authentik-username`
- `x-authentik-groups` 
- `x-authentik-email`
- `x-authentik-name`
- `x-authentik-uid`

**From Auth Service:**
- `set-cookie`
- `location`
- `content-type`

## Example: Protecting Open WebUI

See `kubernetes/apps/default/open-webui/app/auth-policy.yaml` for a complete example.

## Troubleshooting

1. **Check Outpost Status**: Verify the Authentik outpost is running
2. **Istio Configuration**: Ensure extension provider is loaded in istiod
3. **Service Labels**: Verify AuthorizationPolicy selectors match service labels
4. **Logs**: Check Envoy proxy logs for auth failures

```bash
kubectl logs -n istio-ingress deployment/istio-gateway -f
kubectl logs -n authentik deployment/ak-outpost-istio-forward-auth -f
```