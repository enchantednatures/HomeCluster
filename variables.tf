
# tofu/variables.tf
variable "proxmox" {
  type = object({
    name         = string
    cluster_name = string
    endpoint     = string
    insecure     = bool
    username     = string
    api_token    = string
  })
  sensitive = true
}

variable "aws_access_key" { type = string }
variable "aws_secret_key" { type = string }

# Flux GitOps variables
variable "github_owner" {
  description = "GitHub repository owner"
  type        = string
}

variable "github_repository" {
  description = "GitHub repository name"
  type        = string
}

variable "age_private_key" {
  description = "Age private key for SOPS decryption"
  type        = string
  sensitive   = true
}
