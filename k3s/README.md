# k3s on pve01

One server node, **k3s01** (VM 201, `10.0.0.201`, Debian 13, 4 vCPU / 6 GB / 60G), made by `host/pve01-setup.sh k3s` (#27).
Peter reaches it with `agent-bus/bin/k3s` (sudo inside the VM only). The pve01 host stays read-only for him.

| step | how | ticket |
|---|---|---|
| install the server | `bin/k3s 'sudo bash -s' < k3s/install-server.sh`, then `bin/pve01 vm snapshot 201 k3sInstalled` | #28 |
| Rancher | Helm + cert-manager, once the node count is decided | #29 |
| more nodes | k3s02/k3s03 placement | #30 |
| first workload | Brandon picks | #31 |

The k3s version is pinned in `install-server.sh`. Upgrading means changing the pin in a PR, taking a VM snapshot, then re-running the script.

## Deploy notices in #infra (#51)
ArgoCD's notifications controller posts when an app under `k8s/apps/` changes. Good news comes from Biscuit, bad news from Mongo, the same split as the rest of #infra:
- Biscuit: "@brandon Deployed to k3s `<app>` (<sha>): <commit subject>" after a sync that comes up Healthy
- Mongo: "🦖 RAWR." for a failed sync (🔴) or a Degraded app (🟠)

Config lives in `install-argocd.sh`. It needs both bots' Mattermost tokens in `argocd-notifications-secret`. Brandon does this once, on k3s01:

    read -rs B; read -rs M   # paste Biscuit's token, then Mongo's
    sudo kubectl -n argocd patch secret argocd-notifications-secret --type merge \
      -p "{\"stringData\":{\"mattermost-token\":\"$B\",\"mongo-token\":\"$M\"}}"; unset B M

Then Peter re-runs `bin/k3s 'sudo bash -s' < k3s/install-argocd.sh`. Without Biscuit's token the script installs with no subscriptions, so nothing posts.
