# Proxmox Provider
# ---
# Initial Provider Configuration for Proxmox

terraform {

  required_version = ">= 0.13.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "=0.38.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.1"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.13.13"
    }
  }
}




provider "proxmox" {
  endpoint  = "https://${var.proxmox_host}:8006/api2/json"
  api_token = var.proxmox_api_token
  # (Optional) Skip TLS Verification
  insecure = true

  ssh {
    agent    = true
    username = "root"
  }
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = "enchantednatures.github"
}




