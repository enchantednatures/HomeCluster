# tofu/bootstrap/sealed-secrets/variables.tf
variable "cert" {
  description = "Certificate for encryption/decryption"
  type = object({
    cert = string
    key = string
  })
}
