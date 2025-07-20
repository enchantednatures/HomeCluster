# Configure the Authentik provider
terraform {
  required_version = ">= 0.13.0"
  backend "s3" {
    bucket     = "tofu"
    key        = "harbor-state"
    region     = "us-east-1"
    access_key = var.aws_access_key
    secret_key = var.aws_secret_key
    endpoints = {
      s3 = "http://tower:9768"
    }
    skip_credentials_validation = true # Skip AWS related checks and validations
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    use_path_style              = true
  }

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "~> 2025.6.0"
    }

    harbor = {
      source  = "goharbor/harbor"
      version = "3.10.21"
    }
  }
}

# Authentik provider configuration
provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}

# Minio provider configuration
provider "harbor" {
  url      = var.harbor_url
  username = var.harbor_username
  password = var.harbor_password
}

# Variables definition
variable "authentik_url" {
  type        = string
  description = "Authentik server URL"
}

variable "authentik_token" {
  type        = string
  sensitive   = true
  description = "Authentik API token"
}


variable "harbor_url" {
  type        = string
  description = "Harbor Url"
}

variable "harbor_username" {
  type        = string
  description = "Harbor Username"
}

variable "harbor_password" {
  type        = string
  sensitive   = true
  description = "Harbor Password"
}

variable "oicd_client_id" {
  type        = string
  description = "OIDC Client ID for Harbor"
}

variable "oicd_client_secret" {
  type        = string
  sensitive   = true
  description = "OIDC Client Secret for Harbor"
}

variable "aws_access_key" { type = string }
variable "aws_secret_key" { type = string }


data "authentik_provider_oauth2_config" "harbor" {
  name = "Harbor"
}


resource "harbor_config_auth" "oidc" {
  auth_mode          = "oidc_auth"
  primary_auth_mode  = true
  oidc_name          = "auth"
  oidc_endpoint      = data.authentik_provider_oauth2_config.harbor.issuer_url
  oidc_client_id     = var.oicd_client_id
  oidc_client_secret = var.oicd_client_secret
  oidc_scope         = "openid,profile,email,offline_access"
  oidc_verify_cert   = true
  oidc_auto_onboard  = true
  oidc_user_claim    = "preferred_username"
  oidc_admin_group   = "harbor_admin"
}
