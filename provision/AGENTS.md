# AGENTS.md - Infrastructure Provisioning

## Overview

OpenTofu/Terraform configurations for infrastructure outside Kubernetes. Currently: Authentik OAuth and Harbor provider setup.

## Structure

```
provision/
├── terraform/
│   ├── authentik/    # OAuth provider, Grafana/Harbor/Kellnr/MinIO integrations
│   └── harbor/       # Harbor registry provider config
└── certs/            # Certificate files
```

## Where to Look

| Task | Location |
|------|----------|
| Add Authentik app | `terraform/authentik/<app>.tf` |
| Harbor provider | `terraform/harbor/` |

## Conventions

- Terraform uses OpenTofu (`tofu` binary)
- App-specific OAuth in separate `.tf` files
- Run `make terraform-proxmox-plan` before apply

## Anti-Patterns

- Never commit `.tfstate` or provider credentials
- Do not mix VM provisioning with app OAuth (separate concerns)
