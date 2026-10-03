#!/bin/bash
# ArgoCD on the k3s01-03 cluster, bmbell23/proxmox#46. Peter runs, from dockerhost:
#   bin/k3s 'sudo bash -s' < k3s/install-argocd.sh
# After this, merged main IS the deploy: ArgoCD syncs k8s/apps/* from this repo (k8s/argocd/apps.yaml).
# Pinned chart; change it here, in a PR. Safe to re-run. Needs helm (k3s/install-rancher.sh installs it).
set -euo pipefail

# #51: what Biscuit says. Only on a real sync (oncePer the synced commit), so a merge that touches
# one app doesn't re-announce the others. Without a channel id, no subscriptions: nothing posts.
notification_values() {
  cat <<'YAML'
notifications:
  notifiers:
    service.webhook.mattermost: |
      url: __MM_URL__/api/v4
      headers:
      - name: Authorization
        value: Bearer $mattermost-token
      - name: Content-Type
        value: application/json
  triggers:
    trigger.on-deployed: |
      - description: synced and healthy, once per synced commit
        oncePer: app.status.operationState?.syncResult?.revision
        send: [app-deployed]
        when: app.status.operationState != nil and app.status.operationState.phase in ['Succeeded'] and app.status.health.status == 'Healthy'
    trigger.on-sync-failed: |
      - description: the sync itself failed
        oncePer: app.status.operationState?.syncResult?.revision
        send: [app-sync-failed]
        when: app.status.operationState != nil and app.status.operationState.phase in ['Error', 'Failed']
    trigger.on-health-degraded: |
      - description: an app went unhealthy after deploying
        send: [app-health-degraded]
        when: app.status.health.status == 'Degraded'
  templates:
    template.app-deployed: |
      webhook:
        mattermost:
          method: POST
          path: /posts
          body: |
            {"channel_id": "{{.context.mattermostChannel}}", "message": {{ printf "🚀 **k3s: %s** is live at [`%s`](https://github.com/bmbell23/proxmox/commit/%s): %s" .app.metadata.name (trunc 7 .app.status.operationState.syncResult.revision) .app.status.operationState.syncResult.revision ((call .repo.GetCommitMetadata .app.status.operationState.syncResult.revision).Message | splitList "\n" | first) | toJson }}}
    template.app-sync-failed: |
      webhook:
        mattermost:
          method: POST
          path: /posts
          body: |
            {"channel_id": "{{.context.mattermostChannel}}", "message": {{ printf "❌ **k3s: %s** sync failed at `%s`: %s ([ArgoCD](%s/applications/%s))" .app.metadata.name (trunc 7 .app.status.operationState.syncResult.revision) .app.status.operationState.message .context.argocdUrl .app.metadata.name | toJson }}}
    template.app-health-degraded: |
      webhook:
        mattermost:
          method: POST
          path: /posts
          body: |
            {"channel_id": "{{.context.mattermostChannel}}", "message": {{ printf "⚠️ **k3s: %s** is Degraded ([ArgoCD](%s/applications/%s))" .app.metadata.name .context.argocdUrl .app.metadata.name | toJson }}}
YAML
  [ -n "$MM_CHANNEL_ID" ] || return 0
  cat <<YAML
  context:
    mattermostChannel: $MM_CHANNEL_ID
  subscriptions:
    - recipients: [mattermost]
      triggers: [on-deployed, on-sync-failed, on-health-degraded]
YAML
}
ARGOCD_CHART_VERSION=10.9.6
ARGOCD_HOST=argocd.10.0.0.201.sslip.io
# #51: Biscuit announces syncs in #infra. Mattermost on dockerhost, over the LAN (Tailscale doesn't reach it from here).
MM_URL=http://10.0.0.160:8015
MM_TEAM=office
MM_CHANNEL=infra
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(hostname)" = k3s01 ] || { echo "this is $(hostname), not k3s01; refusing" >&2; exit 1; }
command -v helm >/dev/null || { echo "no helm: run k3s/install-rancher.sh first" >&2; exit 1; }

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update >/dev/null

# #51: Biscuit's bot token lives in argocd-notifications-secret (Brandon puts it there, k3s/README.md).
# The chart owns that secret with no items, so a re-run leaves his key alone. The #infra channel id
# isn't secret: look it up with the token and hand it to the templates as context.
MM_CHANNEL_ID=
if token=$(kubectl -n argocd get secret argocd-notifications-secret -o jsonpath='{.data.mattermost-token}' 2>/dev/null | base64 -d) && [ -n "$token" ]; then
  MM_CHANNEL_ID=$(curl -sf -H "Authorization: Bearer $token" "$MM_URL/api/v4/teams/name/$MM_TEAM/channels/name/$MM_CHANNEL" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') || MM_CHANNEL_ID=
fi
unset token
[ -n "$MM_CHANNEL_ID" ] || echo "no Biscuit token in argocd-notifications-secret yet: installing without deploy notices (k3s/README.md)"
# TLS ends at Traefik's door on the LAN, so the server runs plain HTTP behind it.
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --version "$ARGOCD_CHART_VERSION" \
  --set 'configs.params.server\.insecure=true' \
  --set server.ingress.enabled=true --set server.ingress.ingressClassName=traefik \
  --set server.ingress.hostname="$ARGOCD_HOST" \
  --set global.domain="$ARGOCD_HOST" \
  -f - --wait --timeout 10m <<EOF
$(notification_values | sed "s#__MM_URL__#$MM_URL#")
EOF

# The one hand-applied object: the root app. Everything else comes from git.
if apps=$(curl -sfL https://raw.githubusercontent.com/bmbell23/proxmox/main/k8s/argocd/apps.yaml); then
  kubectl apply -f - <<<"$apps"
else echo "k8s/argocd/apps.yaml isn't on main yet: apply it from the branch once (#46)"; fi
kubectl -n argocd get pods -o wide
kubectl -n argocd get applications
echo "ArgoCD: http://$ARGOCD_HOST"
