#!/bin/bash
# Join k3s02 / k3s03 to the k3s01 cluster as servers (embedded etcd), bmbell23/proxmox#28. Peter runs, per node:
#   bin/k3s 'sudo K3S_TOKEN=<from k3s01: sudo cat /var/lib/rancher/k3s/server/token> bash -s' < k3s/join-server.sh
# The token never lands in this repo. Safe to re-run: a node at the pinned version is left alone.
set -euo pipefail
K3S_VERSION=v1.36.5+k3s1          # keep in step with install-server.sh
: "${K3S_TOKEN:?K3S_TOKEN from k3s01 is required}"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
name=$(hostname)
case "$name" in k3s02|k3s03) ;; *) echo "this is $name, not k3s02/k3s03; refusing" >&2; exit 1 ;; esac
ip="10.0.0.20${name: -1}"

install -d -m 755 /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<CFG
# Written by bmbell23/proxmox k3s/join-server.sh; edit there, not here.
server: https://10.0.0.201:6443
node-name: ${name}
node-ip: ${ip}
tls-san:
  - 10.0.0.201
  - 10.0.0.202
  - 10.0.0.203
write-kubeconfig-mode: "0600"
CFG
install -m 600 /dev/null /etc/rancher/k3s/token && printf '%s\n' "$K3S_TOKEN" > /etc/rancher/k3s/token
echo "token-file: /etc/rancher/k3s/token" >> /etc/rancher/k3s/config.yaml

have=$(k3s --version 2>/dev/null | awk 'NR==1 {print $3}' || true)
if [ "$have" = "$K3S_VERSION" ]; then echo "k3s $have already installed"
else curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server; fi

for _ in $(seq 30); do k3s kubectl get node "$name" 2>/dev/null | grep -qw Ready && break; sleep 5; done
k3s kubectl get nodes -o wide
