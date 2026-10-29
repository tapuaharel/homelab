# homelab

Homelab infrastructure built with OpenTofu and managed with GitOps using Flux and Renovate. Powered by Talos Linux VMs on Proxmox VE.

## How it works

The cluster has one control-plane node, `talos-cp-1`, and one worker node, `talos-w-1`. Each node reads its Talos config from cloud-init on first boot. The control plane joins the tailnet through the Tailscale system extension, so `talosctl` and `kubectl` work from any device on the tailnet. The worker stays on the LAN and runs every workload.

Flux pulls the `main` branch and applies `infrastructure/` first, then `apps/`. The infrastructure layer installs three components:

- local-path-provisioner, which stores volumes on a Talos user volume on the worker
- the Tailscale operator, which publishes apps on the tailnet with Tailscale-issued certificates
- the CloudNativePG operator, which runs PostgreSQL

The apps layer deploys Vaultwarden with a single-instance PostgreSQL 18 database. Tailnet devices reach it at `https://vault.<tailnet>.ts.net`.

SOPS and age encrypt the secrets in git, and Flux decrypts them in the cluster. Renovate opens weekly PRs for chart, image, Talos and OpenTofu provider updates.

OpenTofu manages the Talos layer. You run it by hand from `tofu/` on the workstation. It manages the two Proxmox VMs, builds each node's config from the patches in `talos/`, applies it, and upgrades a node when its installer image changes. It reads the Talos secrets from SOPS on each run and never writes them to state.

## Layout

| Path | Contents |
|---|---|
| `talos/` | Talos machine config patches and encrypted cluster secrets |
| `tofu/` | OpenTofu for the Proxmox VMs and Talos nodes |
| `clusters/homelab/` | Flux bootstrap and the Kustomizations for `infrastructure/` and `apps/` |
| `infrastructure/` | local-path-provisioner, Tailscale operator, CloudNativePG operator |
| `apps/` | Vaultwarden and its database |
| `docs/PLAN.md` | Build and migration runbook |

## Installation

This guide creates the cluster on an empty Proxmox VE host. You boot two Talos VMs with cloud-init, import them into OpenTofu, and bootstrap Flux, which installs the rest of the stack from this repository.

Run the commands from the repository root on your workstation, unless a section says to run them on the Proxmox node.

### Requirements

#### Proxmox VE

- A Proxmox VE node named `pve` with a `vm` datastore, a `vmbr0` bridge, and `local` storage for ISOs and snippets.
- Capacity for `talos-cp-1` with 2 vCPU, 4 GB RAM and a 20 GB disk, and for `talos-w-1` with 4 vCPU, 8 GB RAM and a 30 GB disk.
- Root SSH access to the node from the workstation.

#### Network

- DHCP reservations for the MAC addresses in `tofu/vms.tf`, with `10.220.20.56` for `talos-cp-1` and `10.220.20.57` for `talos-w-1`.
- An NFS export at `10.220.20.55:/vw-backups` that the worker can write to.

#### Tailscale

- MagicDNS and HTTPS certificates enabled.
- These tag owners in the tailnet policy file:

  ```jsonc
  "tagOwners": {
    "tag:talos":            ["autogroup:admin"],
    "tag:k8s-operator":     ["autogroup:admin"],
    "tag:k8s":              ["tag:k8s-operator"],
    "tag:password-manager": ["tag:k8s-operator"],
  },
  ```

  If the policy is not allow-all, also allow your user `tcp:50000,6443` to `tag:talos` and `tcp:443` to `tag:password-manager`.
- A valid auth key in `talos/patches/talos-cp-1.sops.yaml`. The key must be reusable, pre-approved, not ephemeral, and tagged `tag:talos`.
- The workstation joined to the tailnet.

> Note: Remove the `talos-cp-1`, `vault` and `tailscale-operator` devices of an earlier cluster from the admin console. Otherwise the new devices get a `-1` suffix.

#### Keys and tokens

- The age private key in `~/.config/sops/age/keys.txt`.
- A GitHub fine-grained personal access token for this repository, with these permissions:
  - `Administration`: Read and write
  - `Contents`: Read and write

### Install the CLI tools

Install these tools on the workstation:

