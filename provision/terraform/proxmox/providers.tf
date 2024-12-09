terraform {
  required_version = "13"


  backend "s3" {
    bucket = "tofu"
    key    = "state"
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

  # backend "pg" { }

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.6"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.68"
    }
    restapi = {
      source  = "Mastercard/restapi"
      version = "1.20"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox.endpoint
  insecure = var.proxmox.insecure

  api_token = var.proxmox.api_token
  ssh {
    agent    = true
    username = var.proxmox.username
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
