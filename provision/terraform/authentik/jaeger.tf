data "authentik_flow" "default-authorization-flow" {
  slug = "default-provider-authorization-implicit-consent"
}

# resource "authentik_outpost" "outpost" {
#   name = "authentik Embedded Outpost"
#   protocol_providers = [
#     authentik_provider_proxy.jaeger_provider.id
#   ]
# }

resource "authentik_provider_proxy" "jaeger_provider" {
  name               = "Jaeger"
  external_host      = "https://auth.enchantednatures.com"
  authorization_flow = data.authentik_flow.default-authorization-flow.id
  mode               = "forward_single"
}

# Create an Application for the Outpost
resource "authentik_application" "jaeger_app" {
  name              = "Jaeger"
  slug              = "jaeger"
  protocol_provider = authentik_provider_proxy.jaeger_provider.id
}
