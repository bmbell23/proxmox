# csi-driver-smb (#74)

Lets k3s pods mount the boston share straight from Proxmox over the LAN (`//10.0.0.159/boston`),
as a dedicated Samba user. Upstream manifests: `kubernetes-csi/csi-driver-smb` `deploy/v1.20.3`, unedited.
To upgrade, replace the four files with the next `deploy/vX.Y.Z` and bump the comment in `kustomization.yaml`.

## Who logs in as what (Paul, #74)
| Samba user | Rights | Used by |
|---|---|---|
| `k3s-ro` | `read list = k3s-ro` on `[boston]`, so Samba enforces read-only | FunForge `kid-media/podcasts` |
| `k3s-rw` | read/write | FunForge `kid-media/music` (parent-mode delete), RomM `media/games` |

Nobody uses guest or `brandon`: guest goes away with #6.

## Secrets (Brandon creates them; nobody else sees the passwords)
In `kube-system`, next to the driver:
```bash
read -rsp 'k3s-ro password: ' PW; echo
sudo k3s kubectl -n kube-system create secret generic smb-boston-ro \
  --from-literal=username=k3s-ro --from-literal=password="$PW"
read -rsp 'k3s-rw password: ' PW; echo
sudo k3s kubectl -n kube-system create secret generic smb-boston-rw \
  --from-literal=username=k3s-rw --from-literal=password="$PW"
unset PW
```

## A volume for an app
Static PV + PVC, one per subdirectory, in the app's own folder. `source` takes a subdirectory, so a PV
only sees what it needs. `Retain`, never `Delete`: boston holds the only copy.
```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: funforge-podcasts
spec:
  capacity: {storage: 1Ti}            # informational; SMB doesn't enforce it
  accessModes: [ReadOnlyMany]
  persistentVolumeReclaimPolicy: Retain
  mountOptions: [ro, dir_mode=0555, file_mode=0444, vers=3.1.1]
  csi:
    driver: smb.csi.k8s.io
    volumeHandle: boston/media/kid-media/podcasts   # unique per PV
    readOnly: true
    volumeAttributes:
      source: //10.0.0.159/boston/media/kid-media/podcasts
    nodeStageSecretRef: {name: smb-boston-ro, namespace: kube-system}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: podcasts
  namespace: funforge
spec:
  accessModes: [ReadOnlyMany]
  storageClassName: ""
  volumeName: funforge-podcasts
  resources: {requests: {storage: 1Ti}}
```
