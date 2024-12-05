
data "authentik_group" "minio_admins" {
  name = "Minio admins"
}

resource "authentik_user" "loki_service" {
  username = "loki-service"
  name     = "Loki Service"
  type = "service_account"
  groups = [data.authentik_group.minio_admins.id]
}

resource "authentik_token" "loki_token" {
  identifier  = "loki-minio-app-password"
  user        = authentik_user.loki_service.id
  description = "My secret token"
  expiring = false
  intent = "app_password"
  retrieve_key = true
}




resource "minio_iam_service_account" "loki_account" {
  target_user = "minio"
  description = "Loki"
}

resource "minio_s3_bucket" "loki_chunks_bucket" {
  bucket = "loki-chunks"
  acl    = "public"
}

resource "minio_s3_bucket" "loki_ruler_bucket" {
  bucket = "loki-ruler"
  acl    = "public"
}

resource "minio_s3_bucket" "loki_admin_bucket" {
  bucket = "loki-admin"
  acl    = "public"
}

# resource "kubernetes_secret" "example" {
#   metadata {
#     name = "loki-bucket"
#     namespace = "monitoring"
#   }

#   data = {
#     ACCESS_KEY = minio_iam_service_account.loki_account.access_key
#     ACCESS_SECRET = minio_iam_service_account.loki_account.secret_key
#   }

#   type = "stringData"
# }

resource "authentik_user" "harbor_service" {
  username = "harbor-service"
  name     = "Harbor Service"
  type = "service_account"
  groups = [data.authentik_group.minio_admins.id]
}

resource "minio_s3_bucket" "harbor_registry_bucket" {
  bucket = "harbor-registry"
  acl    = "public"
}