- [talosctl](https://www.talos.dev/latest/talos-guides/install/talosctl/), the same minor version of Talos
- [kubectl](https://kubernetes.io/docs/tasks/tools/), within one minor version of Kubernetes
- [Flux CLI](https://fluxcd.io/flux/installation/#install-the-flux-cli), the version on the first line of `clusters/homelab/flux-system/gotk-components.yaml`
- [OpenTofu](https://opentofu.org/docs/intro/install/)
- [SOPS](https://github.com/getsops/sops#download)
- [age](https://github.com/FiloSottile/age#installation)
- The [kubectl cnpg plugin](https://cloudnative-pg.io/documentation/current/kubectl-plugin/) at the same version as the CloudNativePG operator, if you want `kubectl cnpg status` and `kubectl cnpg psql`

> Note: With a Flux CLI version that differs from the manifests, `flux bootstrap` commits a Flux upgrade.

### Set the environment variables

The commands in this guide use these variables:

```bash
export PVE_HOST=pve
export CONTROL_PLANE_IP=10.220.20.56
export WORKER_IP=10.220.20.57
export CONTROL_PLANE_ENDPOINT=talos-cp-1.<tailnet>.ts.net
```

### Upload the ISO

Enable snippets on the `local` storage. Keep the content types it already has:

```bash
ssh root@$PVE_HOST 'pvesm set local --content iso,vztmpl,backup,snippets'
```

Download the Talos nocloud ISO for the schematic and version in `talos/patches/talos-w-1.yaml`:

```bash
IMAGE=$(grep -oP 'image: \K\S+' talos/patches/talos-w-1.yaml)
SCHEMATIC=$(echo "$IMAGE" | sed -E 's#.*/nocloud-installer/([0-9a-f]+):.*#\1#')
VERSION=${IMAGE##*:}
ssh root@$PVE_HOST "wget -qO /var/lib/vz/template/iso/talos-nocloud-amd64.iso \
  https://factory.talos.dev/image/$SCHEMATIC/$VERSION/nocloud-amd64.iso"
```

### Generate the machine configurations

Generate the machine configurations from the encrypted cluster secrets, with the versions set in `tofu/talos.tf`:

```bash
TALOS_CONTRACT=$(grep -oP 'talos_version\s*=\s*"\K[^"]+' tofu/talos.tf)
K8S_VERSION=$(grep -oP 'kubernetes_version\s*=\s*"\K[^"]+' tofu/talos.tf)

cd talos
talosctl gen config homelab https://$CONTROL_PLANE_IP:6443 --with-secrets <(sops -d secrets.sops.yaml) \
  --talos-version "$TALOS_CONTRACT" --kubernetes-version "$K8S_VERSION" --force
```

Patch the configurations and upload them to the Proxmox node as cloud-init snippets:

```bash
talosctl machineconfig patch controlplane.yaml --patch @patches/common.yaml --patch @patches/talos-cp-1.yaml \
  --patch @<(sops -d patches/talos-cp-1.sops.yaml) \
  | ssh root@$PVE_HOST 'umask 077; cat > /var/lib/vz/snippets/talos-cp-1.yaml'
talosctl machineconfig patch worker.yaml --patch @patches/common.yaml --patch @patches/talos-w-1.yaml \
  | ssh root@$PVE_HOST 'umask 077; cat > /var/lib/vz/snippets/talos-w-1.yaml'
```

Remove the unpatched configurations and keep `talosconfig`:

```bash
rm controlplane.yaml worker.yaml
chmod 600 talosconfig
cd ..
```

### Create the VMs

On the Proxmox node, create the VMs with the settings in `tofu/vms.tf`:

```bash
qm create 105 --name talos-cp-1 --bios ovmf --machine q35 --ostype l26 \
  --cpu host --cores 2 --memory 4096 --balloon 0 \
  --scsihw virtio-scsi-pci --scsi0 vm:20,cache=writethrough,discard=on,ssd=1,backup=0 \
  --efidisk0 vm:1,efitype=4m,pre-enrolled-keys=0 \
  --net0 virtio=BC:24:11:18:45:A9,bridge=vmbr0,firewall=1 \
  --agent enabled=1 --onboot 1 --tablet 0 \
  --ide2 local:iso/talos-nocloud-amd64.iso,media=cdrom \
  --ide0 vm:cloudinit --ipconfig0 ip=dhcp --cicustom user=local:snippets/talos-cp-1.yaml \
  --boot order='scsi0;ide2'

qm create 106 --name talos-w-1 --bios ovmf --machine q35 --ostype l26 \
  --cpu host --cores 4 --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-pci --scsi0 vm:30,cache=writethrough,discard=on,ssd=1,backup=0 \
  --efidisk0 vm:1,efitype=4m,pre-enrolled-keys=0 \
  --net0 virtio=BC:24:11:27:EF:3C,bridge=vmbr0,firewall=1 \
  --agent enabled=1 --onboot 1 --tablet 0 \
  --ide2 local:iso/talos-nocloud-amd64.iso,media=cdrom \
  --ide0 vm:cloudinit --ipconfig0 ip=dhcp --cicustom user=local:snippets/talos-w-1.yaml \
  --boot order='scsi0;ide2'
```

Start the VMs:

```bash
qm start 105 && qm start 106
```

Each VM installs Talos with its cloud-init configuration and reboots from disk. `talos-cp-1` then appears in the Tailscale admin console with the tag `tag:talos`.

### Bootstrap etcd

Point `talosctl` at the control plane and bootstrap etcd:

```bash
export TALOSCONFIG=$PWD/talos/talosconfig
talosctl config endpoint $CONTROL_PLANE_ENDPOINT
talosctl config node $CONTROL_PLANE_IP
talosctl bootstrap
```

Run `talosctl bootstrap` only once.

### Retrieve the kubeconfig

```bash
talosctl kubeconfig
kubectl config set-cluster homelab --server=https://$CONTROL_PLANE_ENDPOINT:6443
kubectl get nodes -o wide
```

Both nodes report `Ready`, with an `INTERNAL-IP` in `10.220.20.0/24`.

### Remove the install media

Delete the snippets, detach the ISO and the cloud-init drive, and set the boot order in `tofu/vms.tf`:

```bash
ssh root@$PVE_HOST 'rm /var/lib/vz/snippets/talos-cp-1.yaml /var/lib/vz/snippets/talos-w-1.yaml
  qm set 105 --delete ide0,ide2,cicustom,ipconfig0 --boot "order=scsi0;net0"
  qm set 106 --delete ide0,ide2,cicustom,ipconfig0 --boot "order=scsi0;net0"'
```

### Import the cluster into OpenTofu

#### Create an API token

On the Proxmox node, as root, create a role, a user and a token for OpenTofu:

```bash
pveum role add OpenTofu -privs "VM.Audit VM.Allocate VM.PowerMgmt VM.GuestAgent.Audit \
  VM.Config.CPU VM.Config.Memory VM.Config.Disk VM.Config.Network VM.Config.Options \
  VM.Config.HWType VM.Config.CDROM Datastore.Audit Datastore.AllocateSpace SDN.Audit SDN.Use Sys.Audit"
pveum user add opentofu@pve
pveum acl modify / -user opentofu@pve -role OpenTofu
pveum user token add opentofu@pve homelab --privsep 0
```

The last command prints the token secret once.

#### Configure the provider

Trust the Proxmox CA on the workstation and export the token:

```bash
ssh root@$PVE_HOST cat /etc/pve/pve-root-ca.pem | sudo tee /usr/local/share/ca-certificates/pve-root-ca.crt
sudo update-ca-certificates
export PROXMOX_VE_ENDPOINT=https://<pve-address>:8006/
export PROXMOX_VE_API_TOKEN='opentofu@pve!homelab=<secret>'
```

#### Import and apply

```bash
cd tofu
tofu init
tofu import 'proxmox_virtual_environment_vm.node["talos-cp-1"]' pve/105
tofu import 'proxmox_virtual_environment_vm.node["talos-w-1"]' pve/106
tofu import talos_machine_bootstrap.this done
tofu plan
tofu apply -parallelism=1
cd ..
```

The plan lists only the two `talos_machine` resources to create and an update to the bootstrap state. After the apply, `tofu plan` reports no changes.

> Note: Start without state. Git ignores `tofu/*.tfstate`, so a fresh clone has none.

### Bootstrap Flux

Create the `sops-age` Secret that Flux uses to decrypt the secrets in this repository:

```bash
kubectl create namespace flux-system
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

Export the GitHub token. If `GITHUB_TOKEN` is not set, the bootstrap command prompts for it.

```bash
read -s GITHUB_TOKEN && export GITHUB_TOKEN
```

Run the bootstrap:

```bash
flux bootstrap github \
  --owner=tapuaharel \
  --repository=homelab \
  --branch=main \
  --path=clusters/homelab \
  --personal
```

The bootstrap adds a read-only deploy key to the repository and syncs `clusters/homelab/`. Flux applies `infrastructure/` first, then `apps/`. Check the reconciliation:

```bash
flux get kustomizations --watch
flux get helmreleases -A
```

After the bootstrap, delete the GitHub token and run `git pull`.

> Note: Delete the deploy key of an earlier cluster under **Settings**, **Deploy keys** before you run the bootstrap.

### Using your own keys and network

To run the cluster with your own keys and network, fork the repository and change these values before the installation:

| Value | Location |
|---|---|
| age public key | `.sops.yaml` |
| Talos cluster secrets | `talos/secrets.sops.yaml`. Generate them with `talosctl gen secrets` and encrypt them with `sops -e`. |
| Tailscale auth key | `talos/patches/talos-cp-1.sops.yaml` |
| Tailscale operator OAuth client | `infrastructure/tailscale-operator/operator-oauth.sops.yaml` |
| Vaultwarden admin token | `apps/vaultwarden/vaultwarden-secrets.sops.yaml` |
| Backup archive password | `apps/vaultwarden/vaultwarden-backup.sops.yaml` |
| Tailnet name | `talos/patches/talos-cp-1.yaml`, `tofu/talos.tf`, `apps/vaultwarden/deployment.yaml` |
| LAN subnet and node IPs | `talos/patches/common.yaml`, `talos/patches/talos-cp-1.yaml`, `tofu/talos.tf` |
| Proxmox node, datastore, bridge, VM IDs and MAC addresses | `tofu/vms.tf` |
| NFS server and path | `apps/vaultwarden/backup.yaml` |

Edit the encrypted files with `sops <path>`. Update the environment variables, the `qm` commands and the `flux bootstrap` flags to match.
