# Talos bare-metal cluster

Plain `talosctl` config/patches + a `Makefile` for bringing up the
3-node all-control-plane Talos cluster directly on bare metal (no
OpenTofu, no Proxmox). Nodes:

| Node    | Physical host | IP           | Install disk    |
|---------|---------------|--------------|------------------|
| ctrl-01 | atheon        | 10.1.40.11   | `/dev/nvme0n1`   |
| ctrl-02 | panoptes      | 10.1.40.12   | `/dev/nvme0n1`   |
| ctrl-03 | quria         | 10.1.40.13   | `/dev/nvme0n1`   |

All three also advertise a shared control-plane **VIP, `10.1.40.10`**, on
`eno2` via a `Layer2VIPConfig` document
(https://docs.siderolabs.com/talos/v1.13/reference/configuration/network/layer2vipconfig)
— gratuitous-ARP failover between whichever control-plane node currently
holds it, used as the Kubernetes API endpoint
(`CLUSTER_ENDPOINT`/`cluster.controlPlane.endpoint`, and hence
`kubeconfig`'s `server:`). **Never point `talosconfig`/`talosctl` at the
VIP** — it depends on `etcd`/`kube-apiserver` health, so if either is down
you'd lose the one channel (the Talos API) that could fix it. `make
bootstrap`/`kubeconfig`/`health` in the `Makefile` intentionally keep
talking to the real per-node IPs, never the VIP.

**Networking assumption:** each node's switch port must be configured as
an **access port, native VLAN 40** (untagged) — matching how Proxmox
tagged VLAN 40 at the bridge before. `patches/nodes/ctrl-0X.yaml` sets the
IP directly on the physical interface (`eno2`) with no VLAN tagging, which
only works if the switch hands it untagged VLAN 40 traffic. If a NIC ever
needs to carry more than one VLAN, use Talos's `VLANConfig` document
(https://docs.siderolabs.com/talos/v1.13/reference/configuration/network/vlanconfig)
instead — but note maintenance-mode DHCP (before any config is applied)
only works on the port's native/untagged VLAN, so the trunk's native VLAN
would still need to be 40 for the initial `apply-config` to ever reach the
node.

## Multi-document config (Talos 1.14+)

As of Talos 1.14 `talosctl gen config` emits the **multi-document** machine
config: most settings that used to live under the monolithic v1alpha1
`machine:`/`cluster:` keys now have their own documents, and setting the
same thing in both places is a hard validation error. The patches in
`patches/` are written against the new documents throughout. See the
[configuration document map](https://docs.siderolabs.com/talos/v1.14/reference/configuration/document-map)
for which document owns which old field. Notable ones here:

| Old v1alpha1 field                      | Document                      |
|-----------------------------------------|-------------------------------|
| `machine.kubelet.extraArgs`             | `KubeletConfig`               |
| `machine.kubelet.extraMounts`           | `UserVolumeConfig` (removed — see below) |
| `machine.sysctls`                       | `SysctlConfig`                |
| `machine.nodeLabels`                    | `KubeNodeConfig`              |
| `machine.install`                       | `UnattendedInstallConfig`     |
| `cluster.allowSchedulingOnControlPlanes`| `KubeNodeConfig` (drop the taint) |
| `cluster.proxy.disabled`                | `KubeProxyConfig.enabled: false` |
| `cluster.network.cni.name: none`        | delete the `KubeFlannelCNIConfig` document |
| `cluster.extraManifests`                | `KubeExternalManifestConfig` (one per URL) |
| `cluster.inlineManifests`               | `KubeInlineManifestConfig` (one per manifest) |

`cluster.etcd` has no document equivalent yet and stays under v1alpha1.

Two syntax gotchas the patches rely on:

- **Deleting** something the generated config sets needs `$patch: delete`
  (plain `null` or `{}` is silently a no-op) — that's how the
  control-plane `NoSchedule` taint and the Flannel document are removed.
- `HostnameConfig` is generated with `auto: stable`, which conflicts with a
  static `hostname`, so each node patch sets `auto: "off"` — quoted, or
  YAML parses it as the boolean `false`.

`machine.kubelet.extraMounts` was **removed** in the multi-doc config with
no drop-in replacement. The supported equivalent is a `UserVolumeConfig`
with `volumeType: directory`: Talos bind-mounts it off EPHEMERAL at
`/var/mnt/<name>` and propagates it into the kubelet container. That fixes
the path, so the consuming charts point at it:
`longhorn` → `/var/mnt/longhorn` (`defaultDataPath` in
[../k8s/infra/longhorn-system/longhorn/helmrelease.yaml](../k8s/infra/longhorn-system/longhorn/helmrelease.yaml))
and `openebs-local` → `/var/mnt/openebs-local` (`localpv.basePath` in
[../k8s/infra/openebs/localpv-provisioner/helmrelease.yaml](../k8s/infra/openebs/localpv-provisioner/helmrelease.yaml)).

Run `make validate` to merge the patch stack into the base config and
validate the result offline — same stack `make apply` pushes, but without
needing a node. Do this before every `apply`.

Each node's static IP is set via a `LinkConfig` document keyed on the
interface **name** (`eno2` on all three boxes) rather than the older
`machine.network.interfaces[].deviceSelector.hardwareAddr` MAC-selector
approach — see
https://docs.siderolabs.com/talos/v1.13/reference/configuration/network/linkconfig.
Hostnames use a `HostnameConfig` document the same way. These are
additional documents stacked into the same per-node patch file (separated
by `---`), applied through the same `--config-patch` flag as everything
else — no `Makefile`/tooling changes needed.

## Layout

- `image/schematic.yaml` — Talos Image Factory system extensions
  (`i915-ucode`, `intel-ucode`, `iscsi-tools`, `util-linux-tools` — the
  last two are required by Longhorn).
- `bootstrap/cilium/` — Cilium install Job + Helm values, injected as
  Talos `inlineManifests` so Cilium comes up before kube-proxy/CNI would
  otherwise be needed (kube-proxy and the default CNI are disabled).
- `patches/machine.yaml` — shared config for every node: `KubeletConfig`,
  `SysctlConfig`, `KubeNodeConfig` (region label), and the `longhorn` /
  `openebs-local` `UserVolumeConfig`s.
- `patches/controlplane.yaml` — shared control-plane-only config
  (scheduling on control planes, CNI/kube-proxy disabled, extra
  manifests, etcd metrics).
- `patches/nodes/ctrl-0X.yaml` — per-node `UnattendedInstallConfig`
  (install disk) + `HostnameConfig` + `KubeNodeConfig` (zone label) +
  `LinkConfig` (static IP/route on `eno2`) + `Layer2VIPConfig` (shared
  control-plane VIP).
- `scripts/` + `Makefile` — everything two things above can't express
  statically: looking up the Image Factory schematic ID, and rendering
  the Cilium manifests into `inlineManifests` strings.
- `generated/` — **gitignored**. `talosctl gen config` output (cluster
  PKI secrets!), the rendered dynamic patches, `talosconfig`,
  `kubeconfig`.

Run `make help` for the full target list.

## Prerequisites

`talosctl`, `kubectl`, `helm`, `python3`, `curl` on your machine.

## 1. Reserve each node's maintenance-mode IP

`patches/nodes/ctrl-01.yaml`, `ctrl-02.yaml`, `ctrl-03.yaml` already target
the `eno2` interface by name, so nothing needs editing there as long as
that's the right port on all three boxes.

**Recommended:** create a DHCP static reservation on your router for each
node's `eno2` MAC (check the NIC label, BIOS network page, or boot a Linux
live USB and run `ip link`), mapping it to the node's final static IP
(10.1.40.11/.12/.13 — the VIP `10.1.40.10` is never a node's own IP, it
only ever gets ARP'd by whichever node currently holds it). Talos
maintenance mode uses DHCP before any config is applied, and unlike the
old Proxmox/cloud-init setup there's nothing to push a static IP before
boot — a reservation means the node is already reachable at its final IP
the moment it boots from USB, and `talosctl apply-config` can target that
IP directly.

**Without a reservation** the node still comes up — maintenance mode just
DHCPs some other address, and the maintenance IP is throwaway either way
(Talos switches to the `LinkConfig` static IP as soon as the config lands).
Read the address off the node's console (or `nmap -Pn -p 50000 --open
10.1.40.0/24`) and pass it through: `make apply NODE=ctrl-01 IP=<dhcp-ip>`.
Note `apply-all` has no `IP=` escape hatch — it always uses the final static
IPs — so in that case run the three `make apply` calls individually.

## 2. Build and flash the install media

```bash
make iso-url
```

Download the printed ISO URL and flash it to a USB stick (balenaEtcher,
`dd`, Rufus, etc.). Boot each of the 3 machines from the USB stick into
Talos maintenance mode.

## 3. Apply config, bootstrap, fetch kubeconfig

Once all 3 nodes are up in maintenance mode and reachable at their static
IPs:

```bash
make validate    # offline check that the merged config is valid (no node needed)
make apply-all   # pushes machine config + triggers install to /dev/nvme0n1 on all 3 nodes
make bootstrap   # one-time etcd bootstrap on ctrl-01
make kubeconfig  # writes generated/kubeconfig
make health      # waits for the cluster to report healthy
```

or just `make cluster` to run apply-all → bootstrap → health → flux in
one go (see below).

Use the generated config day to day:

```bash
export TALOSCONFIG=$(pwd)/generated/talosconfig
export KUBECONFIG=$(pwd)/generated/kubeconfig
```

> `make health` uses `talosctl health`; flag names have changed across
> Talos versions, so check `talosctl health --help` if it errors.

## 4. Bootstrap Flux and external-secrets

```bash
make flux                                          # installs flux-operator + applies k8s/bootstrap/flux
BITWARDEN_ACCESS_TOKEN=... make bitwarden-secret    # creates the token secret external-secrets needs
```

From here, deployment follows the rest of the repo as documented in
[../agents.md](../agents.md): Flux reconciles [../k8s/infra](../k8s/infra),
ArgoCD reconciles [../k8s/apps](../k8s/apps).

## Rebuilding the cluster with existing data (media apps)

The state on TrueNAS (NFS datasets) and in versitygw's object storage
survives a full cluster rebuild — the repo has re-adoption/restore hooks
for it. In order:

1. **Before tearing down the old cluster** (or from the TrueNAS UI after):
   note the dataset names under `hdd/k8s/n/v/` matching
   `nfs-<pvc-name>-<uid6>` for the `media-data` PVC (media namespace) and
   the versitygw data PVC (versitygw namespace — holds the `cnpg-backups`
   and `iam` buckets). On the old cluster:
   `kubectl get pv -o json | jq -r '.items[] | select(.spec.storageClassName=="truenas-nfs-media") | [.spec.claimRef.namespace+"/"+.spec.claimRef.name, .spec.csi.volumeHandle] | @tsv'`
2. **Enable adoption/restore in git before first deploy:**
   - `k8s/apps/media/storage/values.yaml` → `adopt.dataset: <media-data dataset name>`
   - `k8s/infra/versitygw/versitygw/helmrelease.yaml` → `adopt.dataset: <versitygw dataset name>`
   - `k8s/apps/media/{sonarr,radarr,prowlarr}/values.yaml` →
     `postgres.restore.enabled: true` (bootstrap from the versitygw
     barman-cloud backup instead of `initdb`). Include `seerr` here on
     future rebuilds once its first backup exists — not on the first one
     after the jellyseerr→seerr switch.
3. **Bring up the cluster** (`make cluster` + `make bitwarden-secret`) as
   usual. The static PVs/PVCs bind to the retained datasets, so versitygw
   serves the existing buckets and `media-data` remounts as-is. ESO must
   be syncing before CNPG recovery works (DB passwords + backup
   credentials come from Bitwarden — ordering is: external-secrets →
   versitygw healthy → ArgoCD media apps).
4. **Verify**, then clean up:
   - `kubectl -n media get pvc media-data` and `kubectl -n versitygw get pvc`
     must be `Bound` to the static PVs; spot-check files under `/data`.
   - `kubectl -n media get cluster` — the `*-postgres` clusters bootstrap
     in recovery; watch `kubectl -n media logs <primary pod> | grep -i recovery`.
     Each app then continues WAL archiving to the same object store, no gap.
   - Leave `adopt.dataset` **set permanently** (the static PV/PVC binding is
     the steady state now). Flip the three `postgres.restore.enabled` back
     to `false` once the restored clusters are healthy — CNPG ignores
     `bootstrap` on an initialized cluster anyway, this just keeps git
     honest.

Not covered by this: the per-app `*-config` PVCs on Longhorn
(jellyfin/seerr/qbittorrent config, sonarr/radarr/prowlarr `/config`) are
recreated empty. configarr + the restored Postgres DBs regenerate
sonarr/radarr/prowlarr; seerr starts fresh against its (restored or new)
Postgres DB and re-links jellyfin/sonarr/radarr via the setup wizard.
Jellyfin must be set up fresh unless restored from a separate backup.

## Updating the cluster later

- Change `patches/*.yaml` for config changes, `image/schematic.yaml` for
  extensions, then `make validate` and re-run `make apply NODE=ctrl-01`
  (or `apply-all` for all three) — `talosctl apply-config` is safe to re-run against a live
  node.
- Bumping `TALOS_VERSION` and re-running `make render apply-all` upgrades
  the install image reference; Talos performs the actual OS upgrade on
  the next reboot/via `talosctl upgrade`.
