variable "proxmox_host" {
  type = string
}
variable "proxmox_api_token" {
  type = string
}

variable "template_tag" {
  description = "Template tag"
  type        = string
}

variable "vm_tags" {
  description = "VM tags"
  type        = list(string)
}

variable "target_node" {
  description = "Proxmox node"
  type        = string
}

variable "tailscale_api_key" {
  description = "Tailscale API key"
  type        = string
}

variable "onboot" {
  description = "Auto start VM when node is start"
  type        = bool
  default     = true
}


variable "control_plane_nodes" {
  type = list(object({
    name         = string
    ram          = number
    cores        = number
    count        = number
    disk_size    = string
    storage_pool = string
  }))
  default = [
    {
      name         = "control-plane"
      ram          = 8192
      cores        = 4
      count        = 1
      disk_size    = 200
      storage_pool = "nvme0"
  }]
}

variable "node_types" {
  type = list(object({
    name                = string
    ram                 = number
    cores               = number
    count               = number
    disk_size           = string
    storage_pool_prefix = string
  }))
  default = [
    {
      name                = "lg"
      ram                 = 8192
      cores               = 4
      count               = 3
      disk_size           = 200
      storage_pool_prefix = "nvme"
    }
    # {
    #   name         = "md"
    #   ram          = 8192
    #   cores        = 4
    #   count        = 3
    #   disk_size    = "32G"
    #   storage_pool = "data"
    # },
    # {
    #   name      = "storage"
    #   ram       = 8192
    #   cores     = 4
    #   count     = 3
    #   disk_size = "64G"
    #   storage_pool = "local-zfs"
    # },
  ]
}
