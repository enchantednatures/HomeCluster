resource "authentik_group" "open_webui_users" {
  name         = "Open WebUI Users"
  is_superuser = false
}

resource "authentik_group" "argocd_users" {
  name         = "Argo CD Users"
  is_superuser = false
}

resource "authentik_group" "enchanted_natures" {
  name         = "Enchanted Natures"
  is_superuser = false
}

resource "authentik_group" "snail" {
  name         = "snail"
  is_superuser = false
}

resource "authentik_group" "thanos" {
  name         = "thanos"
  is_superuser = false
}


data "authentik_flow" "default-provider-invalidation-flow" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_flow" "default-authentication-flow" {
  slug = "default-authentication-flow"

}
data "authentik_flow" "default-authorization-flow" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_property_mapping_provider_scope" "scopes" {
  managed_list = [
    "goauthentik.io/providers/oauth2/scope-email",
    "goauthentik.io/providers/oauth2/scope-profile",
    "goauthentik.io/providers/oauth2/scope-offline_access",
    "goauthentik.io/providers/oauth2/scope-openid"
  ]
}
