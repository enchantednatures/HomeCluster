# tofu/bootstrap/volumes/proxmox-volumes/providers.tf
terraform {
  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = ">= 1.19.1"
    }
  }
}
