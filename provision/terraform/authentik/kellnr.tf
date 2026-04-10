resource "authentik_provider_oauth2" "kellnr" {
  name               = "Kellnr"
  client_id          = var.kellnr_client.client_id
  client_secret      = var.kellnr_client.client_secret
  authorization_flow = data.authentik_flow.default-authorization-flow.id
  invalidation_flow  = data.authentik_flow.default-provider-invalidation-flow.id

  allowed_redirect_uris = var.kellnr_client.redirect_urls

  property_mappings = data.authentik_property_mapping_provider_scope.scopes.ids
}

resource "authentik_application" "kellnr" {
  name              = "Kellnr"
  group             = "Kellnr"
  slug              = "kellnr"
  meta_icon         = var.kellnr_client.icon
  meta_launch_url   = var.kellnr_client.launch_url
  protocol_provider = authentik_provider_oauth2.kellnr.id
}

resource "authentik_group" "kellnr_admins" {
  name = "Kellnr Admins"
}

resource "authentik_group" "kellnr_users" {
  name = "Kellnr Users"
}
