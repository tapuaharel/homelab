# Talos Kubernetes homelab: Vaultwarden migration plan (v3.1)

**Goal:** Move Vaultwarden from Docker Compose (Proxmox VM, published with Tailscale Serve) to a Talos Kubernetes cluster managed with GitOps. It stays reachable **only inside the tailnet**, at `https://vault.<tailnet>.ts.net`.

---

## 0. Key decisions

| Decision | Choice | Reason |
|---|---|---|
| Cluster management | Control plane joins the tailnet using the official `siderolabs/tailscale` extension | No subnet routes needed; `talosctl` and `kubectl` work from anywhere on the tailnet |
| App exposure | Tailscale Kubernetes operator, `ingressClassName: tailscale` | Works like the current Serve setup: tailnet-only, MagicDNS name, certificate issued by Tailscale |
| First boot | Talos config delivered as Nocloud cloud-init user-data (Proxmox snippets) | No maintenance mode and no LAN access needed; everything runs over the tailnet |
| URL | `https://vault.<tailnet>.ts.net` | Clean name; each client's server URL is changed once at cutover |
| DNS | MagicDNS only | No local or public DNS records |
| Not used | Own domain, Traefik, Gateway API, cert-manager, MetalLB, metrics-server, Renovate, vzdump | Not needed for a tailnet-only `ts.net` setup |

---

## 1. Design summary

### Resources (single Proxmox node: 20 cores, 16 GB RAM)

| VM | vCPU | RAM | Disk | Role |
|---|---|---|---|---|
| Proxmox host overhead | – | ~2 GB | – | |
| Existing Docker VM | as is | as is | – | Rollback until the cutover is proven |
| `talos-cp-1` | 2 | 4 GB | 20 GB | Control plane, **on the tailnet** |
| `talos-w-1` | 2 | 2 GB | 30 GB | All workloads and data (LAN only): EPHEMERAL ≤ 15 GiB, local-path user volume ≥ 10 GiB |

Expected worker usage: the Tailscale operator and Vaultwarden's proxy pod about 150–200 MB, local-path about 20 MB, Vaultwarden about 50 MB, Flux 300–500 MB. That's **roughly 0.5–0.8 GB of about 1.6 GB available to pods**. Set memory requests and limits on everything. If the worker runs out, move to a 3 GB / 3 GB split.

### Network

| Address | Use |
|---|---|
| `10.100.20.10` | `talos-cp-1`: DHCP reservation for MAC `02:00:0A:64:14:0A` |
| `10.100.20.11` | `talos-w-1`: DHCP reservation for MAC `02:00:0A:64:14:0B` |
| `talos-cp-1.<tailnet>.ts.net` | Talos API (50000) and Kubernetes API (6443) over the tailnet |
| `vault.<tailnet>.ts.net` | Vaultwarden (443, Tailscale-issued certificate) |

Place the two reservations wherever the router requires them: outside the dynamic pool on OPNsense or pfSense, inside it on some consumer routers.

### Stack

| Layer | Choice |
|---|---|
| OS | Talos, **Nocloud** image. Control plane schematic: `qemu-guest-agent` + `tailscale`. Worker schematic: `qemu-guest-agent` |
| Container networking | Flannel (Talos default) |
| Storage | local-path-provisioner |
| Exposure and TLS | Tailscale Kubernetes operator |
| GitOps | Flux + SOPS/age, repo **`talos-k8s`** |
| Backups | Nightly CronJob → off-host storage |

### Repository layout

```
talos-k8s/
├── .sops.yaml
├── talos/
│   ├── patches/
│   │   ├── common.yaml               # kubelet node IP subnet
│   │   ├── talos-cp-1.yaml           # hostname, installer image, cert SANs, etcd subnet
│   │   ├── talos-cp-1.sops.yaml      # Tailscale auth key (encrypted)
│   │   └── talos-w-1.yaml            # hostname, installer image, local-path user volume
│   └── secrets.sops.yaml
├── infrastructure/
│   ├── local-path-provisioner/
│   └── tailscale-operator/           # HelmRelease + OAuth secret (SOPS)
└── apps/
    └── vaultwarden/                  # Deployment, PVC, Service, Ingress, Secret, backup CronJob
```

