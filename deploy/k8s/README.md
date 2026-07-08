# jellyfin — k8s co-location + persistence reference (`colocation-persistence-contract`)

Reference-only fragment, **not** a deployable manifest on its own. The canonical contract, the
blue/green library decision, and the full rationale live in the beehive layer at
`submodules/jellyfin/INFRASTRUCTURE.md` (this fork does not keep its own copy — that file is the
contract of record). flux's `phantom-library-bluegreen-deploy` composes this together with
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

## Explicitly not here
- The `gostream-mkv-virtual` volume's own definition (hostPath vs emptyDir) — gostream's
  `fuse-mount-propagation` fragment owns that.
- The jellyfin container image reference — a placeholder pending `container-image`
  (`submodules/jellyfin/ARTIFACTS.md` will carry the real image/tag once that task lands).
- Live in-cluster bring-up, mount propagation, or rig 35/36 verification — flux's
  `phantom-library-bluegreen-deploy` job, cross-referenced, not claimed here.
