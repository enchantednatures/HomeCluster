# SparkyFitness

Self-hosted fitness and nutrition tracker, deployed from the upstream
`sparkyfitness` Helm chart with a CloudNative-PG database and Authentik SSO.

## Components

| Path | Purpose |
|------|---------|
| `app/` | HelmRelease, PVCs, app/OIDC secrets, Istio routing |
| `db/` | CNPG cluster, owner/superuser secrets, WAL + scheduled backups |
| `backup/` | VolSync restic backup/restore for the uploads PVC |

- Public URL: `https://sparkyfitness.${SECRET_DOMAIN}` (Istio `external-gateway`)
- Database: `sparkyfitness-db-rw.sparkyfitness.svc.cluster.local:5432/sparkyfitness`
- SSO: Authentik OIDC, issuer `https://auth.${SECRET_DOMAIN}/application/o/sparkyfitness/`
- Redirect URI: `https://sparkyfitness.${SECRET_DOMAIN}/api/auth/sso/callback/authentik`

## Secrets

All secrets are SOPS-encrypted. The chart's `lookup`-based secret generation is
disabled so keys are stable across reconciles.

| Secret | Keys |
|--------|------|
| `sparkyfitness-app` | `api_encryption_key`, `better_auth_secret` |
| `sparkyfitness-appdb` | `username` (`sparky`), `password` |
| `sparkyfitness-oidc` | `client_id`, `client_secret` |
| `sparkyfitness-db-owner` | `username` (`sparky_admin`), `password` |
| `sparkyfitness-db-superuser` | `username` (`postgres`), `password` |
| `sparkyfitness-backup-secret` | RustFS credentials + `RESTIC_PASSWORD` + `RESTIC_REPOSITORY` |

## Authentik provisioning (REST API)

The OIDC provider and application are created through Authentik's REST API,
not a blueprint. The API token is not stored in Git: use an admin token at
run time (`AUTHENTIK_TOKEN`), as shown below.

```bash
DOMAIN="${SECRET_DOMAIN}"   # e.g. example.com
AUTH="https://auth.${DOMAIN}"
TOKEN="$AUTHENTIK_TOKEN"

# IDs are stable in this cluster; fetch them if they ever change.
AUTHZ=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "$AUTH/api/v3/flows/instances/?slug=default-provider-authorization-implicit-consent" \
  | jq -r '.results[0].pk')
INVAL=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "$AUTH/api/v3/flows/instances/?slug=default-provider-invalidation-flow" \
  | jq -r '.results[0].pk')
CERT=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "$AUTH/api/v3/crypto/certificatekeypairs/?name=authentik%20Self-signed%20Certificate" \
  | jq -r '.results[0].pk')
SCOPES=$(curl -sS -H "Authorization: Bearer $TOKEN" \
  "$AUTH/api/v3/propertymappings/provider/scope/?page_size=100" \
  | jq -c '[.results[]
      | select((.managed // "") | test("oauth2/scope-(openid|email|profile|offline_access)"))
      | .pk]')

PROVIDER=$(curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$AUTH/api/v3/providers/oauth2/" -d @- <<EOF
{
  "name": "SparkyFitness",
  "authorization_flow": "$AUTHZ",
  "invalidation_flow": "$INVAL",
  "client_type": "confidential",
  "client_id": "sparkyfitness",
  "client_secret": "<from sparkyfitness-oidc>",
  "signing_key": "$CERT",
  "redirect_uris": [
    {"matching_mode": "strict",
     "url": "https://sparkyfitness.${DOMAIN}/api/auth/sso/callback/authentik"}
  ],
  "property_mappings": $SCOPES,
  "sub_mode": "user_username",
  "issuer_mode": "per_provider",
  "include_claims_in_id_token": true,
  "grant_types": ["authorization_code", "refresh_token"]
}
EOF
)
PK=$(printf '%s' "$PROVIDER" | jq -r '.pk')

curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  "$AUTH/api/v3/core/applications/" -d @- <<EOF
{
  "name": "SparkyFitness",
  "slug": "sparkyfitness",
  "provider": "$PK",
  "meta_launch_url": "https://sparkyfitness.${DOMAIN}",
  "group": "Applications",
  "policy_engine_mode": "any"
}
EOF
```

The scope `property_mappings` are required: the API does not pre-select them,
and omitting them yields a token with no scopes and a generic
`invalid_provider` error in SparkyFitness.

## Notes

- The app strips a trailing slash from the env issuer only when building the
  discovery URL; if discovery succeeds, Authentik's slash-terminated issuer is
  stored and SSO works. The upstream fix for the startup-discovery edge case is
  in SparkyFitness PR #3353; bump the chart once a release containing it ships.
- The database owner `sparky_admin` has `CREATEROLE` because SparkyFitness
  creates its limited-privilege `sparky` runtime role on first boot.
- `config.frontendUrl` is set explicitly because routing is handled by Istio
  rather than the chart's ingress/httpRoute.
- The VirtualService routes `/api`, `/uploads`, `/health-data`, `/mcp` and the
  OIDC discovery paths directly to the server. The chart's frontend nginx
  proxies to its upstream over HTTP/1.0, which SparkyFitness rejects with
  `426 Upgrade Required`; bypassing nginx for API traffic avoids that.
