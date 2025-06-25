# Production Environment

This overlay configures the full HomeCluster production environment.

## What's Included

- **Complete System Services**: All CNI, DNS, metrics, and system components
- **Istio Service Mesh**: Full mesh with ingress gateway
- **Complete Monitoring Stack**: Prometheus, Grafana, Loki, Tempo, Promtail
- **External Services**: Cloudflare tunnels, external-DNS
- **Application Workloads**: Immich, Harbor, Flink, Atuin, and more
- **Production Storage**: OpenEBS, external MinIO connections
- **Production Optimizations**: Goldilocks, Spegel, resource management

## External Dependencies

- **MinIO**: External object storage at 192.168.1.241:9768
- **Cloudflare**: Tunnel and DNS management
- **Proxmox**: VM infrastructure
- **Unraid**: Storage backend

## Usage

To use the production environment:

1. Apply the production Flux configuration:
   ```bash
   kubectl apply -f kubernetes/flux/config/cluster-production.yaml
   ```

2. Verify deployment:
   ```bash
   kubectl get kustomizations -n flux-system
   ```

## Environment Variables

The following substitutions are available:
- All cluster settings from ConfigMaps/Secrets
- User-specific settings for applications

## Service Access

- **External Access**: Through Cloudflare tunnels
- **Internal Access**: Through Istio VirtualServices
- **Monitoring**: Grafana dashboard for observability