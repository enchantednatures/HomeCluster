# Cluster Variables Reference

This page documents the values available to Flux post-build variable substitution in this repository: which files define them, which keys exist, and how they reach application manifests.

## Variable sources

| File | Resource | Namespace | Content |
|------|----------|-----------|---------|
| `kubernetes/flux/vars/cluster-settings.yaml` | ConfigMap `cluster-settings` | `flux-system` | Non-secret defaults |
| `kubernetes/flux/vars/cluster-secrets.sops.yaml` | Secret `cluster-secrets` | `flux-system` | Encrypted values |
| `kubernetes/flux/vars/cluster-settings-user.yaml` | ConfigMap `cluster-settings-user` | `flux-system` | Personal overrides |
| `kubernetes/flux/vars/cluster-secrets-user.sops.yaml` | Secret `cluster-secrets-user` | `flux-system` | Encrypted personal overrides |

All four are registered in `kubernetes/flux/vars/kustomization.yaml`.

## cluster-settings keys

| Key | Current value | Purpose |
|-----|---------------|---------|
| `TIMEZONE` | `Etc/UTC` | Default timezone for workloads that reference it |
| `COREDNS_ADDR` | `10.96.0.10` | Cluster DNS service address |
| `KUBE_VIP_ADDR` | `192.168.1.201` | Control-plane virtual IP |
| `CLUSTER_CIDR` | `10.42.0.0/16` | Pod network CIDR |
| `SERVICE_CIDR` | `10.43.0.0/16` | Service network CIDR |
| `NODE_CIDR` | `192.168.1.0/24` | Node network CIDR |

## cluster-secrets keys

Values in this file are SOPS-encrypted; only the key names are meaningful in the clear.

| Key | Purpose |
|-----|---------|
| `SECRET_ACME_EMAIL` | ACME account email |
| `SECRET_CLOUDFLARE_TUNNEL_ID` | Cloudflare Tunnel identifier |
| `SECRET_DOMAIN` | Public application domain used in VirtualService hosts and URLs |
| `PRIVATE_DOMAIN` | Private/internal domain |

Note that `SECRET_DOMAIN` lives in `cluster-secrets`, not `cluster-settings`, despite being referenced by ordinary application manifests such as VirtualServices.

## User override files

`cluster-settings-user.yaml` and `cluster-secrets-user.sops.yaml` carry the same kind of keys and are intended for personal overrides that should not modify the base files. They currently contain placeholder keys (`SETTINGS_PLACEHOLDER` and `SECRET_PLACEHOLDER`).

## Substitution sources and precedence

The layer Kustomizations list the sources in this order (from `kubernetes/flux/apps.yaml`):

1. `cluster-settings` (ConfigMap)
2. `cluster-secrets` (Secret)
3. `cluster-settings-user` (ConfigMap)
4. `cluster-secrets-user` (Secret)

When the same key appears in multiple sources, **later sources overwrite earlier ones**, so a value in a `-user` file wins over the base file. Values supplied inline with `postBuild.substitute` take precedence over everything loaded through `substituteFrom`.

## How the values reach application manifests

Each layer Kustomization sets its own `decryption` and `postBuild.substituteFrom`, and carries a `patches` entry that copies both settings into every Flux Kustomization it renders. The patch targets objects matching:

```
substitution.flux.home.arpa/disabled notin (true)
```

As a result, application `ks.yaml` files do not declare `decryption` or `postBuild`; the values are injected by the parent layer. The mechanism is described in [How Applications Deploy: The Flux Deployment Model](explanation-flux-deployment-model.md).

Two ways to opt out:

- Add the label `substitution.flux.home.arpa/disabled: "true"` to a Flux Kustomization to keep the layer patch from applying.
- Add `kustomize.toolkit.fluxcd.io/substitute: disabled` as a label or annotation on an individual resource to skip substitution for that resource.

## Substitution syntax and behavior

- `${VAR}` — standard substitution.
- `${VAR:=default}` — uses `default` when `VAR` is undefined.
- Undefined variables without a default are substituted with an **empty string**.
- `$${VAR}` — escapes the expression and emits a literal `${VAR}`.
- Variable names may contain only alphanumeric characters and underscores.
- By default, substitution only runs when at least one variable is available. A Kustomization with no variables at all will not evaluate `${VAR:=default}` expressions unless `postBuild.substituteStrategy: Always` is set.

## Usage examples

A VirtualService host, from `kubernetes/apps/atuin/atuin/app/virtualservice.yaml`:

```yaml
spec:
  hosts:
    - atuin.${SECRET_DOMAIN}
```

An application configuration URL, from the Gatus ConfigMap in `kubernetes/apps/gatus/gatus/app/helmrelease.yaml`:

```yaml
url: https://immich.${SECRET_DOMAIN}
```

## Changing a variable

- **Non-secret values**: edit `cluster-settings.yaml` or `cluster-settings-user.yaml` and commit. Flux substitutes the new value the next time the affected Kustomizations reconcile.
- **Secret values**: edit the `.sops.yaml` file and run `make sops-encrypt` before committing. Never commit plaintext.
- To apply immediately, force reconciliation with `make flux-reconcile`; otherwise the change lands on the next interval.
- Because substitution rewrites rendered manifests, a variable change affects every resource that references it.

## Related documents

- [How to Expose an Application](how-to-expose-an-app.md)
- [How to Add an Application](how-to-add-an-application.md)
- [Flux GitOps Workflow](../flux-gitops.md)
- [How Applications Deploy: The Flux Deployment Model](explanation-flux-deployment-model.md)
