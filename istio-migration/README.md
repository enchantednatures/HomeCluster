# Istio Migration Plan

This PR transitions the home cluster from using NGINX as the primary ingress controller to Istio Gateway API.

## Implementation Steps

1. Apply the wildcard certificate for Istio ingress
2. Update the Gateway configuration to handle all cluster ingress traffic
3. Update cloudflared configuration to point to Istio instead of NGINX
4. Create VirtualServices for external services (minio-ui, proxmox)
5. Update external-dns configuration to work with Istio Gateway API
6. Test the migration with a few services first
7. Gradually migrate all services to VirtualServices
8. Decommission NGINX ingress after successful migration

## Components Updated

- Istio Gateway
- Cloudflared tunnel configuration
- External-DNS configuration
- Certificate management
- Service ingress definitions

## Testing Plan

1. Verify certificate issuance for Istio gateway
2. Confirm Cloudflare DNS records are properly created
3. Test external services (minio-ui, proxmox) through Istio gateway
4. Monitor logs for connectivity issues
5. Validate authentication continues to work properly
