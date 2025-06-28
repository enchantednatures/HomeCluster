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

  # backend "pg" { }

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
  }
}

provider "proxmox" {
  endpoint = var.proxmox.endpoint
  insecure = var.proxmox.insecure

  api_token = var.proxmox.api_token
  ssh {
    username    = var.proxmox.username
    agent       = false
    private_key = file("~/.ssh/id_rsa")
  }
}

provider "restapi" {
  uri                  = var.proxmox.endpoint
  insecure             = var.proxmox.insecure
  write_returns_object = true

  headers = {
    "Content-Type"  = "application/json"
    "Authorization" = "PVEAPIToken=${var.proxmox.api_token}"
  }
}

# Kubernetes provider - will connect after kubeconfig is created
provider "kubernetes" {
  config_path = try(local_file.kube_config.filename, null)
}

provider "github" {
  owner = var.github_owner
}

provider "flux" {
  kubernetes = {
    config_path = try(local_file.kube_config.filename, null)
  }
  git = {
    url = "ssh://git@github.com/${var.github_owner}/${var.github_repository}.git"
    ssh = {
      username = "git"
      # private_key = tls_private_key.flux.private_key_pem
      private_key = file("~/.ssh/id_rsa")
    }
  }
}
