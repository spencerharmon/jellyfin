# jellyfin — k8s co-location + persistence reference (`colocation-persistence-contract`, `snapshot-restore-contract`)

Reference-only fragments, **not** deployable manifests on their own. The canonical contracts, the
blue/green library decision, and the full rationale live in the beehive layer at
`submodules/jellyfin/INFRASTRUCTURE.md` (this fork does not keep its own copy — that file is the
contract of record). flux's `phantom-library-bluegreen-deploy` composes these together with
gostream's `fuse-mount-propagation` fragment (the shared FUSE volume + its Bidirectional/
privileged side) into one co-located Pod spec.

## What's here
`jellyfin-colocation-fragment.yaml`:
- Four `PersistentVolumeClaim`s — `jellyfin-var-lib-blue` / `jellyfin-etc-blue` /
  `jellyfin-var-lib-green` / `jellyfin-etc-green` — `ReadWriteOnce`, `storageClassName:
  local-path` (single-node cluster, same class gostream's `state-pvc` uses). One independent
  pair per blue/green color — see `INFRASTRUCTURE.md` for why independent, not shared.
- `jellyfinContainerFragment` / `jellyfinVolumesFragment` — the jellyfin container's
  `volumeMounts` + `volumes` excerpt: mounts the shared `gostream-mkv-virtual` volume
  `HostToContainer` read-only at `/mnt/gostream-mkv-virtual` (same in-container path gostream
  uses), plus its own `/var/lib/jellyfin` + `/etc/jellyfin` PVC mounts. These two keys are
  **not** real Kubernetes kinds — they are named excerpts for the composing manifest (flux) to
  splice into the shared Pod's `containers:` / `volumes:` lists alongside gostream's own
  container and its shared-volume declaration.
- Naming (`-blue` / `-green` suffixes) is illustrative — flux's compose step may rename or
  restructure these (e.g. via a per-color Kustomize overlay) as long as the two colors keep
  independent PVC pairs.

`jellyfin-snapshot-restore-fragment.yaml` (additive sibling, does not modify the fragment above):
- A `VolumeSnapshot` of the **active (prod)** color's `jellyfin-var-lib-<active-color>` PVC, plus a
  restore `PersistentVolumeClaim` for the **inactive** color with `dataSource: {kind: VolumeSnapshot,
  ...}`, replacing that color's previous independent PVC under the same claim name. See
  `INFRASTRUCTURE.md`'s "Snapshot → restore provisioning contract" section for the full sequence,
  the three-way ownership split (jellyfin/phantom-library/flux), and the accepted
  write-loss-window tradeoff at cutover.
- Uses two clearly-marked not-yet-resolved placeholders — `TBD-flux-volumesnapshotclass` and
  `TBD-flux-linstor-storageclass` — for names flux has not minted yet (its Piraeus/LINSTOR CSI work,
  driver `linstor.csi.linbit.com`); see `ARTIFACTS.md` for the cross-dep this records for the next
  reconcile. Never asserted as real names.
- `/etc/jellyfin` is explicitly **not** part of this cycle — only the `/var/lib/jellyfin` (library
  data) PVCs are snapshotted/restored.

## Explicitly not here
- The `gostream-mkv-virtual` volume's own definition (hostPath vs emptyDir) — gostream's
  `fuse-mount-propagation` fragment owns that.
- The jellyfin container image reference — a placeholder pending `container-image`
  (`submodules/jellyfin/ARTIFACTS.md` will carry the real image/tag once that task lands).
- The real `VolumeSnapshotClass`/`StorageClass` names the snapshot/restore fragment references —
  flux's to mint; not yet landed as of this reconcile (see `ARTIFACTS.md` cross-dep note).
- gostream's inode map (`gostream.db`) — never snapshotted, restored, or otherwise touched by the
  snapshot/restore fragment; gostream shares one state PVC across colors by its own `state-pvc`
  decision, independent of this contract.
- Live in-cluster bring-up, mount propagation, execution of the snapshot/restore cycle, or rig 35/36
  verification — flux's `phantom-library-bluegreen-deploy` job, cross-referenced, not claimed here.
