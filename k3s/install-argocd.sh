#!/bin/bash
# ArgoCD on the k3s01-03 cluster, bmbell23/proxmox#46. Peter runs, from dockerhost:
#   bin/k3s 'sudo bash -s' < k3s/install-argocd.sh
# After this, merged main IS the deploy: ArgoCD syncs k8s/apps/* from this repo (k8s/argocd/apps.yaml).
# Pinned chart; change it here, in a PR. Safe to re-run. Needs helm (k3s/install-rancher.sh installs it).
set -euo pipefail
ARGOCD_CHART_VERSION=10.9.6
ARGOCD_HOST=argocd.10.0.0.201.sslip.io
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(hostname)" = k3s01 ] || { echo "this is $(hostname), not k3s01; refusing" >&2; exit 1; }
command -v helm >/dev/null || { echo "no helm: run k3s/install-rancher.sh first" >&2; exit 1; }

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update >/dev/null
# TLS ends at Traefik's door on the LAN, so the server runs plain HTTP behind it.
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version "$ARGOCD_CHART_VERSION" \
  --set 'configs.params.server\.insecure=true' \
  --set server.ingress.enabled=true --set server.ingress.ingressClassName=traefik \
  --set server.ingress.hostname="$ARGOCD_HOST" \
  --set global.domain="$ARGOCD_HOST" --wait --timeout 10m

# The one hand-applied object: the root app. Everything else comes from git.
if apps=$(curl -sfL https://raw.githubusercontent.com/bmbell23/proxmox/main/k8s/argocd/apps.yaml); then
  kubectl apply -f - <<<"$apps"
else echo "k8s/argocd/apps.yaml isn't on main yet: apply it from the branch once (#46)"; fi
kubectl -n argocd get pods -o wide
kubectl -n argocd get applications
echo "ArgoCD: http://$ARGOCD_HOST"
