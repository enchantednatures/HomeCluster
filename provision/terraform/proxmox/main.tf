# tofu/main.tf
module "talos" {
  source = "./talos"

  providers = {
    proxmox = proxmox
  }

  image = {
    version   = "v1.9.1"
    schematic = file("${path.module}/talos/image/schematic.yaml")
  }

  cilium = {
    install = file("${path.module}/talos/inline-manifests/cilium-install.yaml")
    values  = file("${path.module}/templates/cilium/values.yaml")
  }

  cluster = {
    name            = "talos"
    endpoint        = "192.168.1.201"
    gateway         = "192.168.1.1"
    talos_version   = "v1.9.1"
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
      ram_dedicated = 16984
      datastore_id  = "local-lvm"
      disk_size     = 32
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
      cpu           = 8
      ram_dedicated = 16384
      disk_size     = 64
      datastore_id  = "local-lvm"
      igpu          = true
    }

    "work-01" = {
      host_node     = "pve"
      machine_type  = "worker"
      ip            = "192.168.1.212"
      mac_address   = "BC:24:11:2E:08:01"
      vm_id         = 811
      cpu           = 16
      ram_dedicated = 16384
      disk_size     = 128
      datastore_id  = "local-lvm"
      igpu          = true
    }

    "work-02" = {
      host_node     = "pve"
      machine_type  = "worker"
      ip            = "192.168.1.213"
      mac_address   = "BC:24:11:2E:08:02"
      vm_id         = 812
      cpu           = 8
      ram_dedicated = 16384
      disk_size     = 128
      datastore_id  = "local-lvm"
      igpu          = true
    }

    "work-03" = {
      host_node     = "pve"
      machine_type  = "worker"
      ip            = "192.168.1.214"
      mac_address   = "BC:24:11:2E:08:03"
      vm_id         = 813
      cpu           = 8
      ram_dedicated = 16384
      disk_size     = 128
      datastore_id  = "local-lvm"
      igpu          = true
    }

    "work-04" = {
      host_node     = "pve"
      machine_type  = "worker"
      ip            = "192.168.1.215"
      mac_address   = "BC:24:11:2E:08:04"
      vm_id         = 814
      cpu           = 4
      ram_dedicated = 4096
      disk_size     = 64
      datastore_id  = "local-lvm"
      igpu          = true
    }

    "work-05" = {
      host_node     = "pve"
      machine_type  = "worker"
      ip            = "192.168.1.216"
      mac_address   = "BC:24:11:2E:08:05"
      vm_id         = 815
      cpu           = 4
      ram_dedicated = 4096
      disk_size     = 64
      datastore_id  = "local-lvm"
      igpu          = true
    }
  }
}