> 🔒 Never commit `controlplane.yaml`, `worker.yaml`, `talosconfig` or any unencrypted secret. `.gitignore` covers the generated Talos files.

---

## 2. Phase 0: Preparation

### Tailnet (admin console)
- [ ] Check that **MagicDNS** and **HTTPS certificates** are enabled.
- [ ] Add tag owners to the tailnet policy file:
  ```jsonc
  "tagOwners": {
    "tag:talos":        ["autogroup:admin"],
    "tag:k8s-operator": ["autogroup:admin"],
    "tag:k8s":          ["tag:k8s-operator"],
    "tag:password-manager": ["tag:k8s-operator"],
  },
  ```
  If the policy is not the default allow-all, also allow your user `tcp:50000,6443` to `tag:talos` and `tcp:443` to `tag:password-manager` (the Vaultwarden proxy, see Phase 3).
- [ ] Create an **auth key** for the control plane: **reusable, pre-approved, tagged `tag:talos`, not ephemeral**. It has to be reusable because a Talos reset or reinstall wipes the node's Tailscale state.
- [ ] Create an **OAuth client** for the operator with tag `tag:k8s-operator`, using the scopes the operator docs list for your version (at least Devices Core and Auth Keys, write access).

### Image Factory (Cloud Server → Nocloud, latest stable)
- [ ] **Control-plane schematic:** `siderolabs/qemu-guest-agent` + `siderolabs/tailscale`
- [ ] **Worker schematic:** `siderolabs/qemu-guest-agent`
- [ ] Download the nocloud ISO (either schematic works for the first boot) and write down **both installer image URLs** exactly as the factory shows them.

### Workstation
- [ ] Install `talosctl`, `kubectl`, `helm`, `k9s`, `flux`, `sops` and `age`.
- [ ] Make sure the workstation is on the tailnet and can SSH to the Proxmox host (referred to as `pve` below).
- [ ] Generate an age key (`age-keygen -o ~/.config/sops/age/keys.txt`) and replace `age1REPLACE_ME` in `.sops.yaml` with its public key. **Back up `keys.txt` off this machine**; without it the encrypted files can't be decrypted.

### Proxmox host
- [ ] Enable **Snippets** on the `local` storage (Datacenter → Storage → `local` → Content). Keep the existing content types; the shell equivalent must list all of them because it replaces the list:
  ```bash
  pvesm set local --content iso,vztmpl,backup,snippets
  ```

### Proxmox VMs (create both, **do not start yet**)

| Setting | Value |
|---|---|
| CPU type | **`host`** (Talos needs x86-64-v2) |
| Memory | Fixed amount, **ballooning off** |
| Disk | VirtIO SCSI single |
| QEMU guest agent | Enabled |
| Start at boot | Yes |
| Cloud-init drive | **`ide0` CloudInit drive**, IP config `ip=dhcp` |
| Cloud-init custom user-data | **`cicustom user=local:snippets/<node>.yaml`** (the Talos machine config) |

```bash
qm set 201 --net0 virtio=02:00:0A:64:14:0A,bridge=vmbr0
qm set 202 --net0 virtio=02:00:0A:64:14:0B,bridge=vmbr0
qm set 201 --ide0 local-lvm:cloudinit --ipconfig0 ip=dhcp --cicustom user=local:snippets/talos-cp-1.yaml
qm set 202 --ide0 local-lvm:cloudinit --ipconfig0 ip=dhcp --cicustom user=local:snippets/talos-w-1.yaml
qm config 201    # verify net0, ide0, cicustom
```
- [ ] Create both **DHCP reservations** (MAC → IP) on the router.

**Done when:** both VMs exist (still stopped) with the cloud-init drive and `cicustom` set, both DHCP reservations are in place, and snippets are enabled on `local`.

---

## 3. Phase 1: Build the Talos cluster

