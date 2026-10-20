# talos-k8s

Homelab Kubernetes cluster on Talos Linux VMs hosted on PVE, managed with Flux and reachable only over Tailscale.

| Path | Contents |
|---|---|
| `talos/` | Talos machine config patches and SOPS-encrypted secrets |
| `infrastructure/` | Cluster add-ons: local-path-provisioner, Tailscale operator |
| `apps/` | Workloads: Vaultwarden |
| `docs/PLAN.md` | Build and migration plan |