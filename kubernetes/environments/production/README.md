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

This is the default environment. To ensure it's active:

1. Verify environment setting:
   ```bash
   kubectl get configmap cluster-environment -n flux-system -o yaml
   ```
2. Should show `environment: "production"`
3. Apply Flux configuration if needed:
   ```bash
   kubectl apply -f kubernetes/flux/config/cluster-multitenant.yaml
   ```

## Environment Variables

The following substitutions are available:
- `${CLUSTER_ENVIRONMENT}`: Set to "production"  
- All cluster settings from ConfigMaps/Secrets
- User-specific settings for applications

## Service Access

- **External Access**: Through Cloudflare tunnels
- **Internal Access**: Through Istio VirtualServices
- **Monitoring**: Grafana dashboard for observability