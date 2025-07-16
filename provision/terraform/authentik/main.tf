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

# Forward Auth Provider for Istio
resource "authentik_provider_proxy" "istio_forward_auth" {
  name               = "Istio Forward Auth"
  external_host      = "https://auth.${var.cluster_domain}"
  mode               = "forward_single"
  authorization_flow = data.authentik_flow.default-authorization-flow.id
  invalidation_flow  = data.authentik_flow.default-provider-invalidation-flow.id

  # Skip path regex for health checks and well-known paths
  skip_path_regex = "^/(healthz|metrics|\\.well-known/.*|outpost\\.goauthentik\\.io/.*)$"
}

# Application for Forward Auth
resource "authentik_application" "istio_forward_auth" {
  name              = "Istio Forward Auth"
  slug              = "istio-forward-auth"
  protocol_provider = authentik_provider_proxy.istio_forward_auth.id
  meta_description  = "Forward authentication for Istio services"
  meta_publisher    = "HomeCluster"
}

# Outpost for Forward Auth
resource "authentik_outpost" "istio_forward_auth" {
  name               = "istio-forward-auth"
  type               = "proxy"
  protocol_providers = [authentik_provider_proxy.istio_forward_auth.id]

  config = jsonencode({
    authentik_host                 = "https://auth.${var.cluster_domain}"
    authentik_host_insecure        = false
    authentik_host_browser         = "https://auth.${var.cluster_domain}"
    log_level                      = "info"
    object_naming_template         = "ak-outpost-%(name)s"
    docker_network                 = null
    docker_map_ports               = true
    docker_labels                  = null
    container_image                = null
    kubernetes_replicas            = 1
    kubernetes_namespace           = "authentik"
    kubernetes_ingress_annotations = {}
    kubernetes_ingress_secret_name = ""
    kubernetes_service_type        = "ClusterIP"
    kubernetes_disabled_components = []
    kubernetes_image_pull_secrets  = []
  })
}
