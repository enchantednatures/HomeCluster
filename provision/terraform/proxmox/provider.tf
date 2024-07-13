# Proxmox Provider
# ---
# Initial Provider Configuration for Proxmox

terraform {

  required_version = ">= 0.13.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.61.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.5.1"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.2.2"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.16.1"
    }
  }
}




provider "proxmox" {
  endpoint  = "https://${var.proxmox_host}:8006/api2/json"
  api_token = var.proxmox_api_token
  # (Optional) Skip TLS Verification
  insecure = true

  ssh {
    agent       = false
    username = "root"
    private_key = file("~/.ssh/id_rsa")
  }
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = "enchantednatures.github"
}




