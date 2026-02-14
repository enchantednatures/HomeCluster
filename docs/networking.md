# Networking Documentation

## Overview
The HomeCluster networking stack consists of **Cilium** for the CNI and **Istio** (ambient mode) for the service mesh. DNS is managed by **external-dns** with Cloudflare, and external access is provided via **Cloudflare Tunnels**. Private network access is available through **Tailscale**.

## Components

### Cilium CNI
- **Location**: `kubernetes/infra/kube-system/cilium/`
- Provides L2/L3 networking, network policies, and eBPF-based security
- L2 announcements for LoadBalancer services
- Hubble for network observability
- Gateway API support

### Istio Service Mesh (Ambient Mode)
- **Location**: `kubernetes/infra/istio-system/`
- Handles service-to-service communication, traffic routing, and security policies
- Ambient mode uses ztunnel for Layer 4 traffic -- no sidecar proxies needed
- Components:
  - `base/` -- Istio CRDs and base configuration
  - `istiod/` -- Control plane (config distribution, certificate management)
  - `cni/` -- CNI plugin for pod network setup
  - `ztunnel/` -- Ambient mesh data plane
  - `kiali/` -- Service mesh observability UI
  - `ambient-config/` -- Ambient mesh configuration

### External-DNS
- **Location**: `kubernetes/infra/networking/external-dns/`
- Syncs Kubernetes resources to Cloudflare DNS records
- Use annotations on services to automatically create DNS entries

### Cloudflare Tunnels
- **Location**: `kubernetes/infra/networking/cloudflared/`
- Exposes services to the internet without exposing the cluster directly
- No inbound firewall rules required

### Tailscale
- **Location**: `kubernetes/infra/networking/tailscale-operator/` and `tailscale-connector/`
- Private network connectivity to cluster services
- Operator manages Tailscale proxies for services

### k8s-gateway
- **Location**: `kubernetes/infra/networking/k8s-gateway/`
- Provides DNS resolution for cluster services from the home network
- Enables split DNS for internal service discovery

## Key Configuration Files

- `kubernetes/infra/kube-system/cilium/` -- Cilium HelmRelease and configuration
- `kubernetes/infra/istio-system/istiod/app/peer-auth.yaml` -- Mutual TLS configuration
- `kubernetes/infra/istio-system/istiod/app/authorization-policy.yaml` -- Authorization policies
- `kubernetes/infra/istio-ingress/gateway/` -- External gateway configuration
- `kubernetes/infra/networking/services/` -- Network service definitions

## Service Mesh Patterns

### VirtualService
Defines routing rules for traffic entering through gateways:
```yaml
spec:
  hosts:
    - myapp.${SECRET_DOMAIN}
  gateways:
    - istio-ingress/external-gateway
  http:
    - route:
        - destination:
            host: myapp.mynamespace.svc.cluster.local  # Full FQDN required
            port:
              number: 8080  # Explicit port required
```

### Gateway
Entry point for external traffic, typically via Cloudflare Tunnel:
- External gateway in `kubernetes/infra/istio-ingress/gateway/`

### ServiceEntry
Required for cross-namespace communication and external service access.

### AuthorizationPolicy
Controls access between services within the mesh.

## DNS Configuration

### External DNS
- Configured in `kubernetes/infra/networking/external-dns/`
- Creates DNS records in Cloudflare for services with appropriate annotations
- Supports both A records and CNAME records

### Split DNS
- **k8s-gateway** resolves cluster service DNS from the home network
- Configure your home DNS server (e.g., Pi-hole) to forward your domain queries to the k8s-gateway address
- Internal services resolve via CoreDNS within the cluster

## Troubleshooting

```sh
# Verify Cilium pods are running
kubectl -n kube-system get pods -l k8s-app=cilium

# Check Cilium status
cilium status

# Verify Istio components
kubectl -n istio-system get pods

# Check Istio proxy status
istioctl proxy-status

# Analyze Istio configuration
istioctl analyze

# Check external-dns logs for DNS sync issues
kubectl -n networking logs -l app.kubernetes.io/name=external-dns

# Verify Cloudflare Tunnel status
kubectl -n networking get pods -l app.kubernetes.io/name=cloudflared
```
