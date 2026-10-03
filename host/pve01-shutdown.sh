#!/bin/bash
# pve01's half of the shutdown runbook (#58): dockerhost has docker/scripts/maintenance/
# prep-shutdown.sh + verify-boot.sh (docker#23, thread 015); this is the same pair for the vault.
# Runs on dockerhost, through Peter's verbs only (bin/pve01 read-only, bin/k3s). It STOPS NOTHING:
# the host shutdown itself stays Brandon's, and pve-guests stops VMs 201-203 gracefully on the way down.
#
#   pve01-shutdown.sh prep      SAFE, or what it's waiting on / blocked by. Saves a snapshot.
#   pve01-shutdown.sh verify    after boot: compares pve01 with the newest snapshot. CLEAN BOOT or one line per problem.
#   WAIT=600 (verify: seconds to wait for VMs/cluster/apps)  SNAP_ROOT=... (default: ~/projects/Proxmox/logs)
# Exit codes: 0 SAFE / CLEAN BOOT, 1 BLOCKED / problems found, 3 WAITING ON (prep: try again later).

set -uo pipefail
AB=/home/brandon/projects/agent-bus
SNAP_ROOT="${SNAP_ROOT:-/home/brandon/projects/Proxmox/logs}"
pve() { "$AB/bin/pve01" "$@" 2>&1 | grep -v '^tput:'; }
k3s() { "$AB/bin/k3s" "$@" 2>&1 | grep -v '^tput:'; }
say() { echo "[$(date +%H:%M:%S)] $*"; }

# pve01's local mounts, from the `mounts` table (the cifs shares are automounts: not up until touched).
local_mounts() { awk '$1 ~ /^\/dev\// && $NF ~ /^\/mnt\// {print $NF}' | sort -u; }
mem_total() { awk '/^Mem:/{print $2; exit}'; }
running_vms() { awk '$3=="running"{print $1}'; }
apps_bad() { awk 'NR>1 && ($2!="Synced" || $3!="Healthy"){print $1" "$2"/"$3}'; }
nodes_bad() { awk 'NR>1 && $2!="Ready"{print $1" "$2}'; }

prep() {
    local busy=() blockers=() warnings=()
    # 1. Work in flight: a restic run, a Dagu step talking to pve01, or the nightly backup window.
    pve restic log documents | grep -E '^peter-restic-.*\.service +loaded +active' | awk '{print "restic: "$1}' > /tmp/pve01-busy.$$
    pgrep -af 'ssh pve01 ' | grep -vE '^[0-9]+ (bash|sh) ' | awk '{$1=""; print "dagu job:"$0}' | cut -c1-120 >> /tmp/pve01-busy.$$
    mapfile -t busy < /tmp/pve01-busy.$$; rm -f /tmp/pve01-busy.$$
    # 02:30 vzdump k3s-nightly-fenway, 03:00 restic, 03:30 pictures copy + Sun vzdump to boston, Sun 04:00 restore test.
    local hm; hm=$(date +%H%M)
    [ "$hm" -ge 0215 ] && [ "$hm" -le 0430 ] && busy+=("backup window: 02:15-04:30 runs vzdump, restic and the pictures copy")
    if [ "${#busy[@]}" -gt 0 ]; then
        echo "WAITING ON:"; printf '  %s\n' "${busy[@]}"
        echo "NOT SAFE YET. Try again when these are done."; return 3
    fi

    local snap; snap="$SNAP_ROOT/pve01-shutdown-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$snap"
    say "snapshot -> $snap"
    pve vms        > "$snap/vms.txt"
    pve mounts     > "$snap/mounts.txt"
    pve health     > "$snap/health.txt"
    pve restic snapshots > "$snap/restic-snapshots.txt"
    k3s 'sudo kubectl get nodes --no-headers=false' > "$snap/nodes.txt"
    k3s 'sudo kubectl get applications -n argocd' > "$snap/apps.txt"
    k3s 'sudo kubectl get pods -A --no-headers' | awk '$4!="Running" && $4!="Completed"' > "$snap/pods-bad-before.txt"
    say "VMs running: $(running_vms < "$snap/vms.txt" | tr '\n' ' ')· RAM: $(mem_total < "$snap/health.txt")"

    # 2. What's already wrong, so the reboot isn't blamed for it afterwards.
    [ -s "$snap/pods-bad-before.txt" ] && warnings+=("pods not Running before shutdown: $(awk '{print $1"/"$2}' "$snap/pods-bad-before.txt" | tr '\n' ' ')")
    [ -n "$(nodes_bad < "$snap/nodes.txt")" ] && warnings+=("k3s nodes not Ready before shutdown: $(nodes_bad < "$snap/nodes.txt" | tr '\n' ' ')")
    [ -n "$(apps_bad < "$snap/apps.txt")" ] && warnings+=("Argo apps not Synced/Healthy before shutdown: $(apps_bad < "$snap/apps.txt" | tr '\n' ' ')")
    [ -z "$(running_vms < "$snap/vms.txt")" ] && warnings+=("no VMs running: nothing to compare after boot")
    for m in /mnt/beacon /mnt/brighton /mnt/fenway; do
        local_mounts < "$snap/mounts.txt" | grep -qx "$m" || blockers+=("$m is not mounted now: fix that before adding a reboot to it")
    done
    # A network share in fstab without nofail can hold up or fail the boot if its server is away.
    grep -E '^//.*credentials=' "$snap/mounts.txt" | grep -v nofail | awk '{print $2}' | while read -r t; do echo "$t"; done > "$snap/fstab-no-nofail.txt"
    [ -s "$snap/fstab-no-nofail.txt" ] && warnings+=("fstab share without nofail (boot may wait on it): $(tr '\n' ' ' < "$snap/fstab-no-nofail.txt")")

    # 3. The newest documents snapshot should be from the last 26 h (a fresh copy before the box goes dark).
    local last; last=$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$snap/restic-snapshots.txt" | sort | tail -n 1)
    if [ -z "$last" ] || [ $(( $(date +%s) - $(date -d "$last" +%s) )) -gt 93600 ]; then
        warnings+=("newest restic documents snapshot is ${last:-missing}, over 26h old: run bin/pve01 restic backup documents")
    else
        say "restic documents: newest snapshot $last"
    fi

    { printf 'blockers:\n'; printf '  %s\n' "${blockers[@]:-none}"
      printf 'warnings:\n'; printf '  %s\n' "${warnings[@]:-none}"; } > "$snap/verdict.txt"
    ln -sfn "$snap" "$SNAP_ROOT/pve01-shutdown-latest"
    echo
    for w in "${warnings[@]}"; do echo "WARN: $w"; done
    if [ "${#blockers[@]}" -gt 0 ]; then
        for b in "${blockers[@]}"; do echo "BLOCKED: $b"; done
        echo "NOT SAFE TO SHUT DOWN (snapshot kept: $snap)"; return 1
    fi
    echo "SAFE TO SHUT DOWN. Snapshot: $snap"
    echo "On pve01, as root:  shutdown -h now     (pve-guests stops VMs $(running_vms < "$snap/vms.txt" | tr '\n' ' ')gracefully first)"
    echo "After boot, from dockerhost:  ~/projects/Proxmox/host/pve01-shutdown.sh verify"
}

