#!/bin/bash
# k3s server on k3s01 (VM 201 on pve01), bmbell23/proxmox#28. Peter runs it from dockerhost:
#   bin/k3s 'sudo bash -s' < k3s/install-server.sh
# k3s01 starts the HA cluster (embedded etcd, cluster-init). k3s02/03 join it as servers (k3s/join-server.sh).
# Safe to re-run: an installed k3s at the pinned version is left alone. Change the version here, in a PR.
set -euo pipefail
K3S_VERSION=v1.36.5+k3s1          # stable channel, 2026-10-01
NODE_IP=10.0.0.201

[ "$(id -u)" = 0 ] || { echo "run as root (sudo bash -s)" >&2; exit 1; }
[ "$(hostname)" = k3s01 ] || { echo "this is $(hostname), not k3s01; refusing" >&2; exit 1; }

install -d -m 755 /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<CFG
# Written by bmbell23/proxmox k3s/install-server.sh; edit there, not here.
cluster-init: true
node-name: k3s01
node-ip: ${NODE_IP}
tls-san:
  - ${NODE_IP}
  - k3s01
  - 10.0.0.202
  - 10.0.0.203
write-kubeconfig-mode: "0600"
CFG

have=$(k3s --version 2>/dev/null | awk 'NR==1 {print $3}' || true)
if [ "$have" = "$K3S_VERSION" ]; then echo "k3s $have already installed"
else
  apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
fi

for _ in $(seq 30); do k3s kubectl get node k3s01 2>/dev/null | grep -qw Ready && break; sleep 5; done
k3s kubectl get nodes -o wide

# Smoke test: one pod runs, then goes away.
k3s kubectl run smoke --image=busybox:1.36 --restart=Never --command -- echo k3s-ok >/dev/null
k3s kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/smoke --timeout=120s
k3s kubectl logs smoke
k3s kubectl delete pod smoke --wait=false >/dev/null
