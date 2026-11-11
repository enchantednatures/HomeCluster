# Tandoor

Recipe manager, deployed from the bjw-s `app-template` chart with a
CloudNative-PG database and Authentik OIDC single sign-on.

## Components

| Path | Purpose |
|------|---------|
| `app/` | HelmRelease, PVCs, app + SSO secrets, Istio routing |
| `db/` | CNPG cluster, owner/superuser secrets, scheduled backups |

- Public URL: `https://recipes.${SECRET_DOMAIN}` (Istio `external-gateway`)
- Database: `tandoor-db-pooler-rw.default.svc.cluster.local:5432/tandoor`
- SSO: Authentik OIDC, issuer `https://auth.${SECRET_DOMAIN}/application/o/tandoor/`
- Redirect URI: `https://recipes.${SECRET_DOMAIN}/accounts/oidc/authentik/login/callback/`

The callback must be `https://`. cloudflared reaches the Istio gateway over plain
HTTP, so Envoy stamps `X-Forwarded-Proto: http`; the `tandoor` VirtualService
overrides it to `https` (same pattern as `authentik`/`influxdb`). Without that
header Django builds `http://` callback URLs and Authentik rejects them with
`400 invalid_request` because the blueprint registers a strict https URI.

## Authentik provisioning (blueprint)

The provider and application are declared in
`kubernetes/core/authentik/authentik/app/blueprint-tandoor.sops.yaml` and loaded
via `blueprints.secrets` in the Authentik HelmRelease.

- Provider: `authentik_providers_oauth2.oauth2provider` named `tandoor`, confidential client
- Application: `tandoor`, launch URL `https://recipes.${SECRET_DOMAIN}`
- Scopes: `openid`, `email`, `profile`, `offline_access`

## Secrets

| Secret | Keys |
|--------|------|
| `tandoor-secret` | `SECRET_KEY` |
| `tandoor-sso` | `SOCIALACCOUNT_PROVIDERS` (allauth OIDC app config, JSON) |
| `tandoor-db-user` | `username`, `password` |
| `tandoor-postgres-superuser` | `username`, `password` |

`client_id` (`tandoor`) and the generated `client_secret` appear in **two**
places and must match:

- `kubernetes/core/authentik/authentik/app/blueprint-tandoor.sops.yaml` (`client_secret`)
- `kubernetes/apps/default/tandoor/app/sso.sops.yaml` (`secret` inside `SOCIALACCOUNT_PROVIDERS`)

Rotating the client secret means updating both files and re-encrypting with
`make sops-encrypt`.

## Sign-in policy

Tandoor is configured SSO-only:

| Variable | Value | Effect |
|----------|-------|--------|
| `ENABLE_SIGNUP` | `1` | Required: the social adapter refuses first-time OIDC sign-in while `0` |
| `SOCIALACCOUNT_ONLY` | `1` | Hides the local login form in the SPA |
| `SOCIALACCOUNT_EMAIL_AUTHENTICATION` | `1` | Link an OIDC login to an existing account by email |
| `SOCIALACCOUNT_EMAIL_AUTHENTICATION_AUTO_CONNECT` | `1` | ...without an email confirmation round-trip |

Consequences:

- **Authentik is the only access control.** The blueprint has no group/policy
  binding, so every Authentik user can provision a Tandoor account on first
  login. Add a binding to the `tandoor` application to restrict this.
- `ENABLE_SIGNUP=1` is required for that provisioning, and in 2.7.2
  `SOCIALACCOUNT_ONLY` only hides the SPA login form — the server-rendered
  local signup page at `/accounts/signup/` stays reachable. Block it at the
  gateway if that matters.
- New users get their own empty space; add them to a shared space from
  **Settings → Spaces** in Tandoor.
- Local password login still works for break-glass at
  `https://recipes.${SECRET_DOMAIN}/accounts/login/` (the SPA hides the form,
  the server-rendered allauth page still renders it). Keep a local superuser
  password available.

## API

The v2 API is authenticated with an OAuth2 bearer token created under
**Settings → API** (`/api/access-token/`). The legacy `ApiToken` is gone.

- `POST /api/recipe-from-source/` with `{"url": "..."}` scrapes a recipe and
  returns it without saving; `POST /api/recipe/` persists it. Rate limited to
  60 requests/hour (`DRF_THROTTLE_RECIPE_URL_IMPORT`).
- `POST /api/import/` imports an uploaded archive (Mealie, Nextcloud, Paprika,
  default format, ...) asynchronously.
