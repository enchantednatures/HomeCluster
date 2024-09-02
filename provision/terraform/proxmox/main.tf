# tofu/main.tf
module "talos" {
  source = "./talos"

  providers = {
    proxmox = proxmox
  }

  image = {
    version = "v1.7.5"
    schematic = file("${path.module}/talos/image/schematic.yaml")
  }

  cilium = {
    install = file("${path.module}/talos/inline-manifests/cilium-install.yaml")
    values = file("${path.module}/templates/cilium/values.yaml")
  }

  cluster = {
    name            = "talos"
    endpoint        = "192.168.1.201"
    gateway         = "192.168.1.1"
    talos_version   = "v1.7"
    proxmox_cluster = "homelab"
  }

  nodes = {
    "ctrl-01" = {
      host_node     = "pve"
      machine_type  = "controlplane"
      ip            = "192.168.1.201"
      mac_address   = "BC:24:11:2E:C8:01"
      vm_id         = 800
      cpu           = 8
      ram_dedicated = 8192
    }
    # "ctrl-02" = {
    #   host_node     = "pve"
    #   machine_type  = "controlplane"
    #   ip            = "192.168.1.202"
    #   mac_address   = "BC:24:11:2E:C8:02"
    #   vm_id         = 801
    #   cpu           = 4
    #   ram_dedicated = 4096
    #   igpu          = true
    # }
    # "ctrl-03" = {
    #   host_node     = "pve"
    #   machine_type  = "controlplane"
    #   ip            = "192.168.1.203"
    #   mac_address   = "BC:24:11:2E:C8:03"
    #   vm_id         = 802
    #   cpu           = 4
    #   ram_dedicated = 4096
    # }
    "work-00" = {
      host_node     = "pve"
      machine_type  = "worker"
      ip            = "192.168.1.211"
      mac_address   = "BC:24:11:2E:08:00"
      vm_id         = 810
      cpu           = 16
      ram_dedicated = 32768
      igpu          = true
    }

    "work-01" = {
      host_node     = "pve"
      machine_type  = "worker"
      ip            = "192.168.1.212"
      mac_address   = "BC:24:11:2E:08:00"
      vm_id         = 811
      cpu           = 16
      ram_dedicated = 32768
      igpu          = true
    }

  }
}

