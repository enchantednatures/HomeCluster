terraform {

  required_version = ">= 0.13.0"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2024.10.2"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.5.2"
    }
    minio = {
      source = "aminueza/minio"
      version = "3.2.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.35.1"
    }
    bitwarden = {
      source = "maxlaverse/bitwarden"
      version = "0.12.1"
    }
  }
}

provider "authentik" {
  url   = var.url
  token = var.token

}

provider minio {
  // required
  minio_server   = var.minio_url
  # minio_user     = authentik_user.loki_service.name
  # minio_password = authentik_token.loki_token.key

  minio_user = var.aws_access_key
  minio_password = var.aws_secret_key

  minio_region      = var.minio_region
}

provider "kubernetes" {
  config_path    = "~/.kube/config"
  config_context = "admin@talos"
}
