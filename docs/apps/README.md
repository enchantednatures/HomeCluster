# Application Onboarding

Documentation for adding and operating applications in the HomeCluster `apps` layer (`kubernetes/apps/`), organized by the [Diátaxis](https://diataxis.fr/) framework: tutorials, how-to guides, reference, and explanation.

| Type | Document | Purpose |
|------|----------|---------|
| Tutorial | [Deploy Your First Application](tutorial-deploy-first-app.md) | Learn the end-to-end workflow by deploying a throwaway demo app |
| How-to | [How to Add an Application](how-to-add-an-application.md) | The standard checklist for onboarding a real app or service |
| How-to | [How to Add a PostgreSQL Database](how-to-add-a-database.md) | Attach a CloudNative-PG database component to an app |
| How-to | [How to Add Backups](how-to-add-backups.md) | Protect application data with VolSync replication |
| How-to | [How to Expose an Application](how-to-expose-an-app.md) | Publish an app at `<name>.${SECRET_DOMAIN}` through Istio |
| Reference | [Application Anatomy](reference-app-anatomy.md) | Directory layout and the role of every file and resource |
| Reference | [Application Conventions](reference-conventions.md) | House style for `ks.yaml`, HelmReleases, YAML, SOPS, and Istio |
| Reference | [Cluster Variables](reference-cluster-variables.md) | `cluster-settings` / `cluster-secrets` keys and substitution behavior |
| Explanation | [Flux Deployment Model](explanation-flux-deployment-model.md) | Why the layers, discovery, and dependency chains work the way they do |

## Where to start

- New to the repository: start with the [tutorial](tutorial-deploy-first-app.md).
- Adding a real service: use [How to Add an Application](how-to-add-an-application.md).
- Looking up a specific field or default: see the reference documents.

## Related documentation

- [Flux GitOps Workflow](../flux-gitops.md) — general Flux architecture, secrets, and troubleshooting
- [Kubernetes Applications](../kubernetes-applications.md) — inventory of deployed applications
- [Networking](../networking.md) — Istio, external-dns, and Cloudflare exposure
- [Authentik + Istio Forward Auth](../authentik-istio-forward-auth.md) — protecting exposed apps with SSO
