# How to Expose an Application Externally

This guide publishes an application at `<app>.${SECRET_DOMAIN}` through the shared Istio external gateway. DNS records and TLS are handled by external-dns and Cloudflare — you only add a VirtualService.

## Prerequisites

- The application is deployed per [How to Add an Application](how-to-add-an-application.md).
- The application's Service exists; you know its name and port.
- The namespace is part of the mesh (`istio-injection: enabled`, as used by `gatus`, `atuin`, and `immich`).
- `${SECRET_DOMAIN}` is defined (see the [Cluster Variables Reference](reference-cluster-variables.md)).
- The `istio-ingress/external-gateway` gateway exists; it is deployed by the infrastructure layer.

## Step 1: Find the Service and port

```bash
kubectl -n <namespace> get svc
```

Note the service name and the port your app listens on. For example, Atuin's service listens on `8080`, and `kubernetes/apps/atuin/atuin/app/virtualservice.yaml` routes to that port.

## Step 2: Create the VirtualService

Create `kubernetes/apps/<namespace>/<app>/app/virtualservice.yaml`, modeled on `kubernetes/apps/atuin/atuin/app/virtualservice.yaml`:

```yaml
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/networking.istio.io/virtualservice_v1.json
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: <app>
  namespace: <namespace>
spec:
  hosts:
    - <app>.${SECRET_DOMAIN}
  gateways:
    - istio-ingress/external-gateway
  http:
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: <service>.<namespace>.svc.cluster.local
            port:
              number: <port>
```

Rules that matter:

- The destination host is the **fully qualified** service name (`<service>.<namespace>.svc.cluster.local`) with an **explicit** port number.
- The `hosts` entry is the public hostname, built from `${SECRET_DOMAIN}`. Never hardcode a domain.
- The gateway is referenced as `<gateway-namespace>/<gateway-name>`; the VirtualService itself lives in the application namespace.
- A skeleton is also available at [`docs/templates/virtualservice-template.yaml`](../templates/virtualservice-template.yaml).

## Step 3: Register the file

Add the VirtualService to the component index — `kubernetes/apps/<namespace>/<app>/app/kustomization.yaml`:

```yaml
resources:
  - ./helmrelease.yaml
  - ./virtualservice.yaml
```

Without this entry, Flux will not apply the VirtualService even though the file exists in Git.

## Step 4: Validate and commit

```bash
make kubernetes-kubeconform
pre-commit run --all-files
git add kubernetes/apps/<namespace>/<app>/app
git commit -m "feat(<namespace>): expose <app>"
git push
```

## Step 5: Reconcile and verify

```bash
make flux-reconcile
kubectl -n <namespace> get virtualservice
curl -sI https://<app>.${SECRET_DOMAIN}
```

Expected: the VirtualService exists, and once DNS and the edge are in place the request returns the application's response (typically `HTTP/2 200`).

If the gateway returns a 404 or 503:

```bash
# Confirm the service has ready endpoints
kubectl -n <namespace> get endpoints <service>
```

A VirtualService pointing at a service with no endpoints produces a gateway error even though the manifest is valid.

## Notes

- **DNS and TLS**: external-dns watches the `hosts` entries and creates Cloudflare records; Cloudflare Tunnel provides ingress. See [Networking](../networking.md). You do not create Certificate resources for app hostnames.
- **Authentication**: to protect an exposed app with SSO, see [Authentik + Istio Forward Auth](../authentik-istio-forward-auth.md).
- **Internal-only apps** do not need a VirtualService. Use `kubectl port-forward` for ad-hoc access, or reach the service directly from inside the cluster.
- Multiple hosts or path-based routes are possible, but keep one host per application unless you have a specific reason to share one.

## Related documents

- [How to Add an Application](how-to-add-an-application.md)
- [Cluster Variables Reference](reference-cluster-variables.md)
- [Networking](../networking.md)
- [Authentik + Istio Forward Auth](../authentik-istio-forward-auth.md)
