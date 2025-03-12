resource "authentik_provider_oauth2" "minio" {
  name               = "Minio"
  client_id          = var.minio_client.client_id
  client_secret      = var.minio_client.client_secret
  authorization_flow = data.authentik_flow.default-authorization-flow.id
  invalidation_flow  = data.authentik_flow.default-provider-invalidation-flow.id

  allowed_redirect_uris = var.minio_client.redirect_urls

  property_mappings = data.authentik_property_mapping_provider_scope.scopes.ids
}

resource "authentik_application" "minio" {
  name              = "Minio"
  group             = "Minio"
  slug              = "minio"
  meta_icon         = var.minio_client.icon
  meta_launch_url   = var.minio_client.launch_url
  protocol_provider = authentik_provider_oauth2.minio.id
}

resource "authentik_group" "minio_admins" {
  name = "Minio Admins"
}

resource "authentik_group" "minio_users" {
  name = "Minio Users"
}
