# pve01 setup: disk names, /opt/homelab, restic, pictures copy, PBS (#11)

**Run the script, not this page.** Steps 0 to 6 are `host/pve01-setup.sh` (#13). As root on pve01:
```bash
git -C /opt/homelab pull --ff-only && bash /opt/homelab/host/pve01-setup.sh
```
It checks before each step and skips what's done, so it's safe to re-run, or run one step (`… pve01-setup.sh samba`).
It stops twice for you: the restic password and the PBS token (both go in Vaultwarden), and once for a Samba password.
This page explains what each step does. Step 7 (the VM restore test) stays manual. Nothing here deletes data.
Samba (#13): `beacon` and `brighton` are shared **read-only**, user `brandon`. Backups must not be writable from the network.

The names (Brandon, 2026-09-30):

| name | disk | mount | holds |
|---|---|---|---|
| **fenway** | SanDisk 1 TB SSD (sda, LVM `pve`) | `/mnt/fenway` (a 300G thin LV) + `local-lvm` | PBS datastore; VMs restored for testing |
| **beacon** | 2x WD 320G mirror (md0) | `/mnt/beacon` | restic repo `documents` |
| **brighton** | Hitachi 2 TB (sdb1) | `/mnt/brighton` | copy of all of `media/pictures`; restore-test scratch |

## 0. Look before touching (the two disks aren't empty)
`df` showed 19G used on `/mnt/raid1` and 26G on `/mnt/hdd` on 2026-09-30, and they were logged empty at 00:45.
Tell Peter what's there before step 1:
```bash
ls -la /mnt/raid1 /mnt/hdd; du -xsh /mnt/raid1/* /mnt/hdd/* 2>/dev/null
```

## 1. Names: labels and mountpoints for beacon and brighton
The fstab lines use UUIDs, so only the mountpoint paths change.
```bash
umount /mnt/raid1 /mnt/hdd
e2label /dev/md0 beacon
e2label /dev/sdb1 brighton
cp /etc/fstab /etc/fstab.bak-$(date +%F)
sed -i 's|/mnt/raid1|/mnt/beacon|; s|/mnt/hdd|/mnt/brighton|' /etc/fstab
mkdir -p /mnt/beacon /mnt/brighton && rmdir /mnt/raid1 /mnt/hdd
systemctl daemon-reload && mount -a && findmnt /mnt/beacon /mnt/brighton
```

## 2. fenway: a 300G thin volume on the SSD for the PBS datastore
VM 101's boot disk is 104G, so the other ~490G of the thin pool keeps room for a test restore (step 7).
```bash
lvcreate -V 300G -T pve/data -n fenway
mkfs.ext4 -L fenway /dev/pve/fenway
mkdir -p /mnt/fenway
echo '/dev/pve/fenway /mnt/fenway ext4 defaults,discard 0 2' >> /etc/fstab
systemctl daemon-reload && mount /mnt/fenway && findmnt /mnt/fenway
```

## 3. /opt/homelab, and Peter's verbs (#7, #17, #23)
The repo is public, so the clone needs no key.
```bash
apt update && apt install -y git restic rsync
git clone https://github.com/bmbell23/proxmox.git /opt/homelab
bash /opt/homelab/host/pve01-setup.sh tools
```
`tools` symlinks `paul-dispatch`, `peter-restic` and `peter-vm` from `/usr/local/sbin` into `/opt/homelab/host` (#23),
and gives peter sudo for `peter-restic`, `peter-vm` and `git -C /opt/homelab pull --ff-only`. So a merged change to any of the three
is live after the next pull: the nightly one in the 03:00 restic DAG, or Peter's `bin/pve01 pull` right after a merge.
Only changes to `pve01-setup.sh` itself (sudoers, new users, new tools) still need a root re-run.
It refuses to link unless `/opt/homelab` and `/opt/homelab/host` are `root:root` and not group/world-writable.

## 4. The `homelab` user: what Dagu logs in as
No password and no sudo beyond three exact commands. Dagu's key is `~/projects/docker/dagu/dagu_ed25519.pub` on dockerhost.
It only works from dockerhost's LAN IP, the address the Dagu container is NATed behind.
```bash
useradd --system --create-home --home-dir /var/lib/homelab --shell /bin/bash homelab
install -d -m 700 -o homelab -g homelab /var/lib/homelab/.ssh
echo 'from="10.0.0.160",restrict <PASTE dagu_ed25519.pub HERE>' > /var/lib/homelab/.ssh/authorized_keys
chown homelab:homelab /var/lib/homelab/.ssh/authorized_keys && chmod 600 /var/lib/homelab/.ssh/authorized_keys
cat > /etc/sudoers.d/homelab <<'EOF'
homelab ALL=(root) NOPASSWD: /usr/bin/git -C /opt/homelab pull --ff-only, /usr/local/sbin/peter-restic run-backup documents, /usr/local/sbin/peter-restic run-restore-test documents
EOF
chmod 440 /etc/sudoers.d/homelab && visudo -cf /etc/sudoers.d/homelab
install -d -o homelab -g homelab /mnt/brighton/pictures
```

## 5. restic repo `documents` on beacon
**The password is the only key to the repo.** Put a copy in your password manager before anything else.
If pve01's root disk dies and it's gone, beacon holds unreadable data.
Use the script: `bash /opt/homelab/host/pve01-setup.sh restic_repo`. It never replaces an existing password file
or re-inits an existing repo (#26). By hand, the same thing with the same guards:
```bash
install -d -m 700 /root/.restic
[ -s /root/.restic/documents.pass ] && echo "password file exists: NOT replacing it" \
  || { (umask 077; openssl rand -base64 32 > /root/.restic/documents.pass); cat /root/.restic/documents.pass; }   # -> password manager, now
mkdir -p /mnt/beacon/restic
[ -f /mnt/beacon/restic/documents/config ] && echo "repo exists: NOT re-initialising" \
  || restic init --repo /mnt/beacon/restic/documents --password-file /root/.restic/documents.pass
```
On 2026-09-30 the old unguarded block replaced the password of a live repo, and that copy became unreadable.
Then Peter runs the first backup, `check` and a restore test through `bin/pve01 restic …`.

## 6. PBS, with datastore `fenway`
PBS installs on top of Proxmox VE from its own repo. pve01 is PVE 9 (Debian 13 trixie), so it gets PBS 4.
```bash
cat > /etc/apt/sources.list.d/pbs.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt update && apt policy proxmox-backup-server       # expect a 4.x candidate before installing
apt install -y proxmox-backup-server
proxmox-backup-manager datastore create fenway /mnt/fenway/pbs
proxmox-backup-manager datastore update fenway --gc-schedule daily
proxmox-backup-manager prune-job create fenway-prune --store fenway --schedule daily --keep-last 3
proxmox-backup-manager verify-job create fenway-verify --store fenway --schedule weekly
proxmox-backup-manager user create pve@pbs
proxmox-backup-manager user generate-token pve@pbs vzdump    # prints the secret ONCE: keep it
proxmox-backup-manager acl update /datastore/fenway DatastoreBackup --auth-id 'pve@pbs!vzdump'
proxmox-backup-manager cert info | grep -i fingerprint
```
Add it as storage, with the secret and fingerprint from above. On **pve01**, so it can restore:
```bash
pvesm add pbs fenway-pbs --server 127.0.0.1 --datastore fenway --username 'pve@pbs!vzdump' \
  --password '<SECRET>' --fingerprint '<FINGERPRINT>' --content backup
```
On **proxmox** (Paul's host; he owns the VM backup schedule there), with pve01's address:
```bash
pvesm add pbs fenway-pbs --server 10.0.0.197 --datastore fenway --username 'pve@pbs!vzdump' \
  --password '<SECRET>' --fingerprint '<FINGERPRINT>' --content backup
vzdump 101 --storage fenway-pbs --mode snapshot      # one backup; boston stays the scheduled home
```

## 7. Restore test: run dockerhost on pve01, unplugged
The copy must not come up on the network: it would claim dockerhost's IP and Tailscale identity.
pve01 has 15 GiB of RAM (dockerhost has 24), and any PCI passthrough must go, because pve01 doesn't have that card.
```bash
pvesm list fenway-pbs                                  # the volid of the VM 101 backup
qmrestore '<VOLID>' 901 --storage local-lvm --unique 1
qm set 901 --net0 "$(qm config 901 | sed -n 's/^net0: //p'),link_down=1" --memory 8192 --onboot 0
qm config 901 | grep -E '^hostpci' && qm set 901 --delete hostpci0
qm start 901
```
Watch it boot in pve01's web console (VM 901 → Console): a login prompt means it works. Then
`qm stop 901 && qm destroy 901`.

## Check (from dockerhost)
```bash
~/projects/agent-bus/bin/pve01 mounts             # /mnt/beacon, /mnt/brighton, /mnt/fenway
~/projects/agent-bus/bin/pve01 restic snapshots   # an empty list, not "not allowed"
~/projects/agent-bus/bin/pve01 restic forget      # exit 126
```

## 8. k3s01: Peter's VM for k3s (#17)
Asked for by name, not part of the default run. Bianca's side is agent-bus #116 (`bin/k3s`, key `peter_k3s_ed25519`).
1. On dockerhost, as brandon, make the key:
   `ssh-keygen -t ed25519 -N '' -C peter-k3s@agent-bus -f ~/projects/agent-bus/data/keys/peter_k3s_ed25519`
2. On pve01, as root: `git -C /opt/homelab pull --ff-only && bash /opt/homelab/host/pve01-setup.sh tools k3s`
   It asks you to paste the `.pub` line. Then it creates VM 201 `k3s01` from the Debian 13 cloud image:
   4 cores, 6 GB, a 60G disk on `local-lvm`, starting on boot, static `10.0.0.201`.
   It stops if anything already answers on that IP, or if VM 901 (the restore test) is running.
   **Check that 10.0.0.201 is outside your router's DHCP range.**
The `peter` user inside the VM has NOPASSWD sudo. On pve01 itself Peter only gets `bin/pve01 vm …`
(`peter-vm`: status/start/shutdown/stop/snapshots, VMIDs 200-299). Creating and destroying VMs stays yours.
