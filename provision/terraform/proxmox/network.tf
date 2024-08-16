resource "proxmox_virtual_environment_network_linux_bridge" "vmbr8" {
  node_name = "pve"
  name      = "vmbr8"
  autostart = "true"
}

data "proxmox_virtual_environment_dns" "pve_dns" {
  node_name = "pve"
}

resource "proxmox_virtual_environment_dns" "pve_dns" {
  domain    = data.proxmox_virtual_environment_dns.pve_dns.domain
  node_name = data.proxmox_virtual_environment_dns.pve_dns.node_name

  servers = [
    "100.100.100.100",
    "1.1.1.1",
    "8.8.8.8",
  ]
}

