# Homelab
Repository containing my complete homelab setup

## Structure
- [k8s](./k8s) containing all homelab cluster deployments
- [talos](./talos) containing the bare-metal Talos Kubernetes cluster config (plain `talosctl` config/patches + Makefile, no Tofu)

### Kubernetes Cluster

The Kubernetes cluster runs Talos directly on bare metal (3 hosts,
all-control-plane) — see [talos/README.md](./talos/README.md) for the
full bring-up runbook. To interact with the cluster use the kubeconfig
it produces:
```bash
kubectl --kubeconfig talos/generated/kubeconfig get pods
```

### Deployment
The cluster is bootstrapped from [talos/](./talos) (`make cluster`, or the individual `make flux`/`make bitwarden-secret` targets — see [talos/Makefile](./talos/Makefile)), which helm-installs the Flux Operator and applies [k8s/bootstrap/flux](./k8s/bootstrap/flux). The FluxInstance there defines the Flux distribution (auto-upgraded within the pinned semver range) and its git sync; the operator itself is adopted and kept up to date by the self-managing HelmRelease in [k8s/infra/flux-system/flux-operator](./k8s/infra/flux-system/flux-operator). Manual bootstrap is just:
```bash
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator -n flux-system --create-namespace
kubectl apply --server-side -k k8s/bootstrap/flux
```
From there deployment is split:
- Infrastructure services are defined in [k8s/infra](./k8s/infra) following the structure `k8s/infra/[namespace]/[application]` and are reconciled by Flux. Each component carries its own Flux `Kustomization` colocated at `k8s/infra/[namespace]/[application]/ks.yaml` with `dependsOn` edges forming the deployment-order DAG (health-gated on the component's HelmRelease). The root `infra` Kustomization ([k8s/bootstrap/flux/infra.yaml](./k8s/bootstrap/flux/infra.yaml)) discovers all `ks.yaml` files via `k8s/infra/kustomization.yaml` and the namespace-level aggregators. When adding an infra component: create the component directory with a `ks.yaml` containing the correct edges, and reference it from the namespace-level `kustomization.yaml`.
- User-facing applications are defined in [k8s/apps](./k8s/apps) following the structure `k8s/apps/[namespace]/[application]` and are managed by ArgoCD via the `apps` ApplicationSet (deployed by Flux as the last infra component, `k8s/infra/argocd/argo`).

Don't use kubectl (or Helm) to deploy applications to the cluster.

### Platform Services
The cluster already provides services for caching, database, DNS, and secret handling that can and should be used by other the applications if they need it (e.g. for caching or database).
- [Cache](./k8s/infra/valkey)
- [Database](./k8s/infra/cnpg)
- [External Secrets (uses Bitwarden)](./k8s/infra/external-secrets)
- [Authentication](k8s/infra/authentik)
- Ingress:
  - Use Kubernetes Gateway API
  - Istio is used for service mesh and handles ingress
  - [external-dns](./k8s/infra/external-dns) is used to create DNS records
  - [cert-manager](./k8s/infra/cert-manager) is used to create TLS certificates

