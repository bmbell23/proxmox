# Setting up Paul's access (Brandon, as root on Proxmox, once)

Paul is an agent on dockerhost. He reaches this host **only** as user `paul`, with his own key, which is
forced to run `paul-dispatch`: a fixed list of read-only verbs, with no shell. `paul` is not in `sudo`, and his one
sudoers line allows exactly two read commands. Destructive work (`qm destroy`, disks, keys) stays yours.

## 1. On dockerhost (as brandon): make Paul's key
```bash
mkdir -p ~/projects/agent-bus/data/keys && chmod 700 ~/projects/agent-bus/data/keys
ssh-keygen -t ed25519 -N '' -C paul@agent-bus -f ~/projects/agent-bus/data/keys/paul_ed25519
cat ~/projects/agent-bus/data/keys/paul_ed25519.pub     # copy this line for step 3
```
`data/` is gitignored and agents can't read it. `bin/proxmox` uses the key without showing it to them.

## 2. On Proxmox (as root): user, dispatcher, sudoers
```bash
useradd -m -s /bin/bash -G www-data,adm,systemd-journal paul     # www-data: read /etc/pve; adm/journal: logs
install -m 755 -o root -g root /home/brandon/projects/Proxmox/host/paul-dispatch /usr/local/sbin/paul-dispatch
cat > /etc/sudoers.d/paul <<'EOF'
paul ALL=(root) NOPASSWD: /usr/sbin/smartctl -H -A /dev/sd[a-z], /usr/sbin/smartctl -H -A /dev/nvme[0-9]n[0-9], /usr/sbin/qm list
EOF
chmod 440 /etc/sudoers.d/paul && visudo -cf /etc/sudoers.d/paul
```
(Once the Proxmox repo exists there, clone it to `/home/brandon/projects/Proxmox` first, or `scp` the file across.)

## 3. On Proxmox (as root): authorize the key, forced command only
```bash
install -d -m 700 -o paul -g paul /home/paul/.ssh
echo 'command="/usr/local/sbin/paul-dispatch",restrict <PASTE paul_ed25519.pub HERE>' > /home/paul/.ssh/authorized_keys
chown paul:paul /home/paul/.ssh/authorized_keys && chmod 600 /home/paul/.ssh/authorized_keys
```

## 4. Check (from dockerhost)
```bash
~/projects/agent-bus/bin/proxmox health        # works
~/projects/agent-bus/bin/proxmox bash          # "not allowed: bash", exit 126
```

## Question to decide
Does `sudo` for **brandon** on Proxmox ask for a password? If it doesn't, any process on dockerhost running as brandon
(including agents) could reach root there with `ssh proxmox sudo …`. The office policy now denies agents
`ssh … proxmox`, but that's a text rule, not a wall. A password on brandon's sudo there would be the wall.
