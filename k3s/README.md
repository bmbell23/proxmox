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
