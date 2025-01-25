variable "authentik_token" { type = string }
variable "authentik_url" { type = string }
variable "aws_access_key" { type = string }
variable "aws_secret_key" { type = string }
variable "tekton_builder_password" { type = string }

variable "grafana_client" {
  type = object({
    client_id     = string
    client_secret = string
    icon          = string
    launch_url    = string
    redirect_urls = list(object({
      matching_mode = string,
      url           = string
    }))
  })
}


variable "harbor_client" {
  type = object({
    client_id     = string
    client_secret = string
    icon          = string
    launch_url    = string
    redirect_urls = list(object({
      matching_mode = string,
      url           = string
    }))
  })
}

variable "minio_client" {
  type = object({
    client_id     = string
    client_secret = string
    icon          = string
    launch_url    = string
    redirect_urls = list(object({
      matching_mode = string,
      url           = string
    }))
  })
}