The nodes read their Talos config from the cloud-init drive on first boot, install themselves, and the control plane joins the tailnet. Everything runs from the workstation over the tailnet; no LAN access is needed.

### Patches

Talos v1.14 uses separate config documents (`HostnameConfig`, `UnattendedInstallConfig`, `KubeNodeConfig`, `KubeAPIServerConfig`, ...). The old `machine.install`, `machine.network.hostname`, `machine.kubelet` and `cluster.apiServer` fields are rejected next to them.

| Patch | Applies to | Contents |
|---|---|---|
| `common.yaml` | both | `KubeNodeConfig`: kubelet node IP on the LAN subnet |
| `talos-cp-1.yaml` | control plane | Talos API cert SAN, etcd LAN subnet, `HostnameConfig`, `UnattendedInstallConfig` (tailscale schematic), `KubeAPIServerConfig.certExtraSANs` |
| `talos-cp-1.sops.yaml` | control plane | `ExtensionServiceConfig` for Tailscale (auth key). Edit only with `sops talos/patches/talos-cp-1.sops.yaml` |
| `talos-w-1.yaml` | worker | `HostnameConfig`, `UnattendedInstallConfig`, EPHEMERAL capped at 15 GiB, `UserVolumeConfig` `local-path-provisioner` (mounted at `/var/mnt/local-path-provisioner`) |

> ⚠️ With a second network interface (`tailscale0`), the kubelet and etcd might otherwise advertise the 100.x tailnet address. The worker can't reach that address, so the cluster breaks in confusing ways.

Check any patch change before using it:
```bash
talosctl machineconfig patch controlplane.yaml --patch @patches/common.yaml --patch @patches/talos-cp-1.yaml \
  --patch @<(sops -d patches/talos-cp-1.sops.yaml) | talosctl validate --config /dev/stdin --mode metal
```

### Step 1: Generate the configs (locally, before the first boot)

```bash
cd talos
talosctl gen secrets -o secrets.yaml
talosctl gen config homelab https://10.100.20.10:6443 --with-secrets secrets.yaml
```
Don't pass `--config-patch` here: patches baked into the generated files can't be removed later. All patches are applied in step 2.

### Step 2: Upload the patched configs as snippets

Patch on the workstation and stream straight to the Proxmox host, so no patched plaintext file is written locally. `umask 077` keeps the snippets readable by root only.
```bash
talosctl machineconfig patch controlplane.yaml --patch @patches/common.yaml --patch @patches/talos-cp-1.yaml \
  --patch @<(sops -d patches/talos-cp-1.sops.yaml) \
  | ssh pve 'umask 077; cat > /var/lib/vz/snippets/talos-cp-1.yaml'
talosctl machineconfig patch worker.yaml --patch @patches/common.yaml --patch @patches/talos-w-1.yaml \
  | ssh pve 'umask 077; cat > /var/lib/vz/snippets/talos-w-1.yaml'
```

### Step 3: Boot and bootstrap over the tailnet

```bash
ssh pve 'qm start 201 && qm start 202'
# Wait a few minutes: install → reboot → talos-cp-1 appears in the admin console tagged tag:talos

talosctl --talosconfig ./talosconfig config endpoint talos-cp-1.<tailnet>.ts.net
talosctl --talosconfig ./talosconfig config node 10.100.20.10
talosctl bootstrap        # ONCE, control plane only
talosctl kubeconfig
kubectl config set-cluster homelab --server=https://talos-cp-1.<tailnet>.ts.net:6443
kubectl get nodes -o wide
talosctl -n 10.100.20.11 version     # the worker is reached through the control plane, no tailnet needed on it
```

The cluster endpoint stays `10.100.20.10` for internal traffic. Only the workstation uses the tailnet name, and the cert SANs make that name valid for TLS.

> If `talos-cp-1` never appears on the tailnet, open its Proxmox console. The Talos dashboard shows the IP it received, whether the install finished, and Tailscale errors such as a bad auth key.

### Step 4: Clean up

