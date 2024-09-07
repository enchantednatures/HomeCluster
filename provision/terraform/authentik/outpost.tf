# Create an Authentik Outpost
resource "authentik_outpost" "nginx_outpost" {

  protocol_providers = [authentik_provider_proxy.nginx_provider.id]
  name = "nginx-outpost"
  type = "proxy"

  config = jsonencode({
    "authentik_host"          = "https://auth.enchantednatures.com"
    "docker_network"          = null
    "docker_map_ports"        = true
    "container_image"         = null
    "kubernetes_disabled"     = false
    "kubernetes_replicas"     = 1
    "kubernetes_namespace"    = "default"
    "kubernetes_ingress_annotations" = {}
    "kubernetes_service_type" = "ClusterIP"
    "kubernetes_image_pull_secrets" = []
    "kubernetes_disabled_components" = []
  })

  service_connection = authentik_service_connection_kubernetes.cluster_connection.id
}

# Create a Kubernetes Service Connection
resource "authentik_service_connection_kubernetes" "cluster_connection" {
  name  = "my-kubernetes-cluster"
  local = true
}

# Create a Provider for the Outpost
resource "authentik_provider_proxy" "nginx_provider" {
  name               = "nginx-provider"
  external_host      = "https://enchantednatures.com"
  authorization_flow = authentik_flow.provider_authorization_flow.uuid
  mode               = "forward_single"
}

# Create an Application for the Outpost
resource "authentik_application" "nginx_app" {
  name              = "Nginx Application"
  slug              = "nginx-app"
  protocol_provider = authentik_provider_proxy.nginx_provider.id
}

# Create an Authorization Flow (simplified for this example)
resource "authentik_flow" "provider_authorization_flow" {
  name        = "nginx-authorization-flow"
  title       = "Nginx Authorization"
  slug        = "nginx-authorization"
  designation = "authorization"
}
