# AGENTS.md - Infrastructure Layer

## Overview

Infrastructure components deployed first (no dependencies). Cilium CNI, Istio ambient mode, cert-manager, monitoring stack, storage, networking, policy.

## Structure

```
kubernetes/infra/
├── cert-manager/         # TLS certificates
├── istio-ingress/        # Gateway config
├── istio-system/         # Istio ambient (base, cni, istiod, ztunnel, kiali)
├── kafka/                # Strimzi + schema-registry
├── keda/                 # Event-driven autoscaling
├── knative*/             # Serverless (operator, serving, eventing)
├── kube-system/          # Cilium, coredns, metrics-server, spegel, reloader
├── kyverno-system/       # Policy engine + policies
├── monitoring/           # kube-prometheus-stack, grafana, loki, tempo, influxdb
├── networking/           # cloudflared, external-dns, tailscale, k8s-gateway
├── nodes/                # Node configuration
└── openebs-system/       # Local PV storage
```

## Where to Look

| Task | Location |
|------|----------|
| Add certificate issuer | `cert-manager/cert-manager/` |
| Configure Istio ambient | `istio-system/` subdirs |
| Add monitoring target | `monitoring/kube-prometheus-stack/app/` |
| Add network service | `networking/services/` |
| Configure Kyverno policy | `kyverno-system/kyverno/policies/` |
| Storage classes | `openebs-system/`, `operators/rook-ceph/` |

## Conventions

- Istio ambient: FQDNs only, explicit ports, `${SECRET_DOMAIN}` for external hosts
- Monitoring: Prometheus rules in `kube-prometheus-stack`, dashboards in `grafana`
- Certificates: `ClusterIssuer` or `Certificate` resources
- Networking: `cloudflared` for tunnels, `external-dns` for Cloudflare, `tailscale-operator` for mesh

## Anti-Patterns

- Do not mix ingress controllers — use Istio gateway exclusively
- Do not hardcode IPs — use `cluster-settings.yaml` variables
- Do not disable `coredns` or `cilium` — cluster-critical
