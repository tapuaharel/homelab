# Talos Kubernetes homelab: Vaultwarden migration plan (v4)

**Goal:** Move Vaultwarden from Docker Compose (Proxmox VM, published with Tailscale Serve) to a Talos Kubernetes cluster managed with GitOps. It stays reachable **only inside the tailnet**, at `https://vault.<tailnet>.ts.net`.

---

## 0. Key decisions

| Decision | Choice | Reason |
|---|---|---|
| Cluster management | Control plane joins the tailnet using the official `siderolabs/tailscale` extension | No subnet routes needed; `talosctl` and `kubectl` work from anywhere on the tailnet |
| App exposure | Tailscale Kubernetes operator, `ingressClassName: tailscale` | Works like the current Serve setup: tailnet-only, MagicDNS name, certificate issued by Tailscale |
| First boot | Talos config delivered as Nocloud cloud-init user-data (Proxmox snippets) | No maintenance mode and no LAN access needed; everything runs over the tailnet |
| URL | `https://vault.<tailnet>.ts.net` | Clean name; each client's server URL is changed once at the migration |
| Database | **CloudNativePG**, PostgreSQL 18, one instance. Data migrated from the current MySQL with pgloader | Declarative Postgres managed by an operator; learning goal. Deviations from CNPG's multi-node best practices are listed in Phase 3 |
| Database backups | Nightly logical dump (`pg_dump`) + `/data`, off-host | Keeps cert-manager out; no point-in-time recovery |
| DNS | MagicDNS only | No local or public DNS records |
| Not used | Own domain, Traefik, Gateway API, cert-manager (and so CNPG's Barman Cloud backup plugin), MetalLB, metrics-server, Prometheus, Renovate, vzdump | Not needed for a tailnet-only `ts.net` setup |

---

## 1. Design summary

### Resources (single Proxmox node: 20 cores, 16 GB RAM)

| VM | vCPU | RAM | Disk | Role |
|---|---|---|---|---|
| Proxmox host overhead | – | ~2 GB | – | |
| Existing Docker VM | as is | as is | – | Rollback until the migration and a restore drill are proven |
| `talos-cp-1` | 2 | 4 GB | 20 GB | Control plane, **on the tailnet** |
| `talos-w-1` | 2 | **4 GB** | 30 GB | All workloads and data (LAN only): EPHEMERAL ≤ 15 GiB, local-path user volume ≥ 10 GiB |

Expected worker usage: the Tailscale operator and Vaultwarden's proxy pod about 150–200 MB, local-path about 20 MB, Vaultwarden 64–256 MB, CNPG operator 128–256 MB, PostgreSQL 512 MB (fixed, Guaranteed QoS), the nightly backup job about 100 MB while it runs, Flux 300–500 MB. That's **roughly 1.3–1.9 GB of about 3.5 GB available to pods**. Set memory requests and limits on everything. The control plane keeps its `NoSchedule` taint, so all of this runs on the worker.

### Network

| Address | Use |
|---|---|
| `10.220.20.56` | `talos-cp-1`: DHCP reservation for its Proxmox-generated MAC |
| `10.220.20.57` | `talos-w-1`: DHCP reservation for its Proxmox-generated MAC |
| `talos-cp-1.<tailnet>.ts.net` | Talos API (50000) and Kubernetes API (6443) over the tailnet |
| `vault.<tailnet>.ts.net` | Vaultwarden (443, Tailscale-issued certificate) |

Place the two reservations wherever the router requires them: outside the dynamic pool on OPNsense or pfSense, inside it on some consumer routers.

### Stack

| Layer | Choice |
|---|---|
| OS | Talos, **Nocloud** image. Control plane schematic: `qemu-guest-agent` + `tailscale`. Worker schematic: `qemu-guest-agent` |
| Container networking | Flannel (Talos default) |
| Storage | local-path-provisioner |
| Database | CloudNativePG operator + one PostgreSQL 18 instance |
| Exposure and TLS | Tailscale Kubernetes operator |
| GitOps | Flux + SOPS/age, repo **`homelab`** |
| Backups | Nightly CronJob (`pg_dump` + `/data`) → off-host storage |

### Repository layout

```
homelab/
├── .sops.yaml
├── talos/
│   ├── patches/
│   │   ├── common.yaml               # kubelet node IP subnet
│   │   ├── talos-cp-1.yaml           # hostname, installer image, cert SANs, etcd subnet
│   │   ├── talos-cp-1.sops.yaml      # Tailscale auth key (encrypted)
│   │   └── talos-w-1.yaml            # hostname, installer image, local-path user volume
│   └── secrets.sops.yaml
├── tofu/                             # OpenTofu: Proxmox VMs, Talos config, OS upgrades (Phase 7)
├── clusters/homelab/                 # Flux: flux-system/ (bootstrap), infrastructure.yaml, apps.yaml
├── infrastructure/
│   ├── local-path-provisioner/
│   ├── tailscale-operator/           # Namespace, HelmRepository, HelmRelease, OAuth secret (SOPS)
│   └── cnpg/                         # Namespace, HelmRepository, HelmRelease
└── apps/
    └── vaultwarden/                  # ImageCatalog, Cluster, Deployment, PVC, Service, Ingress, Secret, backup CronJob
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
- [ ] Install `talosctl`, `kubectl`, `helm`, `k9s`, `flux`, `sops`, `age` and the `kubectl cnpg` plugin (same version as the operator, see Phase 2).
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
talosctl gen config homelab https://10.220.20.56:6443 --with-secrets secrets.yaml
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

export TALOSCONFIG=$PWD/talosconfig   # every talosctl call below uses it; ~/.talos/config stays empty
chmod 600 talosconfig
talosctl config endpoint talos-cp-1.<tailnet>.ts.net   # redo after every `gen config --force`, which resets it
talosctl config node 10.220.20.56
talosctl bootstrap        # ONCE, control plane only
talosctl kubeconfig
kubectl config set-cluster homelab --server=https://talos-cp-1.<tailnet>.ts.net:6443
kubectl get nodes -o wide
talosctl -n 10.220.20.57 version     # the worker is reached through the control plane, no tailnet needed on it
```

The cluster endpoint stays `10.220.20.56` for internal traffic. Only the workstation uses the tailnet name, and the cert SANs make that name valid for TLS.

> If `talos-cp-1` never appears on the tailnet, open its Proxmox console. The Talos dashboard shows the IP it received, whether the install finished, and Tailscale errors such as a bad auth key.

### Step 4: Clean up

Once both nodes are `Ready`, Talos keeps its config on its own disk, so remove the plaintext configs from the Proxmox host, detach the cloud-init drives and the ISO, and encrypt the Talos secrets:
```bash
ssh pve 'rm /var/lib/vz/snippets/talos-cp-1.yaml /var/lib/vz/snippets/talos-w-1.yaml
         qm set 201 --delete ide0,cicustom,ide2
         qm set 202 --delete ide0,cicustom,ide2'
sops -e --filename-override secrets.sops.yaml secrets.yaml > secrets.sops.yaml   # rules match the output name, not secrets.yaml
cmp <(sops -d secrets.sops.yaml) secrets.yaml && rm secrets.yaml
```

**Done when:**
- [ ] `kubectl get nodes -o wide` shows both nodes `Ready`, with `INTERNAL-IP` set to the **10.220.20.x** addresses (not 100.x)
- [ ] `talosctl health`, `talosctl dashboard` and `kubectl` work from the workstation over the tailnet
- [ ] The snippets are deleted, the cloud-init drives and ISO are detached, and `secrets.yaml` is encrypted

---

## 4. Phase 2: Platform

### 4.0 Give the worker 4 GB of RAM
With CloudNativePG, the worker needs about 1.3–1.9 GB for pods (see the budget in section 1), so 2 GB is no longer enough. Shut down gracefully, then resize:
```bash
talosctl -n 10.220.20.57 shutdown
ssh pve 'qm set <worker-vmid> --memory 4096 --balloon 0 && qm start <worker-vmid>'
kubectl get node talos-w-1 -o jsonpath='{.status.capacity.memory}'
```

### 4.1 local-path-provisioner
Gives the cluster a default StorageClass: each PVC becomes a directory under `/var/mnt/local-path-provisioner` (the Talos user volume on the worker). `infrastructure/local-path-provisioner/kustomization.yaml` pulls the pinned upstream manifest and patches it to:
- label the namespace `pod-security.kubernetes.io/enforce=privileged` (Talos's baseline policy blocks the hostPath helper pods otherwise),
- use the user-volume path instead of `/opt/local-path-provisioner` (read-only on Talos),
- make `local-path` the default StorageClass with `reclaimPolicy: Retain`.

```bash
kubectl apply -k infrastructure/local-path-provisioner
kubectl -n local-path-storage rollout status deploy/local-path-provisioner
kubectl get storageclass          # local-path (default)
```

Test it:
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: test-pvc}
spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 100Mi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: test-pod}
spec:
  containers:
    - name: c
      image: busybox
      command: [sh, -c, "echo hello > /data/hi && sleep 3600"]
      volumeMounts: [{name: d, mountPath: /data}]
      securityContext: {allowPrivilegeEscalation: false, runAsNonRoot: true, runAsUser: 1000, capabilities: {drop: [ALL]}, seccompProfile: {type: RuntimeDefault}}
  volumes: [{name: d, persistentVolumeClaim: {claimName: test-pvc}}]
