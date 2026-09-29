# Proxmox VM Automation

Starter repository for creating Proxmox VMs from reusable profiles.

Current version: 0.1.0

## What this repo contains

- `create_vm_from_iso.py`: CLI that creates one or more VMs with profile defaults
- `profiles/*.json`: VM profile definitions (CPU, RAM, disk, ISO discovery, etc.)

## Quick start

Run this from a Proxmox node (where `qm` is available):

```bash
chmod +x create_vm_from_iso.py
./create_vm_from_iso.py --list-profiles
```

Dry-run first for the Ubuntu k3s node test case:

```bash
./create_vm_from_iso.py \
  --profile ubuntu-k3s-node \
  --name k3s-node \
  --count 1 \
  --dry-run
```

Create and start a single VM:

```bash
./create_vm_from_iso.py \
  --profile ubuntu-k3s-node \
  --name k3s-node \
  --start \
  --yes
```

Create a small parity set:

```bash
./create_vm_from_iso.py \
  --profile ubuntu-k3s-node \
  --name k3s-node \
  --count 3 \
  --start \
  --yes
```

Finalize an ISO install (remove installer media + boot from disk):

```bash
./create_vm_from_iso.py --finalize-vmid 100 --yes
```

Finalize and reboot immediately:

```bash
./create_vm_from_iso.py --finalize-vmid 100 --reboot --yes
```

Clone from a prebuilt template (recommended for repeatable automation):

```bash
./create_vm_from_iso.py \
  --profile ubuntu-k3s-node \
  --name k3s-node \
  --clone-from 9000 \
  --count 3 \
  --start \
  --yes
```

## Profile format

Example fields used in `profiles/ubuntu-k3s-node.json`:

- `os_family`: Optional explicit OS family (`ubuntu`, `debian`, etc.)
- `iso_storage`: Proxmox ISO storage name used by `qm set --ide2`
- `iso_match`: ISO filename pattern searched in `iso_storage` via `pvesm list`
- `iso_glob`: Optional filesystem glob fallback if you prefer path-based discovery
- `defaults`: CPU, RAM, disk, bridge, and behavior flags
- `os_overrides`: Optional per-OS settings merged after defaults

## Notes

- If `iso_match` is set, latest ISO is selected from Proxmox storage by filename sort.
- If `iso_glob` is set, latest ISO is selected by file modification time.
- If `--vmid` is omitted, script attempts `pvesh get /cluster/nextid`.
- Run with `--non-interactive` in automation pipelines.
- Use `--dry-run` to verify generated `qm` commands safely.
- After completing an ISO install, run `--finalize-vmid` to detach `ide2` and prevent `/cdrom` unmount prompts on reboot.

## Automating install steps by OS

- ISO installs are typically interactive unless you wire OS-specific unattended installers.
- Linux (Ubuntu/Debian): easiest path is install once, convert to template, then use `--clone-from`.
- Windows: usually automate via unattend/autounattend image workflow, then clone template.
- For k3s lab nodes, template cloning is usually the fastest and most reliable route.

## Commit workflow (gvc)

This repository is set up to work with your `gvc()` function from `../dotfiles`.

Prereqs:

- Run from a shell where your dotfiles are loaded, so `gvc` is available.
- Ensure `origin` is set and you have push permissions.
- Keep `version.txt` present at repo root (used by `gvc` for auto-incrementing).

Usage:

```bash
# Auto-bump patch version (e.g. 0.1.0 -> 0.1.1), commit, tag, and push
gvc "add ubuntu k3s profile defaults"

# Or set an explicit version
gvc "0.2.0" "add cloud-init support"
```

What `gvc` does in this repo:

- Updates `version.txt`
- Creates commit message in format: `vX.Y.Z: <message>`
- Creates annotated git tag: `vX.Y.Z`
- Pushes branch and tag to `origin`

## Paul (the office agent for this host)

Paul (@paul) watches this host, working read-only through `host/paul-dispatch`. His rules are in `CLAUDE.md`, and the one-time root setup is in `host/SETUP.md` (bmbell23/agent-bus#91).
