# Local Development Environment

This overlay configures a minimal Kubernetes environment suitable for local development and testing.

## What's Included

- **Core System Services**: Cilium CNI, CoreDNS, metrics-server, reloader
- **Istio Service Mesh**: Base, CNI, and Istiod for KNative testing
- **Lightweight Monitoring**: Prometheus, Grafana with reduced storage requirements
- **Istio Gateway**: Configured with NodePort for local access

## What's Excluded

- **External Services**: Cloudflare tunnels, external-dns
- **Production Apps**: Immich, Harbor, Flink, Atuin
- **Production Storage**: OpenEBS, external MinIO connections
- **Production Optimizations**: Goldilocks, Spegel
- **Heavy Monitoring**: Loki, Tempo, Promtail

## Usage

To deploy this environment:

1. Ensure you have a local Kubernetes cluster (minikube, kind, etc.)
2. Set the environment variable in Flux:
   ```bash
   kubectl patch configmap cluster-environment -n flux-system \
     --patch '{"data":{"environment":"local"}}'
   ```
3. Apply the Flux configuration:
   ```bash
   kubectl apply -f kubernetes/flux/config/cluster-multitenant.yaml
   ```

## Local Access

- **Grafana**: NodePort service on cluster IP
- **Prometheus**: NodePort service on cluster IP  
- **Istio Gateway**: NodePort for ingress testing

Use `kubectl get svc -A` to find the NodePort assignments.

## Environment Variables

The following substitutions are available:
- `${CLUSTER_ENVIRONMENT}`: Set to "local"
- All standard cluster settings from ConfigMaps/Secrets