EOF
kubectl get pvc test-pvc          # Pending until the pod is scheduled, then Bound
kubectl exec test-pod -- cat /data/hi
kubectl delete pod test-pod && kubectl delete pvc test-pvc
kubectl get pv                    # Retain leaves the PV "Released"; delete it by hand
```

> ℹ️ local-path doesn't enforce PVC sizes. A volume can grow until the user volume is full, so watch `df` in `talosctl dashboard` rather than relying on the requested size.

**Done when:** the test PVC binds once the pod uses it and the file is readable.

### 4.2 Tailscale Kubernetes operator
Store the OAuth client ID and secret (shown only once) in your password manager **and** SOPS-encrypted in the repo. Create the file inside the `sops` editor so the plaintext never touches disk:
```bash
sops infrastructure/tailscale-operator/operator-oauth.sops.yaml
```
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: operator-oauth
  namespace: tailscale
stringData:
  client_id: <id>
  client_secret: <secret>
```
Create the Secret yourself and install the chart **without** `oauth.*` values. The chart then uses the existing `operator-oauth` Secret, so the secret stays out of shell history and out of Helm's release record. Flux uses the same file in Phase 5.
```bash
kubectl create namespace tailscale
kubectl label ns tailscale pod-security.kubernetes.io/enforce=privileged
sops -d infrastructure/tailscale-operator/operator-oauth.sops.yaml | kubectl apply -f -
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm upgrade --install tailscale-operator tailscale/tailscale-operator -n tailscale
```
> ⚠️ The operator creates its proxy pods in the `tailscale` namespace, and they need privileged access. Without the label they're silently rejected.

