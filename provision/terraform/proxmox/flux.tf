resource "flux_bootstrap_git" "this" {
  embedded_manifests      = true
  disable_secret_creation = true
  delete_git_manifests    = false
  path                    = "kubernetes/flux"

  depends_on = [
    kubernetes_namespace.flux_system,
    kubernetes_secret.sops_age
  ]
}
