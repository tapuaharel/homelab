# One-time adoption of the hand-built cluster (docs/PLAN.md, Phase 7).
# Delete this file after the first successful apply.

# `tofu plan -generate-config-out=vms.tf` writes the resource blocks for these.
import {
  to = proxmox_virtual_environment_vm.talos_cp_1
  id = "pve/105"
}

import {
  to = proxmox_virtual_environment_vm.talos_w_1
  id = "pve/106"
}

# Marks the cluster as already bootstrapped; any ID works.
import {
  to = talos_machine_bootstrap.this
  id = "done"
}
