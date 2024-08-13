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