Once both nodes are `Ready`, Talos keeps its config on its own disk, so remove the plaintext configs from the Proxmox host, detach the cloud-init drives and the ISO, and encrypt the Talos secrets:
```bash
ssh pve 'rm /var/lib/vz/snippets/talos-cp-1.yaml /var/lib/vz/snippets/talos-w-1.yaml
         qm set 201 --delete ide0,cicustom,ide2
         qm set 202 --delete ide0,cicustom,ide2'
sops -e secrets.yaml > secrets.sops.yaml && rm secrets.yaml
```

**Done when:**
- [ ] `kubectl get nodes -o wide` shows both nodes `Ready`, with `INTERNAL-IP` set to the **10.100.20.x** addresses (not 100.x)
- [ ] `talosctl health`, `talosctl dashboard` and `kubectl` work from the workstation over the tailnet
- [ ] The snippets are deleted, the cloud-init drives and ISO are detached, and `secrets.yaml` is encrypted

---

## 4. Phase 2: Platform

### 4.1 local-path-provisioner
- Label its namespace `pod-security.kubernetes.io/enforce=privileged`; Talos's baseline pod security policy blocks its helper pods otherwise.
- Point it at `/var/mnt/local-path-provisioner` (the Talos user volume on the worker) and make it the default StorageClass.

**Done when:** a test PVC binds once a pod uses it.

### 4.2 Tailscale Kubernetes operator
```bash
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  -n tailscale --create-namespace \
  --set oauth.clientId=<id> --set oauth.clientSecret=<secret>
kubectl label ns tailscale pod-security.kubernetes.io/enforce=privileged
```
> ⚠️ The operator creates its proxy pods in the `tailscale` namespace, and they need privileged access. Without the label they're silently rejected.

**Done when:** `tailscale-operator` appears as a device in the admin console, tagged `tag:k8s-operator`.

---

## 5. Phase 3: Vaultwarden rehearsal (production stays on Docker + Serve)

### Manifests (`apps/vaultwarden/`)
```yaml
apiVersion: v1
kind: Namespace
metadata: { name: vaultwarden }
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: vaultwarden-data, namespace: vaultwarden }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources: { requests: { storage: 2Gi } }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: vaultwarden, namespace: vaultwarden }
spec:
  replicas: 0                      # scale to 1 after the data copy
  strategy: { type: Recreate }     # SQLite + RWO: never two pods
  selector: { matchLabels: { app: vaultwarden } }
  template:
    metadata: { labels: { app: vaultwarden } }
    spec:
      containers:
        - name: vaultwarden
          image: vaultwarden/server:<same tag as the compose file>
          env:
            - { name: DOMAIN, value: "https://vault-test.<tailnet>.ts.net" }
            - { name: SIGNUPS_ALLOWED, value: "false" }
          envFrom:
            - secretRef: { name: vaultwarden-secrets }   # ADMIN_TOKEN (argon2), SMTP_*, ...
          ports: [{ name: http, containerPort: 80 }]
          volumeMounts: [{ name: data, mountPath: /data }]
          readinessProbe: { httpGet: { path: /alive, port: http } }
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits:   { memory: 256Mi }
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: vaultwarden-data }
---
apiVersion: v1
kind: Service
metadata: { name: vaultwarden, namespace: vaultwarden }
spec:
  selector: { app: vaultwarden }
  ports: [{ name: http, port: 80, targetPort: http }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vaultwarden
  namespace: vaultwarden
  annotations:
    tailscale.com/tags: "tag:password-manager"   # own tag instead of the shared tag:k8s, so ACLs can target only this proxy
spec:
  ingressClassName: tailscale
  defaultBackend:
    service: { name: vaultwarden, port: { number: 80 } }
  tls:
    - hosts: [vault-test]          # → https://vault-test.<tailnet>.ts.net
```

Move every setting from the compose `environment:` block into `env` (non-secret) or `vaultwarden-secrets` (secret). WebSockets run on port 80, so port 3012 isn't needed.

