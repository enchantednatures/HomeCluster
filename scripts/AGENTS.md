# AGENTS.md - Scripts and Utilities

## Overview

Utility scripts for validation, standardization, and cluster operations.

## Structure

```
scripts/
├── add-yaml-schemas.sh              # Auto-add schema annotations
├── standardize-helmreleases.sh      # Enforce HelmRelease standards
├── standardize-namespace-labels.sh  # Normalize namespace labels
├── validate-yaml-schemas.sh         # Validate YAML schema annotations
├── kubeconform.sh                   # Manifest schema validation
├── validate-ceph-setup.sh           # Ceph config validation
├── ceph-health-check.sh             # Ceph health monitoring
└── ...                              # Additional Ceph and utility scripts
```

## Where to Look

| Task | Script |
|------|--------|
| Validate manifests | `kubeconform.sh` |
| Add missing schemas | `add-yaml-schemas.sh` |
| Standardize HRs | `standardize-helmreleases.sh` |
| Check Ceph health | `ceph-health-check.sh` |

## Conventions

- All bash scripts: `set -o errexit -o pipefail`
- 4-space indent (per `.editorconfig`)
- Scripts invoked via `make scripts-<name>` targets

## Anti-Patterns

- Do not skip validation before committing changes
