# homelab

Homelab Kubernetes cluster that runs [Vaultwarden](https://github.com/dani-garcia/vaultwarden). It runs on two Talos Linux VMs on Proxmox VE, Flux manages it from this repo, and it is reachable only over Tailscale.

## How it works

The cluster has one control-plane node, `talos-cp-1`, and one worker node, `talos-w-1`. Each node reads its Talos config from cloud-init on first boot. The control plane joins the tailnet through the Tailscale system extension, so `talosctl` and `kubectl` work from any device on the tailnet. The worker stays on the LAN and runs every workload.

Flux pulls the `main` branch and applies `infrastructure/` first, then `apps/`. The infrastructure layer installs three components:

- local-path-provisioner, which stores volumes on a Talos user volume on the worker
- the Tailscale operator, which publishes apps on the tailnet with Tailscale-issued certificates
- the CloudNativePG operator, which runs PostgreSQL

The apps layer deploys Vaultwarden with a single-instance PostgreSQL 18 database. Tailnet devices reach it at `https://vault.<tailnet>.ts.net`.

SOPS and age encrypt the secrets in git, and Flux decrypts them in the cluster. Renovate opens weekly PRs for chart, image and Talos version updates. Flux doesn't manage the Talos config in `talos/`. You apply it by hand with `talosctl`.

## Layout

| Path | Contents |
|---|---|
| `talos/` | Talos machine config patches and encrypted cluster secrets |
| `clusters/homelab/` | Flux bootstrap and the Kustomizations for `infrastructure/` and `apps/` |
| `infrastructure/` | local-path-provisioner, Tailscale operator, CloudNativePG operator |
| `apps/` | Vaultwarden and its database |
| `docs/PLAN.md` | Build and migration runbook |
