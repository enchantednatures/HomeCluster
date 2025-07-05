terraform {
  backend "s3" {
    bucket     = "tofu"
    key        = "state"
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
    talos = {
      source  = "siderolabs/talos"
      version = "0.8"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.78"
    }
    restapi = {
      source  = "Mastercard/restapi"
      version = "2.0"
    }
    flux = {
      source  = "fluxcd/flux"
      version = ">=1.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">=2.35"
    }
    github = {
      source  = "integrations/github"
      version = ">= 6.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }

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