**Done when:** `tailscale-operator` appears as a device in the admin console, tagged `tag:k8s-operator`.

### 4.3 CloudNativePG operator
The operator watches `Cluster` resources and runs PostgreSQL for them: it creates the instance pod and PVC, the database and its owner, the credentials Secret, TLS certificates (its own CA, no cert-manager needed), and the `-rw` Service. Install it with the official Helm chart, **pinned**, in its own namespace, with resource limits. In Phase 5 the same values move into `infrastructure/cnpg/release.yaml`.
```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 \
  -n cnpg-system --create-namespace \
  --set resources.requests.cpu=50m --set resources.requests.memory=128Mi \
  --set resources.limits.memory=256Mi                                    # chart 0.29.1 = operator 1.30.1
kubectl -n cnpg-system rollout status deploy/cnpg-cloudnative-pg
kubectl get crd | grep postgresql.cnpg.io
```
Install the `kubectl cnpg` plugin at the **same version** as the operator (CloudNativePG docs → kubectl plugin). It provides `kubectl cnpg status` and `kubectl cnpg psql`.

The chart installs the CRDs. The operator and its pods comply with the `restricted` Pod Security profile, so `cnpg-system` needs no label.

**Done when:** the operator Deployment is ready and `kubectl cnpg version` matches its version.

---

## 5. Phase 3: Migrate Vaultwarden to Kubernetes

A direct migration: stop the Docker service, move its data into the cluster, switch the clients. Vaultwarden is down from step 4 until step 9, typically 30–60 minutes. The Docker VM, its MariaDB and its data stay untouched, so rolling back means starting the old container again.

### 5.1 Facts about production

Vaultwarden **1.37.4**; database is a **native MariaDB 10.11.19** on the Docker VM (`127.0.0.1:3306`), the same major version the Vaultwarden wiki tested pgloader with. Data folder: `/root/vaultwarden/vaultwarden-data`. Current URL: `https://vaultwarden.<tailnet>.ts.net` (Tailscale Serve).

### 5.2 Settings from `compose.yml`

| Compose | Kubernetes |
|---|---|
| `image: vaultwarden/server:latest` | `1.37.4`, pinned on both sides; upgrade only after the migration |
| `DOMAIN` | `env`: `https://vault.<tailnet>.ts.net` |
| `SIGNUPS_ALLOWED=true` | `env: "false"`; invite users from `/admin` |
| `DATABASE_URL` | `env` from the CNPG Secret `vaultwarden-db-app`, key `uri` |
| `ADMIN_TOKEN` | `vaultwarden-secrets` (SOPS). Generate a **new** argon2 hash with `docker exec -it vaultwarden /vaultwarden hash`; write it with single `$` (the `$$` escaping is Compose-only). Save the password you typed in your password manager |
| `TZ=Asia/Jerusalem` | `env` |
| `ROCKET_ADDRESS=127.0.0.1` | **Drop.** Bound to localhost, the Service can't reach the pod |
| `ROCKET_PORT=8080` | Drop (default 80 matches the Service) |
| `LOG_FILE` | Drop; logs go to stdout (`kubectl logs`) |
| `RUST_BACKTRACE`, `EXTENDED_LOGGING`, `ENABLE_WEBSOCKET`, `LOG_LEVEL=info` | Drop (debug or already the default) |
| `restart`, `container_name`, `network_mode: host` | Not needed |

Don't save settings on the `/admin` settings pages afterwards: that writes `config.json`, which overrides the `env` values from git.

