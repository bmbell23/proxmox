#!/bin/bash
# Helm, cert-manager and Rancher on the k3s01-03 cluster, bmbell23/proxmox#29. Peter runs, from dockerhost:
#   bin/k3s 'sudo bash -s' < k3s/install-rancher.sh
# Pinned versions; change them here, in a PR. Safe to re-run (helm upgrade --install).
# Rancher makes its own random bootstrap password. Brandon reads it, Peter doesn't (see the PR).
set -euo pipefail
HELM_VERSION=v4.3.0
CERT_MANAGER_VERSION=v1.21.2
RANCHER_VERSION=2.15.2              # chart kubeVersion < 1.37; k3s is v1.36
RANCHER_HOST=rancher.10.0.0.201.sslip.io
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(hostname)" = k3s01 ] || { echo "this is $(hostname), not k3s01; refusing" >&2; exit 1; }

if [ "$(helm version --template '{{.Version}}' 2>/dev/null || true)" != "$HELM_VERSION" ]; then
  t=$(mktemp -d); f=helm-$HELM_VERSION-linux-amd64.tar.gz
  curl -sfLo "$t/$f" "https://get.helm.sh/$f"
  echo "$(curl -sfL "https://get.helm.sh/$f.sha256sum" | awk '{print $1}')  $t/$f" | sha256sum -c -
  tar -xzf "$t/$f" -C "$t" && install -m 755 "$t/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$t"
fi
helm version --template 'helm {{.Version}}{{"\n"}}'

helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update >/dev/null
helm repo update >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --wait --timeout 10m

# Two replicas across the three nodes (Brandon, 2026-10-02: "2 nodes of rancher for HA").
helm upgrade --install rancher rancher-stable/rancher -n cattle-system --create-namespace \
  --version "$RANCHER_VERSION" --set hostname="$RANCHER_HOST" --set replicas=2 \
  --set ingress.tls.source=rancher --wait --timeout 20m
kubectl -n cattle-system rollout status deploy/rancher --timeout=10m
kubectl -n cattle-system get pods -o wide -l app=rancher
echo "Rancher: https://$RANCHER_HOST"
