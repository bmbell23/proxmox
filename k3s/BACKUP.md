# k3s backups (#53)

What can't be rebuilt from git, and where its copies live. Everything in `k8s/apps/` is rebuilt by ArgoCD;
this page covers what isn't.

| What | Where (on the VMs) | Copy 1 | Copy 2 |
|---|---|---|---|
| Cluster state (etcd) | `/var/lib/rancher/k3s/server/db/` on k3s01–03; k3s snapshots it to `db/snapshots/` every 12 h, keeping 5 | nightly vzdump → `fenway-pbs` | weekly vzdump → `boston-backups` |
| CAs and keys | inside etcd, encrypted with the server token (also `server/tls/` on disk) | same | same |
| **Server token** | `/var/lib/rancher/k3s/server/token` | Vaultwarden, by hand | none: it never changes |
| PVC data (`local-path`) | `/var/lib/rancher/k3s/storage/pvc-*` on whichever node holds it | nightly vzdump → `fenway-pbs` | weekly vzdump → `boston-backups` |

fenway is on pve01's own SSD: good for "I broke it", useless if pve01 dies. boston is the proxmox host's disk,
another machine, so it covers a dead pve01 (boston has no redundancy of its own: see agent-bus thread 008).

**Status 2026-10-03:** both jobs exist (`bin/pve01 jobs`). The first fenway copy of 201–203 finished at 04:18. The weekly boston job can't write yet: pve01 mounts boston read-only (#57). Token in Vaultwarden and the restore test: still open.

## 1. The backup jobs (Brandon, root on pve01, once)
```bash
pvesh create /cluster/backup --id k3s-nightly-fenway --schedule '02:30' --vmid 201,202,203 \
  --storage fenway-pbs --mode snapshot --enabled 1 --notes-template '{{guestname}}'
pvesh create /cluster/backup --id k3s-weekly-boston --schedule 'sun 03:30' --vmid 201,202,203 \
  --storage boston-backups --mode snapshot --compress zstd --prune-backups keep-last=2 \
  --enabled 1 --notes-template '{{guestname}}'
cat /etc/pve/jobs.cfg                  # both jobs listed
vzdump 201 202 203 --storage fenway-pbs --mode snapshot   # first copy now, instead of waiting for 02:30
```
- fenway already prunes to the last 3 per VM (PBS `fenway-prune`, PVE01.md step 6), so the nightly job sets no pruning of its own.
- The VMs have no qemu-guest-agent (`systemctl is-active qemu-guest-agent`: inactive), so a snapshot backup is
  crash-consistent, like pulling the plug. etcd copes with that, and the k3s snapshot files inside are complete copies anyway.
- Size: each VM uses about 5 GB of its 40 GB disk (k3s01 `df /`: 4.9G). Expect a few GB per VM after zstd.

Check (Peter): `bin/pve01 jobs`, `bin/pve01 vzdump-logs`.

If fenway backups fail with `fingerprint … not verified`, PBS's certificate changed (the Tailscale cert, #48). Fix: `pvesm set fenway-pbs --fingerprint <sha256 of /etc/proxmox-backup/proxy.pem>`.

## 2. The server token (Brandon, once)
k3s keeps its CAs in etcd, encrypted with this token, so **restoring a snapshot without it means a new cluster**.
It's the one secret here worth a password-manager entry. On k3s01:
```bash
sudo cat /var/lib/rancher/k3s/server/token
```
Paste it into Vaultwarden as **"k3s server token (k3s01–03)"**. Peter never reads it.

## 3. Restore test (Peter, after the first backup)
k3s01's latest fenway backup is restored to a scratch VMID (291), with its NIC unplugged so it can't join the live
cluster or take 10.0.0.201. It should boot, and `k3s etcd-snapshot list` should show the snapshots. Then it's
destroyed (Brandon). The result is recorded on #53, with the date. Never run it alongside VM 901 (pve01 has 15 GiB).

## Rebuilding from scratch (outline; the runbook is #54)
1. Restore 201–203 from the newest backup (`qmrestore`, or from the PVE UI under the storage).
2. If only etcd is lost: on k3s01, `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot> --token <token>`,
   then rejoin k3s02/03 (`k3s/join-server.sh`).
