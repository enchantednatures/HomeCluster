# flux.tf - Flux GitOps Bootstrap Configuration

# Create flux-system namespace
resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
  }

  depends_on = [module.talos]
}

# Create SOPS Age secret for decryption
resource "kubernetes_secret" "sops_age" {
  metadata {
    name      = "sops-age"
    namespace = "flux-system"
  }

  data = {
    "age.agekey" = var.age_private_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.flux_system]
}

# Bootstrap Flux
# resource "flux_bootstrap_git" "this" {
#   embedded_manifests = true
#   path               = "kubernetes/flux"
#   depends_on = [
#     kubernetes_namespace.flux_system,
#     kubernetes_secret.sops_age
#   ]
# }

# Use existing repository (comment out if you want Terraform to create it)
data "github_repository" "this" {
  name = var.github_repository
}

resource "tls_private_key" "flux" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "github_repository_deploy_key" "this" {
  title      = "Flux"
  repository = data.github_repository.this.name
  key        = tls_private_key.flux.public_key_openssh
  read_only  = false
}

resource "kubernetes_secret" "ssh_keypair" {
  metadata {
    name      = "flux-system"
    namespace = "flux-system"
  }

  type = "Opaque"

  data = {
    "identity.pub" = tls_private_key.flux.public_key_openssh
    "identity"     = tls_private_key.flux.private_key_pem
    "known_hosts"  = "github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg="
  }

  depends_on = [kubernetes_namespace.flux_system]
}
