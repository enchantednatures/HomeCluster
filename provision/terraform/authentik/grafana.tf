

resource "authentik_provider_oauth2" "grafana" {
  name               = "Grafana"
  client_id          = var.grafana_client.client_id
  client_secret      = var.grafana_client.client_secret
  authorization_flow = data.authentik_flow.default-authorization-flow.id
  invalidation_flow  = data.authentik_flow.default-provider-invalidation-flow.id

  allowed_redirect_uris = var.grafana_client.redirect_urls

  property_mappings = data.authentik_property_mapping_provider_scope.scopes.ids
}

resource "authentik_application" "grafana" {
  name              = "Grafana"
  group             = "Grafana"
  slug              = "grafana"
  meta_icon         = var.grafana_client.icon
  meta_launch_url   = var.grafana_client.launch_url
  protocol_provider = authentik_provider_oauth2.grafana.id
}

resource "authentik_group" "grafana_admins" {
  name = "Grafana Admins"
}

resource "authentik_group" "grafana_editors" {
  name = "Grafana Editors"
}

resource "authentik_group" "grafana_viewers" {
  name = "Grafana Viewers"
}