### Copy the data
```bash
# Docker VM: consistent snapshot while prod keeps running
sqlite3 /path/to/vw-data/db.sqlite3 ".backup '/tmp/db.sqlite3'"
tar -czf vw-data.tgz -C /path/to/vw-data --exclude='db.sqlite3*' . -C /tmp db.sqlite3

# Cluster: temporary pod fills the PVC
kubectl -n vaultwarden run restore --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"vaultwarden-data"}}],"containers":[{"name":"restore","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
kubectl cp vw-data.tgz vaultwarden/restore:/data/
kubectl -n vaultwarden exec restore -- sh -c 'tar -xzf /data/vw-data.tgz -C /data && rm /data/vw-data.tgz'
kubectl -n vaultwarden delete pod restore
kubectl -n vaultwarden scale deploy/vaultwarden --replicas=1
```

The files that matter are `db.sqlite3`, `rsa_key*`, `attachments/`, `sends/` and `config.json` if present. `icon_cache/` is optional.

**Done when:**
- [ ] `https://vault-test.<tailnet>.ts.net` loads from a tailnet device, the login works, the items are there and attachments open
- [ ] The URL does **not** resolve from a device outside the tailnet

---

## 6. Phase 4: Backups and restore drill (before going live)

- [ ] **Nightly CronJob** in `vaultwarden`: `sqlite3 .backup` + tar `/data` + `rclone` to off-host storage (B2, NAS, etc.). The community image `ttionya/vaultwarden-backup` does all of this. It can mount the same RWO PVC because there's only one worker.
- [ ] **Restore drill:** delete the `vaultwarden` namespace, including the PVC, and restore from the off-host backup using the Phase 3 procedure. Time it.

**Done when:** a restore from backup has worked at least once.

---

## 7. Phase 5: Cutover

1. [ ] **Stop the old service** on the Docker VM:
   ```bash
   docker compose stop vaultwarden
   tailscale serve reset        # or remove only Vaultwarden's handler if Serve fronts other services there
   ```
   Never run both at once, or the databases diverge.
2. [ ] **Copy the data again** from the now-stopped container (Phase 3 procedure: scale to 0, restore pod, scale to 1).
3. [ ] **Switch to the final name:** set `DOMAIN` to `https://vault.<tailnet>.ts.net` and the Ingress `tls.hosts` to `[vault]`, then apply. Delete the old `vault-test` device from the admin console if it remains.
4. [ ] **Update each client:** in the browser extension, phone apps and desktop app, change the server URL to `https://vault.<tailnet>.ts.net` and log in again. The vault data doesn't change, only where the clients connect.
5. [ ] **Test:** web vault, browser extension autofill, phone app sync, opening an attachment, creating an item and seeing it sync to another client.
6. [ ] **Keep the old VM and its data untouched for 2–4 weeks.** Rollback means: scale the Deployment to 0, start the container, re-enable its Serve config, and point the clients back to the old URL.

---

## 8. Phase 6: GitOps (Flux)

- [ ] `flux bootstrap github ...` against `talos-k8s`.
- [ ] Create a `Kustomization` for `infrastructure`, and one for `apps` with `dependsOn: infrastructure`.
- [ ] Move the Tailscale operator to a Flux `HelmRelease`, with the OAuth credentials in a SOPS-encrypted Secret.
- [ ] Encrypt `vaultwarden-secrets` with SOPS and give Flux the age key (`sops-age` Secret in `flux-system`).
- [ ] Check worker RAM in `talosctl dashboard` once Flux is running.

**Done when:** deleting the Vaultwarden Deployment by hand results in Flux recreating it within a minute.

---

## 9. Phase 7: Drills

| Drill | What you learn |
|---|---|
| `talosctl upgrade` each node **with its own installer image** (control plane: the tailscale schematic) | Immutable OS upgrades; the extension survives the upgrade |
| `talosctl upgrade-k8s` | Kubernetes version upgrades |
| Delete both VMs, recreate them (Phase 0), re-run Phase 1 steps 2–4 and restore the Vaultwarden backup, entirely over the tailnet | Whether everything can be rebuilt from the repo and backups alone |
