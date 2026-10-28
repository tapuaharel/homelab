locals {
  cluster_name = "homelab"
  cp_endpoint  = "talos-cp-1.taila07fc4.ts.net"
  talos_dir    = "${path.module}/../talos"

  nodes = {
    talos-cp-1 = { type = "controlplane", ip = "10.220.20.56" }
    talos-w-1  = { type = "worker", ip = "10.220.20.57" }
  }
}

# Secrets are read from SOPS on every run and only reach the nodes through
# ephemeral resources and write-only arguments, so they never land in state.
ephemeral "sops_file" "secrets" {
  source_file = "${local.talos_dir}/secrets.sops.yaml"
}

ephemeral "sops_file" "cp_patch" {
  source_file = "${local.talos_dir}/patches/talos-cp-1.sops.yaml"
}

locals {
  s = yamldecode(ephemeral.sops_file.secrets.raw)

  # talosctl's secrets.yaml uses different key names than the provider schema.
  machine_secrets = {
    cluster    = local.s.cluster
    trustdinfo = local.s.trustdinfo
    secrets = {
      bootstrap_token             = local.s.secrets.bootstraptoken
      secretbox_encryption_secret = local.s.secrets.secretboxencryptionsecret
    }
    certs = {
      etcd               = { cert = local.s.certs.etcd.crt, key = local.s.certs.etcd.key }
      k8s                = { cert = local.s.certs.k8s.crt, key = local.s.certs.k8s.key }
      k8s_aggregator     = { cert = local.s.certs.k8saggregator.crt, key = local.s.certs.k8saggregator.key }
      k8s_serviceaccount = { key = local.s.certs.k8sserviceaccount.key }
      os                 = { cert = local.s.certs.os.crt, key = local.s.certs.os.key }
    }
  }
}

ephemeral "talos_client_configuration" "this" {
  cluster_name    = local.cluster_name
  machine_secrets = local.machine_secrets
}

# Used to drain nodes before OS upgrades.
ephemeral "talos_cluster_kubeconfig" "this" {
  cluster_name    = local.cluster_name
  machine_secrets = local.machine_secrets
  endpoint        = "https://${local.cp_endpoint}:6443"
}

ephemeral "talos_machine_configuration" "node" {
  for_each = local.nodes

  cluster_name     = local.cluster_name
  cluster_endpoint = "https://10.220.20.56:6443"
  machine_type     = each.value.type
  machine_secrets  = local.machine_secrets
  # Config contract the cluster was created with; don't bump it on OS upgrades.
  talos_version = "v1.14"
  # Must match the running cluster. Bump it after each `talosctl upgrade-k8s`.
  kubernetes_version = "v1.37.1"

  config_patches = concat(
    [
      file("${local.talos_dir}/patches/common.yaml"),
      file("${local.talos_dir}/patches/${each.key}.yaml"),
    ],
    each.key == "talos-cp-1" ? [ephemeral.sops_file.cp_patch.raw] : [],
  )
}

# Applies the config in AUTO mode and upgrades the OS when `image` changes.
# Run applies with -parallelism=1 so upgrades go one node at a time.
# Never set on_destroy.reset: without it, destroying this resource leaves the node alone.
resource "talos_machine" "node" {
  for_each = local.nodes

  node = each.value.ip
  # The worker isn't on the tailnet; its API is reached through the control plane.
  endpoint = local.cp_endpoint

  client_configuration_wo  = ephemeral.talos_client_configuration.this.client_configuration
  machine_configuration_wo = ephemeral.talos_machine_configuration.node[each.key].machine_configuration
  kubeconfig_wo            = ephemeral.talos_cluster_kubeconfig.this.kubeconfig_raw

  # Same installer image as the patch, which Renovate bumps.
  image = regex("image: (\\S+)", file("${local.talos_dir}/patches/${each.key}.yaml"))[0]
}

resource "talos_machine_bootstrap" "this" {
  node                    = local.nodes.talos-cp-1.ip
  endpoint                = local.cp_endpoint
  client_configuration_wo = ephemeral.talos_client_configuration.this.client_configuration

  depends_on = [talos_machine.node]
}
