# Create the authentication flow
resource "authentik_flow" "passkey_flow" {
  name        = "passkey-authentication"
  title       = "Sign in with Passkey"
  slug        = "passkey-authentication"
  designation = "authentication"
}

# Create the WebAuthn authentication stage
resource "authentik_stage_authenticator_webauthn" "passkey_stage" {
  name                      = "passkey-authentication"
  configure_flow           = null  # No configuration flow since we're doing passkey-only
  friendly_name            = "Passkey Authentication"
  user_verification       = "preferred"
  resident_key_requirement = "required"  # This enables passwordless/usernameless authentication
}

# Bind the WebAuthn stage to the flow
resource "authentik_flow_stage_binding" "passkey_binding" {
  target = authentik_flow.passkey_flow.uuid
  stage  = authentik_stage_authenticator_webauthn.passkey_stage.id
  order  = 0
}

# Create a policy to set this as the default authentication flow
resource "authentik_policy_expression" "default_auth_flow" {
  name       = "default-auth-flow-policy"
  expression = "return True"
}

# Bind the policy to the flow
resource "authentik_policy_binding" "default_auth" {
  target = authentik_flow.passkey_flow.uuid
  policy = authentik_policy_expression.default_auth_flow.id
  order  = 0
}
