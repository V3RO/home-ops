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

### Application Charts
Every application is packaged as a small wrapper chart under
`k8s/apps/[namespace]/[application]` (`Chart.yaml` + `values.yaml`). Do not copy
Deployment, Service, HTTPRoute, or CNPG resources into every app. Reuse the
homelab helper charts from the Zot OCI registry instead:

| Chart | Use when | Version used in this repo |
| --- | --- | --- |
| `home-ops-app-chart` | The application has **no official Helm chart** | `0.3.1` |
| `home-ops-cnpg-cluster-chart` | The application **needs a PostgreSQL database** | `0.1.0` |
| `home-ops-route-chart` | The application's chart **does not support Gateway API** | `0.1.3` |

All helper charts live in `oci://zot.schober.dev/charts` and are pinned in the
app wrapper's `Chart.yaml`. Add the helper charts as **dependencies of the app's
deployment chart**, next to the upstream chart where one exists. Pin versions
and bump them consistently with the other apps in the repo.

#### Apps without an official Helm chart
Use `home-ops-app-chart` as the only workload dependency. It renders the
Deployment, Service, persistence, probes, ExternalSecrets, and can also render
the route and CNPG resources:

```yaml
# k8s/apps/[namespace]/[application]/Chart.yaml
apiVersion: v2
name: myapp
type: application
version: 0.1.0
dependencies:
  - name: home-ops-app-chart
    version: 0.3.1
    repository: oci://zot.schober.dev/charts
```

Configuration goes under the `home-ops-app-chart:` key in `values.yaml`. Note
that `home-ops-app-chart` already declares `home-ops-route-chart` and
`home-ops-cnpg-cluster-chart` as conditional dependencies, so the route is
enabled through the nested key:

```yaml
home-ops-app-chart:
  image:
    repository: ghcr.io/example/myapp
    tag: v1.2.3

  ports:
    - name: http
      containerPort: 8080
      protocol: TCP

  service:
    ports:
      - name: http
        port: 80
        targetPort: http

  home-ops-route-chart:
    enabled: true
    host: myapp.schober.dev
    backend:
      port: 80
```

If the app needs PostgreSQL, follow the existing wrapper pattern (for example
`k8s/apps/media/qui`) and add `home-ops-cnpg-cluster-chart` as a sibling
dependency so the database is explicit at the wrapper level:

```yaml
# Chart.yaml
dependencies:
  - name: home-ops-app-chart
    version: 0.3.1
    repository: oci://zot.schober.dev/charts
  - name: home-ops-cnpg-cluster-chart
    version: 0.1.0
    repository: oci://zot.schober.dev/charts
    condition: home-ops-cnpg-cluster-chart.enabled
```

```yaml
# values.yaml (top level, not under home-ops-app-chart)
home-ops-cnpg-cluster-chart:
  enabled: true
  cluster:
    storage:
      size: 2Gi
      class: openebs-hostpath
  backup:
    schedule: "0 55 3 * * *"   # pick a free slot, see below
```

#### Apps with an official Helm chart
Wrap the upstream chart in `k8s/apps/[namespace]/[application]` and add only the
helper dependencies the app actually needs. Values for the upstream chart are
nested under its dependency name; helper chart values stay at the top level.

For an app with an official chart that needs PostgreSQL:

```yaml
# Chart.yaml
dependencies:
  - name: myapp
    version: 1.2.3
    repository: oci://ghcr.io/example/charts
  - name: home-ops-cnpg-cluster-chart
    version: 0.1.0
    repository: oci://zot.schober.dev/charts
    condition: home-ops-cnpg-cluster-chart.enabled
```

```yaml
# values.yaml
myapp:
  # upstream chart values
  database:
    host: myapp-postgres-rw.[namespace].svc.cluster.local
    port: 5432
    name: myapp
    user: myapp
    existingSecret: cnpg-myapp-credentials
    existingSecretPasswordKey: password

home-ops-cnpg-cluster-chart:
  enabled: true
  cluster:
    storage:
      size: 5Gi
      class: openebs-hostpath
  backup:
    schedule: "0 20 3 * * *"
    credentials:
      accessKeyIdRef: myapp-backup-id
      secretAccessKeyRef: myapp-backup-secret
```

