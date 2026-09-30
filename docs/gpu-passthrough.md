# RTX 3070 passthrough to DockerHost (VM 101)

Step-by-step, in order. Every command is Brandon's to run; Paul (host) and Dakota (guest/Docker)
check between steps. Each phase has a **check** and a **rollback**. Don't start a phase until the
previous one's check passes, and don't put two phases in one window unless it says so.

Sources: bmbell23/docker#2 (Bianca's scoping, 2026-09-28), agent-bus threads 014 and 015,
proxmox#14. Facts below are as of those dates; phase 0 re-checks the ones that move.

## What we know
- Host `proxmox`: i7-8700K, ASUS PRIME Z370-A (BIOS 0606, UEFI), 31 GB RAM, PVE 9.0.3.
- GPU at `01:00.0` (RTX 3070, `10de:2484`) and `01:00.1` (HDMI audio, `10de:228b`).
- Already on the host from an earlier attempt: `intel_iommu=on` in `/etc/default/grub`, vfio modules,
  `/etc/modprobe.d/vfio-pci.conf` with `ids=10de:2484,10de:228b`, nouveau/nvidia blacklisted.
- **The blocker:** VT-d is off in the BIOS. `/sys/kernel/iommu_groups` is empty, so any `hostpci`
  line makes VM 101 fail to start. That's what "bricked" it last time.
- VM 101: SeaBIOS, i440fx, 24 GB, CPU `x86-64-v2-AES`, NIC `ens18` static via netplan.
  **Stay on i440fx/SeaBIOS.** q35 renames the NIC and takes dockerhost off the network.
- Guest: `nvidia-dkms-570` built, `nvidia-container-toolkit` installed, Docker has only `runc`.

## Prerequisites (separate windows, before any GPU work)
One change per window, so if something breaks we know what did it.

### P1. CPU type (VM stop/start, ~2 min of container downtime)
Needed anyway: ML wheels want AVX/AVX2, and `x86-64-v2-AES` has neither. On proxmox, as root:
```
qm config 101 | grep -E '^cpu'      # expect: cpu: x86-64-v2-AES
qm set 101 --cpu host
qm shutdown 101 --timeout 300       # a reboot inside the guest does NOT apply a CPU change
qm status 101                       # stopped
qm start 101
qm agent 101 ping && echo agent-ok
```
Check (in dockerhost): `grep -o -w avx2 /proc/cpuinfo | head -1` prints `avx2`, then Dakota's `verify-boot`.
Rollback: `qm set 101 --delete cpu`, same stop/start.
Note: the queued `discard=on,ssd=1` disk changes also apply on this stop/start (thread 015). Harmless.

### P2. Disk space on dockerhost (no downtime)
Root disk was 89–90% full (9.7–12 GB free). Driver/CUDA images and models must not land on `/`.
Check: `df -h / /mnt/docker`: `/` under 80%, models planned for `/mnt/docker`. Dakota's lane.

### P3. Host updates (host reboot, all VMs down)
323 pending packages, including the PVE 9.0 → 9.1 path. Do them in their own window, with their own
reboot, before the GPU. A GPU fault after a kernel update would be impossible to pin on either.
Check after: `bin/proxmox health` (kernel, `pveversion`), `bin/proxmox errors 2h`, VM 101 back with `verify-boot`.

### P4. Memory headroom
Passthrough pins all of VM 101's RAM (24 GB) on a 31 GB host, and the host was already 5.2 GB into
swap (09-29). Check `free -h` on the host after P3. If swap is still in use, drop VM 101 to 20 GB
(`qm set 101 --memory 20480`, applied on the next stop/start) before phase 3.

## Phase 0. Backup and prep (no downtime)
1. Fresh backup of 101 (about 25 min, ~106 GB), to boston and, once PBS is up, to pve01's `fenway`:
   `vzdump 101 --mode snapshot --compress zstd --storage boston_backups --remove 0` (`--remove 0`: don't let it prune the Sunday dumps)
2. **Prove it.** Restore one file from it (or Peter's VM 901 test restore on pve01 reaches a login).
   An untested backup is a guess.
3. Make the HDMI audio function go to vfio-pci, not `snd_hda_intel`:
   ```
   grep -q 'softdep snd_hda_intel' /etc/modprobe.d/vfio-pci.conf || \
     echo 'softdep snd_hda_intel pre: vfio-pci' >> /etc/modprobe.d/vfio-pci.conf
   update-initramfs -u -k all
   ```
4. Plug a monitor into the **motherboard** HDMI (the iGPU) so the host console stops using the 3070.
5. Run `prep-shutdown` in dockerhost; confirm no agent turns in flight.

Rollback: nothing changed that matters until the reboot.

## Phase 1. BIOS (host reboot, all VMs down ~10 min, at the keyboard)
1. `qm shutdown 101 --timeout 300`, then shut the host down from the PVE UI (node → Shutdown).
2. In BIOS: Advanced → System Agent (SA) Configuration → **VT-d = Enabled**.
   Advanced → System Agent → Graphics Configuration → **Primary Display = CPU Graphics** (iGPU), and
   **iGPU Multi-Monitor = Enabled** if offered.
3. Boot. VM 101 starts on its own (`onboot: 1`).

Check, on proxmox:
```
ls /sys/class/iommu                        # dmar0 (and maybe dmar1)
dmesg | grep -i -e DMAR -e 'IOMMU enabled' | head
lspci -nnk -s 01:00                        # "Kernel driver in use: vfio-pci" on BOTH .0 and .1
for g in /sys/kernel/iommu_groups/*; do echo "group ${g##*/}: $(ls $g/devices)"; done | grep 01:00
```
The 3070's group should hold only `01:00.0` and `01:00.1` (plus, at most, the PCIe root port
`00:01.0`, which is fine). If other devices share it, **stop** and tell Paul: that needs a different slot
or ACS override, and we decide that together.

Rollback: VT-d off again in BIOS. No VM config has changed yet.

## Phase 2. Give the GPU to VM 101 (VM stop/start, ~2 min)
```
qm shutdown 101 --timeout 300
qm set 101 --hostpci0 0000:01:00          # both functions; keep i440fx/SeaBIOS, no pcie=1, no x-vga
qm start 101
qm agent 101 ping && echo agent-ok
```
Check (in dockerhost): `nvidia-smi` shows the RTX 3070; `ip -br a` still shows `ens18` with 10.0.0.160;
`verify-boot` is clean.
Rollback: `qm shutdown 101; qm set 101 --delete hostpci0; qm start 101`.
If VM 101 won't start at all: the rollback above, then `journalctl -b | grep -i vfio` on proxmox for Paul.

## Phase 3. Docker GPU runtime (dockerd restart, every container bounces; its own window, Dakota's lane)
In dockerhost, after `prep-shutdown`:
```
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
docker info | grep -i runtimes            # nvidia listed
docker run --rm --gpus all nvidia/cuda:12.8.0-base-ubuntu24.04 nvidia-smi
```
Check: `verify-boot` clean (containers come back on their own via `unless-stopped`).
Rollback: restore `/etc/docker/daemon.json` from the `.bak` nvidia-ctk leaves, restart docker.

## Phase 4. Use it
A local image service (ComfyUI/diffusers, models on `/mnt/docker`) is a separate ticket in its
owner's repo. Not part of this runbook.

## After each window
- Paul: `bin/proxmox errors 2h`, `bin/proxmox health`, and note the outcome in agent-bus thread 014.
- If it isn't written down, it didn't happen.
