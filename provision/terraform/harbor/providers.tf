# Configure the Authentik provider
terraform {
  required_version = ">= 0.13.0"
  backend "s3" {
    bucket = "tofu"
    key    = "harbor-state"
    region = "us-east-1"
    access_key = var.aws_access_key
    secret_key = var.aws_secret_key
    endpoints = {
      s3 = "http://tower:9768"
    }
    skip_credentials_validation = true  # Skip AWS related checks and validations
    skip_requesting_account_id = true
    skip_metadata_api_check = true
    skip_region_validation = true
    use_path_style = true
  }

  required_providers {
    authentik = {
      source = "goauthentik/authentik"
      version = "~> 2024.10.2"
    }

    harbor = {
      source = "goharbor/harbor"
      version = "3.10.16"
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
  type = string
  description = "Authentik server URL"
}

variable "authentik_token" {
  type = string
  sensitive = true
  description = "Authentik API token"
}


variable "harbor_url" {
  type = string
  description = "Harbor Url"
}

variable "harbor_username" {
  type = string
  description = "Harbor Username"
}

variable "harbor_password" {
  type = string
  sensitive = true
  description = "Harbor Password"
}

variable "aws_access_key" { type = string }
variable "aws_secret_key" { type = string }
