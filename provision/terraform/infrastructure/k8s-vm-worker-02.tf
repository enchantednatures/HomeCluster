resource "proxmox_virtual_environment_vm" "k8s-work-02" {
  provider  = proxmox.euclid
  node_name = var.euclid.node_name

  name        = "k8s-work-02"
  description = "Kubernetes Worker 02"
  tags        = ["k8s", "worker"]
  on_boot     = true
  vm_id       = 8102

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "ovmf"

  cpu {
    cores = 4
    type  = "host"
  }

  memory {
    dedicated = 16384
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = "BC:24:11:2E:AE:02"
  }

  efi_disk {
    datastore_id = "local"
    file_format = "raw" // To support qcow2 format
    type         = "4m"
  }

  disk {
    datastore_id = "data"
    file_id      = proxmox_virtual_environment_download_file.debian_12_generic_image.id
    iothread     = true
    interface    = "scsi0"
    cache        = "writethrough"
    discard      = "on"
    ssd          = true
    size         = 32
  }

  disk {
    datastore_id = "data"
    iothread     = true
    file_format  = "raw"
    interface    = "scsi1"
    cache        = "writethrough"
    discard      = "on"
    ssd          = true
    size         = 64
  }

  disk {
    datastore_id = "data"
    iothread     = true
    file_format  = "raw"
    interface    = "scsi2"
    cache        = "writethrough"
    discard      = "on"
    ssd          = true
    size         = 512
  }

  boot_order = ["scsi0"]

  agent {
    enabled = true
  }

  operating_system {
    type = "l26" # Linux Kernel 2.6 - 6.X.
  }

  initialization {
    dns {
      domain  = var.vm_dns.domain
      servers = var.vm_dns.servers
    }
    ip_config {
      ipv4 {
        address = "192.168.1.202/24"
        gateway = "192.168.1.1"
      }
    }

    datastore_id      = "local"
    user_data_file_id = proxmox_virtual_environment_file.cloud-init-work-02.id
  }
}

output "work_02_ipv4_address" {
  depends_on = [proxmox_virtual_environment_vm.k8s-work-02]
  value      = proxmox_virtual_environment_vm.k8s-work-02.ipv4_addresses[1][0]
}

resource "local_file" "work-02-ip" {
  content         = proxmox_virtual_environment_vm.k8s-work-02.ipv4_addresses[1][0]
  filename        = "output/work-02-ip.txt"
  file_permission = "0644"
}
