image = {
  version = "v1.7.4"
  schematic = file("schematic.yaml")
}

nodes = {

  "ctrl-01" = {
    host_node    = "pve"
    machine_type = "controlplane"
  }
  "ctrl-02" = {
    host_node    = "pve"
    machine_type = "controlplane"
  }

  "ctrl-03" = {
    host_node    = "pve"
    machine_type = "controlplane"
  }
}