### 5.3 PostgreSQL with CloudNativePG: choices

| Practice | Here | Why |
|---|---|---|
| Image pinned **by digest** through an `ImageCatalog` | Official `minimal` image, Debian trixie, PostgreSQL **18** | Reproducible; a patch update is a one-line commit. `minimal`/`standard` images replace the deprecated `system` images |
| Application owns its database | `initdb` creates database `vaultwarden` owned by `vaultwarden`; the app reads the generated `vaultwarden-db-app` Secret | No database password to create or store; superuser access stays disabled (default) |
| Connect through the `-rw` Service | `vaultwarden-db-rw.vaultwarden:5432` (in the Secret's `uri`) | Always points at the primary |
| **Guaranteed QoS** (requests = limits) and `shared_buffers` ≈ 25 % of memory | 500m CPU, 512 Mi, `shared_buffers: 128MB` | Postgres is never the first pod evicted under memory pressure |
| `wal_level: replica` | Set explicitly | CNPG defaults to `logical`; nothing here needs logical replication, so this cuts WAL volume |
| TLS | On by default (operator-managed CA) | libpq's default `sslmode=prefer` encrypts the connection |
| Data checksums | On by default in PostgreSQL 18 | Detects storage corruption |

**Deliberate deviations** (single node, small homelab):

| Best practice | Deviation | Consequence |
|---|---|---|
| 3 instances across nodes | `instances: 1` | No automatic failover; a worker outage is a database outage |
| PodDisruptionBudgets on | `enablePDB: false` | CNPG docs: required for single-instance clusters, otherwise the node can't be drained (Talos upgrades hang) |
| Separate WAL volume (`walStorage`) | One volume | Same disk underneath and local-path doesn't enforce sizes, so a split adds nothing |
| Physical backups: Barman Cloud plugin, WAL archiving, PITR | Nightly logical dump (Phase 4) | No cert-manager; restores go back to the last dump, not to any second |
| Monitoring with `PodMonitor` | `kubectl cnpg status` | No Prometheus in this cluster |
| `NetworkPolicy` limiting who can reach Postgres | None | Flannel doesn't enforce NetworkPolicy |

### 5.4 Manifests (`apps/vaultwarden/`)

| File | Contents |
|---|---|
| `namespace.yaml` | Namespace `vaultwarden` (Talos default `baseline` Pod Security: Vaultwarden runs as root, the CNPG pods meet `restricted`) |
| `postgres.yaml` | `ImageCatalog` (PostgreSQL 18 by digest) and `Cluster` `vaultwarden-db` with the settings in 5.3 |
| `pvc.yaml` | `vaultwarden-data`, 1 Gi: `rsa_key*`, `attachments/`, `sends/` |
| `deployment.yaml` | Vaultwarden `1.37.4`, **`replicas: 0`** (scaled by hand during the migration), `Recreate`, `DATABASE_URL` from `vaultwarden-db-app` |
| `service.yaml` | Port 80 |
| `ingress.yaml` | `ingressClassName: tailscale`, tag `tag:password-manager`, host `vault` → `https://vault.<tailnet>.ts.net` |
| `kustomization.yaml` | Lists the files above, **not** the secret: `kubectl apply -k` doesn't decrypt, so the secret is applied by hand until Flux (Phase 5) does it |
| `vaultwarden-secrets.sops.yaml` | `ADMIN_TOKEN`, encrypted |

### 5.5 Migration, step by step

**Step 1: Prepare the Docker VM** (no downtime)
```bash
# compose.yml: image: vaultwarden/server:1.37.4
docker compose up -d                                   # same version, nothing changes
cat /root/vaultwarden/vaultwarden-data/config.json     # if it exists, remove keys now set by env (domain, admin_token, signups_allowed, ...)
docker exec -it vaultwarden /vaultwarden hash          # new admin token for the cluster
```

**Step 2: Before you start** (no downtime)
- [ ] Export the vault: web vault → Tools → Export vault → `.json (Encrypted)`. Keep it off the cluster.
- [ ] No tailnet device is already named `vault` (otherwise the proxy becomes `vault-1`).
- [ ] If you use a **security key or passkey (WebAuthn)** for two-step login: it's tied to the domain and won't work on the new URL. Make sure an authenticator app or the recovery code works; re-register the key afterwards.
- [ ] If the tailnet policy isn't allow-all: your user may reach `tcp:443` on `tag:password-manager`.
- [ ] Warn other users of the vault about the downtime.

**Step 3: Deploy the database and the app at 0 replicas** (no downtime)
```bash
sops apps/vaultwarden/vaultwarden-secrets.sops.yaml     # ADMIN_TOKEN: '$argon2id$...'
kubectl apply -k apps/vaultwarden
sops -d apps/vaultwarden/vaultwarden-secrets.sops.yaml | kubectl apply -f -
kubectl cnpg status vaultwarden-db -n vaultwarden       # wait for "Cluster in healthy state"
kubectl -n vaultwarden get ingress vaultwarden          # the "vault" device appears in the admin console
```

**Step 4: Stop the old service** (downtime starts)
```bash
# Docker VM. MariaDB keeps running; nothing writes to it any more.
docker compose stop vaultwarden
tailscale serve reset          # or remove only Vaultwarden's handler if Serve fronts other services
```
Never run both at once, or the data diverges.

**Step 5: Copy `/data`**
```bash
# Docker VM
tar -czf /root/vw-data.tgz -C /root/vaultwarden/vaultwarden-data \
  --exclude='vaultwarden.log' --exclude='icon_cache' --exclude='db.sqlite3*' .
# copy /root/vw-data.tgz to the workstation (scp over the tailnet), then on the workstation:
kubectl -n vaultwarden run restore --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"d","persistentVolumeClaim":{"claimName":"vaultwarden-data"}}],"containers":[{"name":"restore","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"d","mountPath":"/data"}]}]}}'
kubectl -n vaultwarden wait --for=condition=Ready pod/restore
kubectl cp vw-data.tgz vaultwarden/restore:/data/
kubectl -n vaultwarden exec restore -- sh -c 'tar -xzf /data/vw-data.tgz -C /data && rm /data/vw-data.tgz && ls -la /data'
kubectl -n vaultwarden delete pod restore
```
Expect `rsa_key.pem` (without it every client is logged out), `attachments/`, `sends/`, and `config.json` if you kept one.

**Step 6: Let Vaultwarden create the empty schema, then stop it**
```bash
kubectl -n vaultwarden scale deploy/vaultwarden --replicas=1
kubectl -n vaultwarden rollout status deploy/vaultwarden
kubectl -n vaultwarden logs deploy/vaultwarden | head -30    # migrations ran, no errors; don't log in
kubectl -n vaultwarden scale deploy/vaultwarden --replicas=0
```

**Step 7: Copy the database with pgloader** (Vaultwarden wiki, "Using the PostgreSQL Backend" → "Migrating from MySQL to PostgreSQL"). MariaDB listens only on `127.0.0.1` on the Docker VM, so bring PostgreSQL to the VM through two tunnels:
```bash
# Workstation, terminal 1
kubectl -n vaultwarden port-forward svc/vaultwarden-db-rw 15432:5432
# Workstation, terminal 2: makes 127.0.0.1:15432 on the VM reach the port-forward
ssh -R 15432:127.0.0.1:15432 <docker-vm>
# Workstation, terminal 3: the Postgres password for the load file
kubectl -n vaultwarden get secret vaultwarden-db-app -o jsonpath='{.data.password}' | base64 -d; echo
```
On the Docker VM, with the MariaDB user and password from the production `DATABASE_URL`:
```bash
umask 077; mkdir -p /root/pgloader && cat > /root/pgloader/vaultwarden.load <<'EOF'
load database
     from mysql://vaultwarden:<mariadb-password>@127.0.0.1:3306/vaultwarden
     into postgresql://vaultwarden:<pg-password>@127.0.0.1:15432/vaultwarden
     WITH data only
     EXCLUDING TABLE NAMES MATCHING '__diesel_schema_migrations'
     ALTER SCHEMA 'vaultwarden' RENAME TO 'public'
;
EOF
docker run --rm --network host -v /root/pgloader:/work dimitri/pgloader:latest pgloader /work/vaultwarden.load
rm -rf /root/pgloader
```
Warnings are normal; errors usually mean an old pgloader. Close the two tunnels afterwards.

**Step 8: Compare row counts** (MariaDB on the VM vs. PostgreSQL). Every count must match:
```sql
SELECT 'users', COUNT(*) FROM users UNION ALL SELECT 'ciphers', COUNT(*) FROM ciphers
UNION ALL SELECT 'folders', COUNT(*) FROM folders UNION ALL SELECT 'attachments', COUNT(*) FROM attachments
UNION ALL SELECT 'sends', COUNT(*) FROM sends UNION ALL SELECT 'organizations', COUNT(*) FROM organizations
UNION ALL SELECT 'twofactor', COUNT(*) FROM twofactor UNION ALL SELECT 'devices', COUNT(*) FROM devices;
```
```bash
mysql -u vaultwarden -p vaultwarden                                  # VM: paste the query
kubectl cnpg psql vaultwarden-db -n vaultwarden -- -d vaultwarden    # cluster: paste the query
```

**Step 9: Start Vaultwarden and test it in a private browser window** (downtime ends)
```bash
kubectl -n vaultwarden scale deploy/vaultwarden --replicas=1
kubectl -n vaultwarden logs -f deploy/vaultwarden
```
- [ ] `https://vault.<tailnet>.ts.net` loads (the first request can take up to a minute while the certificate is issued)
- [ ] Login works with your two-step method, the item count matches, an attachment opens
- [ ] `/admin` accepts the new admin token

**Step 10: Switch the clients.** In the browser extension, phone apps and desktop app: log out, set the server URL to `https://vault.<tailnet>.ts.net`, log in.

**Step 11: Test everything**
- [ ] Extension autofill on a real site, phone sync
- [ ] A new item appears live on a second client (WebSockets through the proxy)
- [ ] The URL does **not** resolve from a device outside the tailnet
- [ ] Re-register a WebAuthn key or passkey, if you use one
- [ ] In `deployment.yaml`, change `replicas: 0` to `replicas: 1` and commit. Otherwise the next `kubectl apply -k` scales Vaultwarden back to 0

**Step 12: Keep the old VM, its MariaDB and its data untouched for 2–4 weeks.** Set up backups (Phase 4) right away.

### 5.6 If something goes wrong

**Roll back** (any step): `kubectl -n vaultwarden scale deploy/vaultwarden --replicas=0`, then on the Docker VM `docker compose start vaultwarden` and restore its Serve config. Clients that were already switched go back to `https://vaultwarden.<tailnet>.ts.net`. Anything saved on the cluster in between is lost.

**Retry the data load** (steps 5–8) from an empty database:
```bash
kubectl -n vaultwarden scale deploy/vaultwarden --replicas=0
kubectl -n vaultwarden delete cluster vaultwarden-db     # its PVC goes too; Retain keeps the PV as "Released"
kubectl get pv | grep vaultwarden-db                     # delete that PV by hand
kubectl apply -k apps/vaultwarden && kubectl cnpg status vaultwarden-db -n vaultwarden
```
Then clear `/data` before copying it again (in the `restore` pod: `rm -rf /data/* /data/.[!.]*`).

**Done when:** steps 9 and 11 pass and every client uses `https://vault.<tailnet>.ts.net`.

---

## 6. Phase 4: Backups and restore drill (right after the migration)

- [ ] **Nightly CronJob** in `vaultwarden` with `ttionya/vaultwarden-backup` (supports PostgreSQL up to 18): `pg_dump` of the database plus `/data` (`rsa_key*`, `attachments/`, `sends/`, `config.json`), zipped with a password and sent off-host with rclone (B2, NAS, etc.).
  - `DB_TYPE=postgresql`, `PG_HOST=vaultwarden-db-rw`, `PG_DBNAME=vaultwarden`, `PG_USERNAME=vaultwarden`, `PG_PASSWORD` from `vaultwarden-db-app` (key `password`).
  - `ZIP_PASSWORD` and the rclone config go in a SOPS-encrypted Secret. Keep the zip password in your password manager **and somewhere outside it**.
  - It can mount the same RWO `/data` PVC because there's only one worker.
- [ ] **Restore drill**, timed. Until it has worked, the old Docker VM is your only proven fallback, so don't retire it before this.
  1. Note the item count, then `kubectl delete ns vaultwarden` and delete the `Released` PVs it leaves behind.
  2. `kubectl apply -k apps/vaultwarden` and the secret, then **immediately** `kubectl -n vaultwarden scale deploy/vaultwarden --replicas=0`. The new database needs about a minute to initialise, so Vaultwarden can't create its schema first; check its logs to be sure.
  3. Restore the dump into the empty database and `/data` into the PVC with the backup image's restore command. **Don't start Vaultwarden before the dump is restored:** the dump contains the schema, and a pre-created schema conflicts with it.
  4. Scale to 1 and run the step 9 checks.

**Done when:** a restore from the off-host backup has worked at least once.

---

## 7. Phase 5: GitOps (Flux)

Flux runs in the cluster, pulls `homelab` from GitHub and makes the cluster match it. Afterwards, every change goes through git: a manual `kubectl edit` is reverted at the next sync. `talos/` stays manual (`talosctl`).

### Files in the repo

| Path | Contents |
|---|---|
| `clusters/homelab/flux-system/` | Written by `flux bootstrap` (Flux's own manifests and the git sync) |
| `clusters/homelab/infrastructure.yaml` | Flux `Kustomization` → `./infrastructure`: `prune`, `wait`, SOPS decryption with `sops-age` |
| `clusters/homelab/apps.yaml` | Flux `Kustomization` → `./apps`, same settings, `dependsOn: infrastructure` (the CNPG CRDs must exist before the `Cluster`) |
| `infrastructure/kustomization.yaml` | `local-path-provisioner`, `tailscale-operator`, `cnpg` |
| `infrastructure/cnpg/` | `Namespace`, `HelmRepository`, `HelmRelease` `cnpg` (chart `0.29.1`, the former `values.yaml` inline) |
| `infrastructure/tailscale-operator/` | `Namespace` with the `privileged` label, `operator-oauth.sops.yaml`, `HelmRepository`, `HelmRelease` `tailscale-operator` (chart `1.104.1`, no values) |
| `apps/kustomization.yaml` | `vaultwarden` |
| `apps/vaultwarden/` | Now also lists `vaultwarden-secrets.sops.yaml`. The `Cluster` and the PVC carry `kustomize.toolkit.fluxcd.io/prune: disabled`, so Flux never deletes them, even if they disappear from git |

The `HelmRelease`s use the **same release names, namespaces, chart versions and values** as the manual installs, so helm-controller upgrades the existing releases in place: nothing restarts, and `helm history` shows a new revision instead of a second install.

### Step 1: Prerequisites
```bash
flux version --client      # v2.9.6
flux check --pre
```
Create a GitHub **fine-grained token**, limited to `homelab`, with **Contents: read/write** and **Administration: read/write** (to add the deploy key), expiring in 1 day. Bootstrap needs it once; afterwards Flux uses a read-only SSH deploy key.
```bash
read -s GITHUB_TOKEN && export GITHUB_TOKEN
```

### Step 2: Give Flux the age key (before bootstrap, so the first sync can decrypt)
```bash
kubectl create namespace flux-system
kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```
The only secret that never goes into git; recreate it by hand after a cluster rebuild.

### Step 3: Bootstrap
```bash
git push                   # the files above must be on GitHub first
flux bootstrap github \
  --owner=tapuaharel --repository=homelab --personal --private=true \
  --branch=main --path=clusters/homelab
git pull                   # bootstrap pushed clusters/homelab/flux-system/
unset GITHUB_TOKEN         # and delete the token on GitHub
```
Bootstrap installs the controllers in `flux-system`, commits their manifests, adds the deploy key and starts syncing `clusters/homelab/`, which pulls in `infrastructure.yaml` and `apps.yaml`.

### Step 4: Watch the takeover
```bash
flux get kustomizations --watch     # flux-system → infrastructure → apps reach Ready=True
flux get helmreleases -A            # cnpg, tailscale-operator: Ready
helm history cnpg -n cnpg-system    # a new revision by Flux, not a fresh install
kubectl -n vaultwarden get pods     # no unexpected restarts
```
If something isn't Ready: `flux get kustomizations` (the message), `flux logs --level=error`, `kubectl -n cnpg-system describe helmrelease cnpg`. Typical causes: a missing `sops-age` Secret ("failed to decrypt"), a wrong path, a chart version that doesn't exist.

### Step 5: Prove it
```bash
kubectl -n vaultwarden delete deploy vaultwarden
flux reconcile kustomization apps --with-source
kubectl -n vaultwarden get deploy                   # back
kubectl -n vaultwarden scale deploy/vaultwarden --replicas=0
flux reconcile kustomization apps                   # back to 1: git wins
```
Check worker RAM in `talosctl -n 10.220.20.57 dashboard`; the Flux controllers add about 300–500 MB.

### Day to day

| You want to... | Do this |
|---|---|
| Change anything | Edit, commit, push; `flux reconcile kustomization <name> --with-source` to apply now |
| See what Flux does | `flux get all -A`, `flux events`, `flux tree kustomization apps` |
| Change something by hand temporarily | `flux suspend kustomization apps` … `flux resume kustomization apps` (reverts to git) |
| Upgrade an operator | Bump `version:` in its `release.yaml` |
| Upgrade Flux | New CLI, run the same `flux bootstrap` again |

> ⚠️ `prune: true` deletes objects whose files are removed from git. The `Cluster` and the Vaultwarden PVC are protected by the annotation; anything else you remove from git really goes.

**Done when:** all three Kustomizations and both HelmReleases are Ready, and the deleted Deployment comes back on its own.

---

## 8. Phase 6: Drills

| Drill | What you learn |
|---|---|
| `talosctl upgrade` each node **with its own installer image** (control plane: the tailscale schematic) | Immutable OS upgrades; the extension survives the upgrade. The worker drain works because the PDB is off |
| `talosctl upgrade-k8s` | Kubernetes version upgrades |
| CNPG operator upgrade (bump the chart version in git) | Operator upgrades restart the instance: a short database outage with one instance |
| PostgreSQL minor update (new digest in the `ImageCatalog`) | How CNPG rolls out a new image |
| Delete both VMs, recreate them (Phase 0), re-run Phase 1 steps 2–4, let Flux rebuild, and restore the backup | Whether everything can be rebuilt from the repo and backups alone |

---

## 9. Phase 7: Manage the Talos layer with OpenTofu

OpenTofu takes over the Proxmox VMs, the Talos machine configs and OS upgrades. The patches in `talos/` stay the source of truth. Tofu reads `talos/secrets.sops.yaml` and the Tailscale patch through SOPS on every run, and passes them on only through ephemeral resources and write-only arguments, so the state file holds no secrets. If the state is lost, re-run the imports in step 3.

| Tofu resource | Replaces |
|---|---|
| `proxmox_virtual_environment_vm` (imported) | The `qm set` commands in Phase 0 |
| `talos_machine` | `talosctl machineconfig patch` + `apply-config`, and `talosctl upgrade` (changing `image` upgrades the node) |
| `talos_machine_bootstrap` (imported) | `talosctl bootstrap` |

Kubernetes upgrades stay manual: run `talosctl upgrade-k8s`, then bump `kubernetes_version` in `tofu/talos.tf` to match.

### Step 1: Prerequisites

- [ ] Install OpenTofu ≥ 1.11.
- [ ] Create a Proxmox user and API token for OpenTofu. On the Proxmox host, as root:
  ```bash
  # On PVE 8, use VM.Monitor instead of VM.GuestAgent.Audit
  pveum role add OpenTofu -privs "VM.Audit VM.Allocate VM.PowerMgmt VM.GuestAgent.Audit \
    VM.Config.CPU VM.Config.Memory VM.Config.Disk VM.Config.Network VM.Config.Options \
    VM.Config.HWType VM.Config.CDROM Datastore.Audit Datastore.AllocateSpace SDN.Audit SDN.Use Sys.Audit"
  pveum user add opentofu@pve
  pveum acl modify / -user opentofu@pve -role OpenTofu
  pveum user token add opentofu@pve homelab --privsep 0   # prints the secret once
  ```
  Then export the token on the workstation:
  ```bash
  export PROXMOX_VE_ENDPOINT=https://<pve-address>:8006/
  export PROXMOX_VE_API_TOKEN='opentofu@pve!homelab=<secret>'
  ```
- [ ] `cd tofu && tofu init`, then commit `.terraform.lock.hcl`.

### Step 2: Check that the generated config matches the running nodes

`talos_machine` applies config in `AUTO` mode and has no dry-run, so the first apply must not change anything. `talosctl` uses the same config generator as the provider, so a dry-run with the same inputs shows what the first apply would do:
```bash
cd talos
talosctl gen config homelab https://10.220.20.56:6443 --with-secrets <(sops -d secrets.sops.yaml) \
  --talos-version v1.14 --kubernetes-version v1.37.1 --output-types controlplane -o - \
| talosctl machineconfig patch /dev/stdin --patch @patches/common.yaml --patch @patches/talos-cp-1.yaml \
    --patch @<(sops -d patches/talos-cp-1.sops.yaml) \
| talosctl -n 10.220.20.56 apply-config --dry-run --file /dev/stdin

talosctl gen config homelab https://10.220.20.56:6443 --with-secrets <(sops -d secrets.sops.yaml) \
  --talos-version v1.14 --kubernetes-version v1.37.1 --output-types worker -o - \
| talosctl machineconfig patch /dev/stdin --patch @patches/common.yaml --patch @patches/talos-w-1.yaml \
| talosctl -n 10.220.20.57 apply-config --dry-run --file /dev/stdin
```
Both must report no changes. If a field differs, pin it in a patch or in `tofu/talos.tf` before going on.

### Step 3: Import

```bash
cd tofu
tofu plan -generate-config-out=vms.tf   # writes the VM blocks from what Proxmox reports
```
Edit `vms.tf`: drop read-only and default-valued attributes, and add `lifecycle { prevent_destroy = true }` to both VMs. Repeat `tofu plan` until it shows only the three imports and two `talos_machine` creates.

### Step 4: First apply

```bash
tofu apply -parallelism=1
```
`talos_machine` has no import, so this "creates" it by applying the config checked in step 2. The running image already matches, so no upgrade runs. Afterwards, delete `imports.tf`, check that `tofu plan` reports no changes, and commit.

**Done when:**
- [ ] `tofu plan` reports no changes
- [ ] A test edit to a patch shows up in `tofu plan` (then revert it)
- [ ] `tofu show` contains no keys or tokens

### Day to day

| You want to... | Do this |
|---|---|
| Change a Talos patch | Edit, `tofu apply -parallelism=1`, commit |
| Upgrade Talos (Renovate PR) | Merge, pull, `tofu apply -parallelism=1`: drains, upgrades and reboots each node in turn |
| Upgrade Kubernetes | `talosctl upgrade-k8s --to <version>`, then bump `kubernetes_version` and `tofu apply` |
| Resize a VM | Edit `vms.tf`, `tofu apply` |

> ⚠️ Never set `on_destroy { reset = true }` on `talos_machine`. Without it, removing the resource leaves the node running.

> ℹ️ Rebuilding from empty VMs isn't automated through cloud-init. A snippet would hold the full machine config, and the Proxmox provider can't upload it without writing it to state. New VMs boot into maintenance mode instead, and `talos_machine` configures them over the LAN. That apply must run from a machine on `10.220.20.0/24`, with `endpoint` set to each node's IP.
