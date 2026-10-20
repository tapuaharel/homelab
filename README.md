# talos-k8s

Homelab Kubernetes cluster on Talos Linux (Proxmox VMs), managed with Flux and reachable only over Tailscale.

| Path | Contents |
|---|---|
| `talos/` | Talos machine config patches and SOPS-encrypted secrets |
| `infrastructure/` | Cluster add-ons: local-path-provisioner, Tailscale operator |
| `apps/` | Workloads: Vaultwarden |
| `docs/PLAN.md` | Build and migration plan |

Never commit `controlplane.yaml`, `worker.yaml`, `talosconfig` or any unencrypted secret.
