terraform {

  required_version = ">= 0.13.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.61.0"
    }

    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.16.1"
    }
  }
}



provider "proxmox" {
  alias    = "euclid"
  endpoint = var.euclid.endpoint
  insecure = var.euclid.insecure
  api_token = var.euclid_auth.api_token

  tmp_dir = "/var/tmp"
  ssh {
    agent       = true
    username = "root"
    private_key = file("~/.ssh/id_rsa")
  }
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = "enchantednatures.github"
}



