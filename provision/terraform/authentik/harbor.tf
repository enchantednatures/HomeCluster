data "authentik_certificate_key_pair" "generated" {
  name = "authentik Self-signed Certificate"
}

resource "authentik_provider_oauth2" "harbor" {
  name                = "Harbor"
  client_id           = var.harbor_client.client_id
  client_secret       = var.harbor_client.client_secret
  signing_key         = data.authentik_certificate_key_pair.generated.id
  authentication_flow = data.authentik_flow.default-authentication-flow.id
  authorization_flow  = data.authentik_flow.default-authorization-flow.id
  invalidation_flow   = data.authentik_flow.default-provider-invalidation-flow.id

  allowed_redirect_uris = var.harbor_client.redirect_urls

  property_mappings = data.authentik_property_mapping_provider_scope.scopes.ids
}

resource "authentik_application" "harbor" {
  name              = "Harbor"
  group             = "Harbor"
  slug              = "harbor"
  meta_icon         = var.harbor_client.icon
  meta_launch_url   = var.harbor_client.launch_url
  protocol_provider = authentik_provider_oauth2.harbor.id
}

resource "authentik_group" "harbor_admins" {
  name = "Harbor Admins"
}

resource "authentik_group" "harbor_users" {
  name = "Harbor Users"
}

resource "authentik_group" "tekton_group" {
  name = "tekton"
}

resource "authentik_user" "tekton-builder" {
  username = "tekton-builder"
  name     = "tekton-builder"
  groups   = [authentik_group.harbor_users.id, authentik_group.tekton_group.id]
}
