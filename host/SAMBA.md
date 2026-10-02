# Samba shares refuse a missing disk (#5, Brandon as root on Proxmox, once)

`[boston]` (sda1 → `/mnt/boston`) and `[external]` (sdd1 → `/mnt/external`) sit on `nofail` mounts.
If a disk doesn't come up, smbd serves the empty directory underneath, on `pve-root` (81.9G), and
dockerhost writes onto `/` until it fills: the Jan 7 2026 incident again. The fix makes smbd check
the path is a real mountpoint before each connect. `nofail` stays, so a dead disk still can't hang the boot.

## 1. Update Paul's dispatcher (adds the read-only `samba` verb)
```bash
install -m 755 -o root -g root /home/brandon/projects/Proxmox/host/paul-dispatch /usr/local/sbin/paul-dispatch
```
(Or `scp` it from dockerhost, as in [SETUP.md](SETUP.md) step 2.) From dockerhost, `bin/proxmox samba`
now prints `testparm -s` and whether every share path is mounted. Take a "before" copy:
```bash
~/projects/agent-bus/bin/proxmox samba > /tmp/agentbus/paul/samba-before.txt
```

## 2. Add the guard to both shares
```bash
cp -a /etc/samba/smb.conf /etc/samba/smb.conf.bak-$(date +%F)
```
Then, in `/etc/samba/smb.conf`, inside **both** the `[boston]` and `[external]` blocks:
```
   root preexec = /usr/bin/mountpoint -q %P
   root preexec close = yes
```
`%P` is the share's path. If `mountpoint` fails, the connect is refused instead of serving a writable empty folder.
It only runs at connect time, so existing sessions (dockerhost's mount) aren't touched by the reload.

## 3. Check and reload
```bash
testparm -s 2>/dev/null | grep -A12 -E '^\[(boston|external)\]'    # both show the two lines
systemctl reload smbd
```

## 4. Verify
From dockerhost:
```bash
ls /mnt/boston >/dev/null && touch /mnt/boston/.paul-5-test && rm /mnt/boston/.paul-5-test && echo boston ok
~/projects/agent-bus/bin/proxmox samba                              # both paths "mounted"
```
Negative test on `[external]` only (nothing mounts it from dockerhost), on Proxmox:
```bash
umount /mnt/external
smbclient -N //localhost/external -c ls        # expect a refused connect (an NT_STATUS error), not an empty listing
mount /mnt/external
smbclient -N //localhost/external -c ls        # lists the disk again
```
(`-N` works while the share is still `guest ok`; after #6 use `-U brandon`.)

## Rollback
```bash
cp -a /etc/samba/smb.conf.bak-<date> /etc/samba/smb.conf && systemctl reload smbd
```
No data is touched either way.
