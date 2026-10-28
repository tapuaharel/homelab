locals {
  vms = {
    talos-cp-1 = { vm_id = 105, cores = 2, memory = 4096, disk = 20, mac = "BC:24:11:18:45:A9" }
    talos-w-1  = { vm_id = 106, cores = 4, memory = 8192, disk = 30, mac = "BC:24:11:27:EF:3C" }
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.vms

  name          = each.key
  node_name     = "pve"
  vm_id         = each.value.vm_id
  bios          = "ovmf"
  machine       = "q35"
  boot_order    = ["scsi0", "net0"]
  on_boot       = true
  tablet_device = false

  agent {
    enabled = true
  }

  cpu {
    type  = "host"
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
    floating  = 0 # ballooning off
  }

  disk {
    datastore_id = "vm"
    interface    = "scsi0"
    size         = each.value.disk
    cache        = "writethrough"
    discard      = "on"
    ssd          = true
    backup       = false
  }

  efi_disk {
    datastore_id = "vm"
    type         = "4m"
  }

  network_device {
    bridge      = "vmbr0"
    mac_address = each.value.mac
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  lifecycle {
    prevent_destroy = true
  }
}