If the upstream chart does **not** support Gateway API, add
`home-ops-route-chart` as an additional sibling dependency:

```yaml
# Chart.yaml
dependencies:
  - name: myapp
    version: 1.2.3
    repository: oci://ghcr.io/example/charts
  - name: home-ops-route-chart
    version: 0.1.3
    repository: oci://zot.schober.dev/charts
    condition: home-ops-route-chart.enabled
```

```yaml
# values.yaml
home-ops-route-chart:
  enabled: true
  host: myapp.schober.dev
  backend:
    # Set this explicitly when the upstream Service name differs from the
    # release name; the helper defaults the backend to the release name.
    name: myapp
    port: 80
```

If the upstream chart **does** support Gateway API (for example Forgejo's
`httpRoute`), use its native support instead of adding the route helper, and
disable its Ingress template.

#### CNPG helper conventions
`home-ops-cnpg-cluster-chart` creates the CloudNativePG `Cluster`, database
credentials, and barman-cloud backups. Defaults derive from the release name:
cluster `<release>-postgres`, database and owner `<release>`, credentials
Secret `cnpg-<owner>-credentials` (basic-auth with a `password` key), and
backup path `s3://cnpg-backups/<release>/`.

- Use 3 instances on `openebs-hostpath` unless there is a reason not to; CNPG
  handles replication itself.
- Databases are backed up nightly to versitygw. Existing clusters use
  5-minute slots between `03:05` and `03:55`; pick an unused slot for a new app
  rather than reusing or overlapping one.
- Each app gets its own versitygw account/keys (`<app>-backup-id` and
  `<app>-backup-secret`), not the shared root credentials. The credentials are
  managed through the `bitwarden-cnpg-secrets` ClusterSecretStore and generated
  in-cluster on first install.
- Point the application at `<cluster.name>-rw.<namespace>.svc.cluster.local:5432`
  and consume the generated `cnpg-<owner>-credentials` Secret.

#### Route helper conventions
`home-ops-route-chart` creates an `HTTPRoute` for apps that cannot render one
themselves. By default it attaches to the internal Gateway
(`internal-gateway` in `istio-ingress-internal`, `sectionName: https`), so
[cert-manager](./k8s/infra/cert-manager) and [external-dns](./k8s/infra/external-dns)
handle TLS and DNS automatically. Useful values:

- `host` / `hostnames`: hostnames to serve (rendered through `tpl`).
- `backend.name`: target Service; defaults to the release name and must be set
  for upstream charts whose Service is named differently.
- `backend.port`: target Service port.
- `gateway.name`, `gateway.namespace`, `gateway.sectionName`: use another
  Gateway, for example the public `kgateway-external` in `kgateway-external`.
- `extraRules`: raw additional HTTPRoute rules.
- `authentik.enabled`: adds Authentik forward-auth (GatewayExtension +
  TrafficPolicy) and a callback rule. The app's namespace must be present in
  the Authentik `ReferenceGrant` at
  `k8s/infra/authentik/authentik/templates/reference-grant.yaml`.

### Platform Services
The cluster already provides services for caching, database, DNS, and secret handling that can and should be used by other the applications if they need it (e.g. for caching or database).
- [Cache](./k8s/infra/valkey)
- [Database](./k8s/infra/cnpg)
- [External Secrets (uses Bitwarden)](./k8s/infra/external-secrets)
- [Authentication](k8s/infra/authentik)
- Ingress:
  - Use Kubernetes Gateway API
  - Istio is used for service mesh
  - Kgateway is is the Gateway API implementation 
  - [external-dns](./k8s/infra/external-dns) is used to create DNS records
  - [cert-manager](./k8s/infra/cert-manager) is used to create TLS certificates

