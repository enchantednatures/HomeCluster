terraform {

  required_version = ">= 0.13.0"

  required_providers {
    authentik = {
      source  = "goauthentik/authentik"
      version = "2024.8.4"
    }
  }
}

provider "authentik" {
  url   = var.url
  token = var.token

}
