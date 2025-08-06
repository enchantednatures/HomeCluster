# Networking Documentation

## Overview
The HomeCluster networking stack consists of **Cilium** for the CNI and **Istio** for the service mesh. DNS is managed by **external‑dns** with Cloudflare, and external access is provided via **Cloudflare Tunnels**.

### Components
- **Cilium** – Provides L2/L3 networking, network policies, and eBPF‑based security.
- **Istio** – Handles service‑to‑service communication, traffic routing, and security policies.
- **External‑DNS** – Syncs Kubernetes `Ingress`/`Service` resources to Cloudflare DNS records.
- **Cloudflare Tunnel** – Exposes services to the internet without exposing the cluster directly.

### Key Configuration Files
- `kubernetes/infra/cilium/` – HelmRelease and configuration for Cilium.
- `kubernetes/infra/istio-system/` – Istio components (istiod, ztunnel, etc.).
- `kubernetes/infra/istio-system/istiod/app/authorization-policy.yaml` – Example Istio policies.
- `kubernetes/infra/istio-system/istiod/app/peer-auth.yaml` – Mutual TLS configuration.
- `kubernetes/infra/istio-system/istiod/app/authorization-policy.yaml` – Authorization policies.
- `kubernetes/infra/istio-system/istiod/app/peer-auth.yaml` – Peer authentication.
- `kubernetes/infra/istio-system/istiod/app/authorization-policy.yaml` – Authorization policies.
- `kubernetes/infra/istio-system/istiod/app/peer-auth.yaml` – Peer authentication.

## Service Mesh Patterns
- **ServiceEntry** – Required for cross‑namespace communication.
- **VirtualService** – Defines routing rules for external traffic.
- **Gateway** – Entry point for external traffic via Cloudflare Tunnel.

## DNS Configuration
- **External‑DNS** is configured in `kubernetes/infra/istio-system/` and `kubernetes/infra/istio-system/` to create DNS records for services.
- Use `external-dns` annotations on `Ingress`/`Service` resources to automatically create DNS entries in Cloudflare.

## Troubleshooting
- Verify Cilium pods are running: `kubectl -n kube-system get pods -l k8s-app=cilium`.
- Verify Istio components: `kubectl -n istio-system get pods`.
- Check `external-dns` logs for DNS sync issues.
- Verify Cloudflare Tunnel status with `cloudflared tunnel list`.
