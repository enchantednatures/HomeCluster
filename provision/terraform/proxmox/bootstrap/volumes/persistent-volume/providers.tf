# tofu/bootstrap/volumes/persistent-volume/providers.tf
terraform {
  required_providers {
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = ">= 2.31.0"
    }
  }
}
