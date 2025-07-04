terraform {

  required_version = ">= 0.13.0"

  backend "s3" {
    bucket     = "tofu"
    key        = "authentik"
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
      version = "2025.6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.5.3"
    }
    minio = {
      source  = "aminueza/minio"
      version = "3.5.4"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.37.1"
    }
    bitwarden = {
      source  = "maxlaverse/bitwarden"
      version = "0.14.0"
    }
  }
}

provider "authentik" {
  url   = var.authentik_url
  token = var.authentik_token
}

# provider minio {
#   // required
#   minio_server   = var.minio_url
#   # minio_user     = authentik_user.loki_service.name
#   # minio_password = authentik_token.loki_token.key

#   minio_user = var.aws_access_key
#   minio_password = var.aws_secret_key

#   minio_region      = var.minio_region
# }

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "admin@talos"
}
