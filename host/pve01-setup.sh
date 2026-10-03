#!/bin/bash
# pve01 setup (#11, #13). Brandon runs it as root on pve01, from the /opt/homelab clone:
#   git -C /opt/homelab pull --ff-only && bash /opt/homelab/host/pve01-setup.sh          # every step, in order
#   bash /opt/homelab/host/pve01-setup.sh samba                                          # one step
# Every step checks first and skips what's already done, so it's safe to run again. Nothing here
# deletes data. The VM restore test stays manual: PVE01.md step 7.
set -euo pipefail
REPO=/opt/homelab
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(hostname)" = pve01 ] || { echo "this is $(hostname), not pve01" >&2; exit 1; }

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
skip() { echo "   already done: $*"; }
loud() { printf '\n\033[1;33m%s\033[0m\n' "$*"; }
fstab_has() { grep -qE "^[^#]*[[:space:]]$1[[:space:]]" /etc/fstab; }
# Installing proxmox-backup-server adds its enterprise repo, which answers 401 without a subscription and
# makes every apt-get update fail (#21). We use pbs-no-subscription, so switch the enterprise one off first.
apt_update() {
  local f
  for f in $(grep -ls 'enterprise.proxmox.com/debian/pbs' /etc/apt/sources.list.d/* || true); do
    case "$f" in
      *.sources) grep -qi '^Enabled: *false' "$f" || { sed -i '/^Types:/a Enabled: false' "$f"; echo "   disabled $f"; } ;;
      *.list)    sed -i 's|^\([[:space:]]*deb \)|# \1|' "$f"; echo "   disabled $f" ;;
    esac
  done
  apt-get update -qq
}
# Write a sudoers file only if visudo accepts it: a broken file in sudoers.d breaks sudo for everyone.
sudoers() {
  local tmp; tmp=$(mktemp); cat > "$tmp"
  if visudo -cf "$tmp"; then install -m 440 -o root -g root "$tmp" "$1"; rm -f "$tmp"
  else rm -f "$tmp"; echo "visudo rejected the new $1; left the old one alone" >&2; exit 1; fi
}

look() {
  say "look: what's on the two data disks"
  for d in /mnt/raid1 /mnt/hdd /mnt/beacon /mnt/brighton; do
    mountpoint -q "$d" || continue
    echo "-- $d"; ls -la "$d"; du -xsh "$d"/* 2>/dev/null || true
  done
}

names() {
  say "names: md0 -> beacon, sdb1 -> brighton"
  [ -e "/etc/fstab.bak-$(date +%F)" ] || cp /etc/fstab "/etc/fstab.bak-$(date +%F)"
  local old new dev
  for pair in "/mnt/raid1 /mnt/beacon" "/mnt/hdd /mnt/brighton"; do
    read -r old new <<<"$pair"
    dev=$(findmnt -no SOURCE "$old" || findmnt -no SOURCE "$new" || true)
    [ -n "$dev" ] || { echo "neither $old nor $new is mounted; stopping" >&2; exit 1; }
    if fstab_has "$new"; then skip "$new in fstab"
    else
      fstab_has "$old" || { echo "$old isn't in fstab; stopping" >&2; exit 1; }
      mountpoint -q "$old" && umount "$old"
      # nofail: a dead backup disk must not stop pve01 from booting.
      sed -E -i "/^[[:space:]]*#/!s|[[:space:]]$old[[:space:]]+ext4[[:space:]]+defaults[[:space:]]| $new ext4 defaults,nofail |" /etc/fstab
      fstab_has "$new" || { echo "fstab edit failed for $old; backup is /etc/fstab.bak-$(date +%F)" >&2; exit 1; }
      echo "   fstab: $old -> $new"
    fi
    [ "$(e2label "$dev")" = "$(basename "$new")" ] || { e2label "$dev" "$(basename "$new")"; echo "   label $dev = $(basename "$new")"; }
    mkdir -p "$new"
    [ -d "$old" ] && ! mountpoint -q "$old" && rmdir "$old" 2>/dev/null || true
  done
  systemctl daemon-reload
  mountpoint -q /mnt/beacon   || mount /mnt/beacon
  mountpoint -q /mnt/brighton || mount /mnt/brighton
  findmnt /mnt/beacon; findmnt /mnt/brighton
}

fenway() {
  say "fenway: 300G thin volume on the SSD for PBS"
  if lvs pve/fenway >/dev/null 2>&1; then skip "LV pve/fenway"
  else lvcreate -V 300G -T pve/data -n fenway; fi
  local fs; fs=$(blkid -s TYPE -o value /dev/pve/fenway || true)
  if [ -z "$fs" ]; then mkfs.ext4 -L fenway /dev/pve/fenway
  elif [ "$fs" = ext4 ]; then skip "ext4 on fenway"
  else echo "fenway already holds $fs; not formatting it" >&2; exit 1; fi
  mkdir -p /mnt/fenway
  if fstab_has /mnt/fenway; then skip "fenway in fstab"
  else [ -z "$(tail -c1 /etc/fstab)" ] || echo >> /etc/fstab
       echo '/dev/pve/fenway /mnt/fenway ext4 defaults,discard,nofail 0 2' >> /etc/fstab; fi
  systemctl daemon-reload
  mountpoint -q /mnt/fenway || mount /mnt/fenway
  findmnt /mnt/fenway
}

tools() {
  say "tools: packages, dispatcher, Peter's restic, vm and pull verbs"
  apt_update
  apt-get install -y -qq git restic rsync samba >/dev/null
  # Symlinks into the clone, not copies (#23): a merged change is live after the next pull, with no root step.
  # That makes the clone root's code, so refuse to link if anyone but root could write to it.
  local d
  for d in "$REPO" "$REPO/host"; do
    [ "$(stat -c %U:%G "$d")" = root:root ] && [ $(( 0$(stat -c %a "$d") & 022 )) = 0 ] \
      || { echo "$d must be root:root and not group/world-writable: fix it before linking" >&2; exit 1; }
  done
  local t
  for t in paul-dispatch peter-restic peter-vm; do
    [ -x "$REPO/host/$t" ] || { echo "$REPO/host/$t missing or not executable" >&2; exit 1; }
    if [ "$(readlink "/usr/local/sbin/$t")" = "$REPO/host/$t" ]; then skip "/usr/local/sbin/$t -> $REPO/host/$t"
    else ln -sfn "$REPO/host/$t" "/usr/local/sbin/$t"; echo "   linked /usr/local/sbin/$t -> $REPO/host/$t"; fi
  done
  local forced; forced=$(grep -o 'command="[^"]*"' /home/peter/.ssh/authorized_keys 2>/dev/null | cut -d'"' -f2 || true)
  [ "$forced" = /usr/local/sbin/paul-dispatch ] && skip "peter's key runs /usr/local/sbin/paul-dispatch" \
    || loud "peter's key forces '${forced:-nothing}', not /usr/local/sbin/paul-dispatch: tell Peter"
  local line
  for line in /usr/local/sbin/peter-restic /usr/local/sbin/peter-vm "/usr/bin/git -C $REPO pull --ff-only"; do
    if grep -qF "NOPASSWD: $line" /etc/sudoers.d/peter 2>/dev/null; then skip "peter's sudoers line for $line"
    else { cat /etc/sudoers.d/peter 2>/dev/null || true
           echo "peter ALL=(root) NOPASSWD: $line"; } | sudoers /etc/sudoers.d/peter; fi
  done
}

homelab() {
  say "homelab: the user Dagu logs in as"
  id homelab >/dev/null 2>&1 && skip "user homelab" \
    || useradd --system --create-home --home-dir /var/lib/homelab --shell /bin/bash homelab
  install -d -m 700 -o homelab -g homelab /var/lib/homelab/.ssh
  local key; key=$(cat "$REPO/host/keys/dagu_ed25519.pub")
  [[ "$key" == "ssh-ed25519 "* ]] || { echo "no Dagu key in $REPO/host/keys" >&2; exit 1; }
  echo "from=\"10.0.0.160\",restrict $key" > /var/lib/homelab/.ssh/authorized_keys
  chown homelab:homelab /var/lib/homelab/.ssh/authorized_keys && chmod 600 /var/lib/homelab/.ssh/authorized_keys
  sudoers /etc/sudoers.d/homelab <<'EOF'
homelab ALL=(root) NOPASSWD: /usr/bin/git -C /opt/homelab pull --ff-only, /usr/local/sbin/peter-restic run-backup documents, /usr/local/sbin/peter-restic run-restore-test documents
EOF
  mountpoint -q /mnt/brighton || { echo "/mnt/brighton not mounted: run the names step" >&2; exit 1; }
  install -d -o homelab -g homelab /mnt/brighton/pictures
}

restic_repo() {
  say "restic: repo 'documents' on beacon"
  mountpoint -q /mnt/beacon || { echo "/mnt/beacon not mounted: run the names step" >&2; exit 1; }
  install -d -m 700 /root/.restic
  local pass=/root/.restic/documents.pass repo=/mnt/beacon/restic/documents
  if [ -s "$pass" ]; then skip "password file"
  else
    (umask 077; openssl rand -base64 32 > "$pass")
    loud "NEW restic password for 'documents'. Put it in Vaultwarden NOW (item: 'restic documents (pve01 beacon)'):"
    cat "$pass"
    loud "Without it the repo on beacon can't be read. Press Enter once it's saved."
    read -r || true
  fi
  if [ -f "$repo/config" ]; then skip "repo initialised"
  else mkdir -p /mnt/beacon/restic && restic init --repo "$repo" --password-file "$pass"; fi
}

samba() {
  say "samba: beacon and brighton, read-only, login required"
  # Backups must not be writable from the network: anything that can write here can also delete it.
  # fenway isn't shared: it only holds the PBS datastore, which you browse in PBS's web UI (:8007).
  id brandon >/dev/null 2>&1 || useradd --no-create-home --shell /usr/sbin/nologin brandon
  local conf=/etc/samba/smb.conf name
  for name in beacon brighton; do
    if grep -q "^\[$name\]" "$conf"; then skip "[$name] share"
    else printf '\n[%s]\n   path = /mnt/%s\n   read only = yes\n   browseable = yes\n   valid users = brandon\n' "$name" "$name" >> "$conf"
    fi
  done
  testparm -s >/dev/null 2>&1 || { echo "testparm failed; the shares are at the end of $conf" >&2; exit 1; }
  local users; users=$(pdbedit -L 2>/dev/null || true)
  if grep -q '^brandon:' <<<"$users"; then skip "Samba password for brandon"
  else loud "Set a Samba password for brandon (also worth a Vaultwarden entry):"; smbpasswd -a brandon; fi
  systemctl enable -q --now smbd && systemctl reload smbd
  testparm -s 2>/dev/null | grep -A4 -E '^\[(beacon|brighton)\]' || true
}

pbs() {
  say "PBS: install, datastore 'fenway', token for Proxmox VE"
  mountpoint -q /mnt/fenway || { echo "/mnt/fenway not mounted: run the fenway step" >&2; exit 1; }
  if [ ! -f /etc/apt/sources.list.d/pbs.sources ]; then
    cat > /etc/apt/sources.list.d/pbs.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    apt_update
  fi
  dpkg -s proxmox-backup-server >/dev/null 2>&1 && skip "proxmox-backup-server" || apt-get install -y proxmox-backup-server
  local pbm=proxmox-backup-manager
  if $pbm datastore list --output-format json | grep -q '"name":"fenway"'; then skip "datastore fenway"
  else
    $pbm datastore create fenway /mnt/fenway/pbs
    $pbm datastore update fenway --gc-schedule daily
  fi
  $pbm prune-job list  --output-format json | grep -q '"id":"fenway-prune"'  || $pbm prune-job create fenway-prune --store fenway --schedule daily --keep-last 3
  $pbm verify-job list --output-format json | grep -q '"id":"fenway-verify"' || $pbm verify-job create fenway-verify --store fenway --schedule weekly
  $pbm user list --output-format json | grep -q '"userid":"pve@pbs"' || $pbm user create pve@pbs
  local tokfile=/root/.pbs-fenway-token secret
  if [ -s "$tokfile" ]; then skip "token pve@pbs!vzdump"
  else
    # A token left by an earlier, interrupted run has a secret nobody saved: replace it.
    $pbm user list-tokens pve@pbs 2>/dev/null | grep -q 'pve@pbs!vzdump' && $pbm user delete-token pve@pbs vzdump
    # generate-token has no --output-format (#18); it prints JSON, spaced or not, depending on the version.
    local out; out=$($pbm user generate-token pve@pbs vzdump)
    (umask 077; sed -n 's/.*"value": *"\([^"]*\)".*/\1/p' <<<"$out" > "$tokfile")
    [ -s "$tokfile" ] || { $pbm user delete-token pve@pbs vzdump; rm -f "$tokfile"
                           echo "couldn't read the token secret; removed the token, re-run to make a new one" >&2; exit 1; }
  fi
  # A token only gets what its user also has, so both need the role.
  $pbm acl update /datastore/fenway DatastoreBackup --auth-id pve@pbs
  $pbm acl update /datastore/fenway DatastoreBackup --auth-id 'pve@pbs!vzdump'
  secret=$(cat "$tokfile")
  local fp; fp=$($pbm cert info | sed -n 's/^Fingerprint (sha256): //p')
  [ -n "$fp" ] || { echo "couldn't read PBS's certificate fingerprint" >&2; exit 1; }
  pvesm status --storage fenway-pbs >/dev/null 2>&1 && skip "storage fenway-pbs on pve01" \
    || pvesm add pbs fenway-pbs --server 127.0.0.1 --datastore fenway --username 'pve@pbs!vzdump' \
         --password "$secret" --fingerprint "$fp" --content backup
  loud "PBS token secret (pve@pbs!vzdump). Put it in Vaultwarden: 'PBS fenway token (pve01)'. It's also in $tokfile."
  echo "$secret"
  loud "Then, on proxmox as root (Paul's host), to back VM 101 up to fenway once:"
  echo "pvesm add pbs fenway-pbs --server 10.0.0.197 --datastore fenway --username 'pve@pbs!vzdump' --password '$secret' --fingerprint '$fp' --content backup"
  echo "vzdump 101 --storage fenway-pbs --mode snapshot"
}

k3s() {
  say "k3s01-03: VMs 201-203 for k3s (#17, #27), Peter's, with sudo inside them only"
  # 3 x 4 GB (balloon down to 2 GB) on a 15 GiB host: the cluster and the VM 901 restore test never run together.
  qm status 901 2>/dev/null | grep -q running && { echo "VM 901 (restore test) is running; finish it first" >&2; exit 1; }
  local gw dns bridge=vmbr0 key=/root/peter_k3s_ed25519.pub img=/var/lib/vz/import/debian-13-genericcloud-amd64.qcow2
  gw=$(ip -4 route show default | awk '{print $3; exit}')
  # The LAN gateway, not pve01's own resolver: that's Tailscale's 100.100.100.100, which the VMs can't reach (#41).
  dns=$gw
  ip link show "$bridge" >/dev/null 2>&1 || { echo "no $bridge on pve01" >&2; exit 1; }
  # The key is made on dockerhost, as brandon: cat ~/projects/agent-bus/data/keys/peter_k3s_ed25519.pub
  if [ ! -s "$key" ]; then
    loud "Paste peter_k3s_ed25519.pub from dockerhost (one line), then Enter:"
    read -r line || true
    [[ "$line" == "ssh-ed25519 "* ]] || { echo "that isn't an ed25519 public key" >&2; exit 1; }
    echo "$line" > "$key"
  fi
  mkdir -p "$(dirname "$img")"
  [ -s "$img" ] || { wget -q --show-progress -O "$img.part" \
      https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 && mv "$img.part" "$img"; }
  local n id ip name ak
  for n in 1 2 3; do
    id=20$n ip=10.0.0.20$n name=k3s0$n
    if qm status "$id" >/dev/null 2>&1; then skip "VM $id"; continue; fi
    ping -c1 -W1 "$ip" >/dev/null 2>&1 && { echo "something already answers on $ip; pick another IP and tell Peter" >&2; exit 1; }
    # Plain key: Proxmox's cloud-init field may reject authorized_keys options. Peter adds from="10.0.0.160"
    # inside each VM on his first login.
    ak=$(mktemp); cat "$key" > "$ak"
    qm create "$id" --name "$name" --memory 4096 --balloon 2048 --cores 2 --cpu host --ostype l26 \
      --net0 "virtio,bridge=$bridge" --scsihw virtio-scsi-single --serial0 socket --vga serial0 --agent enabled=1 --onboot 1
    qm set "$id" --scsi0 "local-lvm:0,import-from=$img,discard=on,ssd=1" --boot order=scsi0
    qm disk resize "$id" scsi0 40G
    # Cloud-init: user peter (NOPASSWD sudo, the Debian cloud default), Peter's key, static IP.
    qm set "$id" --ide2 local-lvm:cloudinit --ciuser peter --sshkeys "$ak" \
      --ipconfig0 "ip=$ip/24,gw=$gw" --nameserver "$dns" --searchdomain home.arpa
    rm -f "$ak"
    qm start "$id"
    echo "   $name (VM $id) starting on $ip"
  done
  echo "   gateway $gw, DNS $dns. Peter takes it from here with bin/k3s."
}

steps=(look names fenway tools homelab restic_repo samba pbs)
if [ $# -eq 0 ]; then for s in "${steps[@]}"; do "$s"; done
else
  for s in "$@"; do
    [ "$s" = restic ] && s=restic_repo
    # k3s isn't in the default run: it's asked for by name.
    printf '%s\n' "${steps[@]}" k3s | grep -qx "$s" || { echo "steps: ${steps[*]} k3s" >&2; exit 1; }
    "$s"
  done
fi
say "done. Tell Peter; he checks from dockerhost with bin/pve01."
