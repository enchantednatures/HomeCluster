locals {
  nodes = flatten([flatten([
    for resource in var.control_plane_nodes : [
      for count in range(resource.count) : {
        i            = count
        ram          = resource.ram
        cores        = resource.cores
        name         = format("%s-%02s", resource.name, count + 1)
        disk_size    = resource.disk_size
        storage_pool = resource.storage_pool
      } # if resource.name != "storage"
    ]
    ]), flatten([
    for resource in var.node_types : [
      for count in range(resource.count) : {
        i            = count
        ram          = resource.ram
        cores        = resource.cores
        name         = format("%s-%02s", resource.name, count + 1)
        disk_size    = resource.disk_size
        storage_pool = format("%s%s", resource.storage_pool_prefix, count + 1)
      } # if resource.name != "storage"
    ]

  ])])
}

resource "tailscale_tailnet_key" "machine_key" {
  reusable      = true
  ephemeral     = true
  preauthorized = true
  expiry        = 3600
  description   = "Auth Key"
}

data "proxmox_virtual_environment_vms" "template" {
  node_name = var.target_node
  tags      = ["template", var.template_tag]
}



resource "proxmox_virtual_environment_file" "cloud_network_config" {
  count        = length(local.nodes)
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_host

  source_raw {
    data = templatefile("./cloud-inits/network.tftpl",
      {
        ip_addr = format("192.168.1.2%02s", count.index + 1)
      }
    )

    file_name = "network-${count.index}.yaml"
  }
}
resource "proxmox_virtual_environment_file" "cloud_user_config" {
  count        = length(local.nodes)
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_host


  source_raw {
    data      = templatefile("./cloud-inits/user.tftpl", {
      hostname = local.nodes[count.index].name
      tailscale_machine_key = tailscale_tailnet_key.machine_key.key
    }) # file_name = "${var.vm_hostname}.${var.domain}-ci-user.yml"
    file_name = "user-${count.index}.yaml"
  }
}



resource "proxmox_virtual_environment_vm" "kubernetes_vm" {
  count     = length(local.nodes)
  name      = local.nodes[count.index].name
  node_name = "pve"
  tags      = ["terraform", "k3s"]

  vm_id = 101 + count.index

  # on_boot = var.onboot

  agent {
    enabled = true
  }


  # machine = "q35"
  operating_system { type = "l26" }
  bios = "seabios"

  cpu {
    architecture = "x86_64"
    type         = "host"
    cores        = local.nodes[count.index].cores
    sockets      = 1
    flags        = []
  }


  memory {
    dedicated = local.nodes[count.index].ram
  }

  network_device {
    bridge = "vmbr0"
    model  = "virtio"
    # vlan_id = var.network.tag
  }


  # Ignore changes to the network
  ## MAC address is generated on every apply, causing
  ## TF to think this needs to be rebuilt on every apply
  lifecycle {
    ignore_changes = [
      network_device,
    ]
  }

  # boot_order    = ["scsi0"]
  # scsi_hardware = "virtio-scsi-pci"

  disk {
    datastore_id = local.nodes[count.index].storage_pool
    size         = local.nodes[count.index].disk_size
    # file_id      = proxmox_virtual_environment_file.ubuntu_cloud_image.id
    interface = "scsi0"

    discard = "ignore"
    ssd     = true
  }

  serial_device {
    device = "socket"
  }

  clone {
    vm_id = 9001
    full  = true
  }

  initialization {
    datastore_id         = local.nodes[count.index].storage_pool
    network_data_file_id = proxmox_virtual_environment_file.cloud_network_config[count.index].id
    user_data_file_id    = proxmox_virtual_environment_file.cloud_user_config[count.index].id
    user_account {
      keys     = [trimspace(tls_private_key.ubuntu_vm_key.public_key_openssh)]
      password = random_password.ubuntu_vm_password.result
      username = "kube_admin"
    }
    # interface            = ""
    # ip_config {
    #   ipv4 {
    #     address = "dhcp"
    #   }
    # }
    # meta_data_file_id    = proxmox_virtual_environment_file.cloud_meta_config.id
  }
}

# resource "proxmox_virtual_environment_file" "ubuntu_cloud_image" {
#   content_type = "iso"
#   datastore_id = "local"
#   node_name    = "pve"

#   source_file {
#     path      = "https://cdimage.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
#     file_name = "debian-12-genericcloud-amd64.img"
#   }
# }



resource "random_password" "ubuntu_vm_password" {
  length           = 16
  override_special = "_%@"
  special          = true
}

resource "tls_private_key" "ubuntu_vm_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

output "ubuntu_vm_password" {
  value     = random_password.ubuntu_vm_password.result
  sensitive = true
}

output "ubuntu_vm_private_key" {
  value     = tls_private_key.ubuntu_vm_key.private_key_pem
  sensitive = true
}

output "ubuntu_vm_public_key" {
  value = tls_private_key.ubuntu_vm_key.public_key_openssh
}
