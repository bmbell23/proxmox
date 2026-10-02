# Metrics exporters on the Proxmox host (#42, Brandon as root on Proxmox, once)

Prometheus lives on dockerhost (Dakota's `docker/monitoring/`). Thread 018 has the plan. The host gets
two small exporters, plus a read-only API token so pve-exporter can read VM and backup state:

| What | Where it runs | Port | Gives |
|---|---|---|---|
| `prometheus-node-exporter` | Proxmox host | 9100 | CPU, RAM, swap, filesystems, network |
| `prometheus-smartctl-exporter` | Proxmox host | 9633 | SMART health, reallocated sectors, temps for every drive |
| pve-exporter | **dockerhost** (container, Dakota's) | 9221 | VMs, storage, backup jobs, via the API token below |

pve-exporter runs on dockerhost, not here: it's a pip package, and pip on a hypervisor is how you get a
host nobody can upgrade. All the host needs for it is a user that can look and can't touch.

Both exporters are bound to the LAN IP (10.0.0.159), so they're not on Tailscale. They only serve
read-only metrics.

## 0. Fix apt first
`apt-get update` has failed every night since at least Sep 30 (`pveupdate ... exit code 100` in
`bin/proxmox errors 3d`), so nothing installs until it's fixed. Find out why:
```bash
apt-get update 2>&1 | grep -E '^(Err|E:|W:)'
```
If it's `401 Unauthorized` from `enterprise.proxmox.com` (no subscription), switch off the enterprise
repos and use no-subscription, same as pve01 (#21). PVE 9 uses deb822 `.sources` files:
```bash
ls /etc/apt/sources.list.d/
for f in $(grep -ls 'enterprise.proxmox.com' /etc/apt/sources.list.d/*.sources); do
  grep -qi '^Enabled: *false' "$f" || sed -i '/^Types:/a Enabled: false' "$f"; echo "disabled $f"; done
grep -rqs 'pve-no-subscription' /etc/apt/sources.list.d/ || cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
apt-get update        # must end with no Err/E: lines
```
If the error is something else, stop and paste it to Paul.

**This only refreshes the package lists. Don't run `apt upgrade` as part of this job.** Upgrades are their own job, with a backup first.

## 1. node_exporter (Debian trixie main, 1.9.0)
`--no-install-recommends` skips `prometheus-node-exporter-collectors`, which would add its own systemd
timers to the host.
```bash
apt-get install -y --no-install-recommends prometheus-node-exporter
sed -i 's|^ARGS=.*|ARGS="--web.listen-address=10.0.0.159:9100"|' /etc/default/prometheus-node-exporter
grep ^ARGS /etc/default/prometheus-node-exporter
systemctl restart prometheus-node-exporter
systemctl is-active prometheus-node-exporter
```

## 2. smartctl_exporter (trixie-backports, 0.14.0)
It isn't in trixie main, so add backports and pin the install to it. Backports packages are only
installed when you ask for them with `-t`, so nothing else on the host changes.
```bash
cat > /etc/apt/sources.list.d/debian-backports.sources <<'EOF'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
apt-get update
apt-get install -y -t trixie-backports prometheus-smartctl-exporter
sed -i 's|^ARGS=.*|ARGS="--web.listen-address=10.0.0.159:9633"|' /etc/default/prometheus-smartctl-exporter
grep ^ARGS /etc/default/prometheus-smartctl-exporter    # if there's no ARGS line, add that one
systemctl restart prometheus-smartctl-exporter
systemctl is-active prometheus-smartctl-exporter
```

## 3. Read-only API user for pve-exporter
```bash
pveum user add prometheus@pve --comment "read-only metrics, proxmox#42"
pveum acl modify / --users prometheus@pve --roles PVEAuditor
pveum user token add prometheus@pve monitoring --privsep 0
pveum user permissions prometheus@pve | grep -v Audit   # should list only paths, no privileges other than *.Audit
```
`token add` prints the secret **once**. It goes into the secret file Dakota names for her pve-exporter
container on dockerhost, and nowhere else (not chat, not a repo). `--privsep 0` means the token
gets the user's rights, which are PVEAuditor (look, don't touch).

## 4. Check (Paul can run these from dockerhost)
```bash
curl -s 10.0.0.159:9100/metrics | grep -m1 '^node_load1'
curl -s 10.0.0.159:9633/metrics | grep -c '^smartctl_device_smart_status'   # one per drive: expect 6 (nvme0n1, sda-sde per `bin/proxmox disks`)
```
If the count is 0, or the two USB Passports (sdd, sde) are missing, read `journalctl -u prometheus-smartctl-exporter -n 30`: it needs to be able to
open `/dev/sd*` (Debian's unit should handle that, but it isn't verified here).

If the curls time out, check the PVE firewall with `pve-firewall status`. If it's enabled, allow 9100 and
9633 from 10.0.0.160 only.

## Rollback
```bash
apt-get purge -y prometheus-node-exporter prometheus-smartctl-exporter
rm /etc/apt/sources.list.d/debian-backports.sources && apt-get update
pveum user delete prometheus@pve       # also removes its token
```
