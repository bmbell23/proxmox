# backup/

Backup scripts for the Proxmox host. They're copied from `bmbell23/dotfiles` `scripts/` at 09c90ed and are byte-identical
to it (#3; agent-bus thread 012: copy, prove, then remove). The dotfiles copies stay until the parity check passes.

| script | tier | status |
|---|---|---|
| `proxmox-config-backup.sh` | 3 Infrastructure | live: Dagu `proxmox-config-backup`, 02:00 (still runs the dotfiles copy) |
| `backup-script.sh` | 1 Documents / 2 Media | legacy: target `/mnt/backups` (sdc1) is dead. Dagu `proxmox-backup-rsync` runs docker's `boston-copy.sh` instead |
| `backup-external.sh` | 2 Media | legacy: target `/mnt/external` isn't mounted |
