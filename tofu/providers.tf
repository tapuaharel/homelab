terraform {
  required_version = ">= 1.11" # ephemeral resources and write-only arguments

  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.12.0"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.119"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.4"
    }
  }
}

# Reads PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN from the environment.
provider "proxmox" {}
