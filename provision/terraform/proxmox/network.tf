resource "proxmox_virtual_environment_network_linux_bridge" "vmbr8" {
  node_name = "pve"
  name      = "vmbr8"
  autostart = "true"
}