verify() {
    local snap="$SNAP_ROOT/pve01-shutdown-latest" problems=() wait="${WAIT:-300}"
    [ -d "$snap" ] || { echo "no snapshot at $snap: nothing to compare against (run prep before a shutdown)"; return 1; }
    say "comparing with $(readlink -f "$snap")"
    local h; h=$(pve health)
    [ -n "$h" ] && echo "$h" | grep -q pve01 || { echo "PROBLEM: pve01 doesn't answer bin/pve01 health"; return 1; }
    say "uptime:$(echo "$h" | grep -oE 'up [^,]+')  RAM: $(mem_total < "$snap/health.txt") -> $(echo "$h" | mem_total)"

    # 1. Storage first: the backup disks.
    local now_m; now_m=$(pve mounts | local_mounts)
    for m in $(local_mounts < "$snap/mounts.txt"); do
        echo "$now_m" | grep -qx "$m" || problems+=("$m is not mounted (was before shutdown)")
    done

    # 2-4. VMs, nodes, apps: retry for $wait seconds, they come up in that order.
    local start; start=$(date +%s); local vm_bad nodes apps
    while :; do
        vm_bad=$(comm -23 <(running_vms < "$snap/vms.txt" | sort) <(pve vms | running_vms | sort))
        nodes=""; apps=""
        if [ -z "$vm_bad" ]; then
            nodes=$(k3s 'sudo kubectl get nodes' | nodes_bad)
            apps=$(k3s 'sudo kubectl get applications -n argocd' | apps_bad)
        fi
        [ -z "$vm_bad$nodes$apps" ] && break
        [ $(( $(date +%s) - start )) -ge "$wait" ] && break
        sleep 20
    done
    for v in $vm_bad; do problems+=("VM $v is not running (was before shutdown)"); done
    [ -n "$nodes" ] && problems+=("k3s nodes not Ready: $(echo "$nodes" | tr '\n' ' ')")
    [ -n "$apps" ]  && problems+=("Argo apps not Synced/Healthy: $(echo "$apps" | tr '\n' ' ')")
    local pods; pods=$(k3s 'sudo kubectl get pods -A --no-headers' | awk '$4!="Running" && $4!="Completed"{print $1"/"$2}' \
        | grep -vxFf <(awk '{print $1"/"$2}' "$snap/pods-bad-before.txt") )
    [ -n "$pods" ] && problems+=("pods not Running (were fine before): $(echo "$pods" | tr '\n' ' ')")

    echo
    if [ "${#problems[@]}" -gt 0 ]; then printf 'PROBLEM: %s\n' "${problems[@]}"; return 1; fi
    echo "CLEAN BOOT"
}

case "${1:-}" in
    prep) prep ;;
    verify) verify ;;
    *) echo "usage: $0 prep|verify" >&2; exit 2 ;;
esac
