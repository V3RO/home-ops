# Self-hosted NetBird — progress and handover

Status as of **2026-10-06**. Companion to:
- `NETBIRD_SELF_HOSTING_PLAN.md` — the original design
- `NETBIRD_PUBLIC_GATEWAY_CROWDSEC_FOLLOW_UP_PLAN.md` — public edge and CrowdSec

> **Read `origin/main`, not a stale local checkout.** During the build, more than
> one session worked this repo concurrently and local checkouts repeatedly fell
> behind. Verify `git rev-parse --short HEAD` against the Flux revision before
> concluding anything from local files. Several components were also refined
> after the initial commits (the live config differs from what the first author
> wrote), so **the cluster is authoritative** where they disagree.

---

## 1. Current state

Working and verified: NetBird control plane reachable publicly, clients
authenticate via Authentik, and **a remote device can reach homelab services
through the tunnel** (confirmed from an off-network device).

| Component | State |
| --- | --- |
| `netbird` (Flux component) | Ready |
| `netbird-router` (Flux component) | Ready |
| `kgateway-external` (Flux component) | Ready |
| `external-dns-cloudflare` (Flux component) | Ready |
| Server / dashboard | `netbirdio/netbird-server:0.77.0` / `netbirdio/dashboard:v2.90.10` |
| Router client | `netbirdio/netbird:0.77.0`, `1/1 Running` |
| Chart pin | netbird `1.0.8`, home-ops-cnpg-cluster-chart `0.1.0` |
| CNPG cluster | 3 instances, `Cluster in healthy state` |
| Continuous archiving | `ContinuousArchiving=True`, `ok=1257 fail=0` |
| Nightly backups | 5+ consecutive `completed` (03:30, `0 30 3 * * *`) |
| Router client connectivity | `Management: Connected`, `Signal: Connected`, `Relays: 1/2 Available` |

### Addresses

| Purpose | Value |
| --- | --- |
| Public Gateway (`kgateway-external`) | `10.1.40.91` (Cilium VIP, BGP-advertised) |
| Internal Gateway (`istio-ingress-internal`) | `10.1.40.66` |
| STUN LoadBalancer | `10.1.40.90`, UDP 3478 |
| WAN IP | `80.108.88.161` |
| NetBird hostname | `netbird.schober.dev` (DNS-only, never proxied) |
| Authentik hostname | `auth.schober.dev` (must stay public — see §5) |

### Public DNS

- `netbird.schober.dev` → `80.108.88.161`, published by `external-dns-cloudflare`
  from the Gateway's `external-dns.alpha.kubernetes.io/target` annotation.
- `auth.schober.dev` → `80.108.88.161`.
- Homelab app hostnames (`jellyfin`, `immich`, …) have **no public records**;
  they resolve only internally, and remote clients reach them through NetBird.

---

## 2. Delivered components

| Path | Purpose |
| --- | --- |
| `k8s/infra/netbird/` | Combined server + dashboard + CNPG + backups |
| `k8s/infra/netbird/netbird/templates/config-external-secret.yaml` | Renders the **entire** `config.yaml` via External Secrets |
| `k8s/infra/netbird-router/` | NetBird client peer acting as the routing peer |
| `k8s/infra/kgateway-external/` | Dedicated public Gateway + leaf certs |
| `k8s/infra/external-dns/external-dns-cloudflare/` | Publishes public DNS (Cloudflare) |

NetBird was deliberately removed from `internal-gateway` and its wildcard
certificate; `netbird.schober.dev` and `auth.schober.dev` each have their own
leaf certificate on the public gateway, with `allowedRoutes` restricted to the
`netbird` and `authentik` namespaces respectively.

---

## 3. Where secrets live

All delivered through External Secrets; **no secret values in git**.

| Bitwarden item (project `bitwarden-app-secrets`) | Used for |
| --- | --- |
| `netbird-auth-secret` | `server.authSecret` (relay shared secret) |
| `netbird-encryption-key` | `server.store.encryptionKey` — **see §5, critical** |
| `netbird-owner-email` / `netbird-owner-password` | Local break-glass owner |
| `netbird-router-setup-key` | Router peer enrolment |
| `cloudflare-token` | cert-manager DNS-01 **and** external-dns |

`netbird-database-password` (project `bitwarden-cnpg-secrets`) holds the CNPG
password; the cluster chart pushes it with `updatePolicy: IfNotExists`, so it
survives rebuilds.

---

## 4. Configuration that is NOT in git

These live in the NetBird dashboard / database. A rebuild loses them, and no
Flux reconciliation will restore them. **Recreate manually after any rebuild.**

- `kubernetes-routers` group
- Network `Homelab`, with resources:
  - `schober.dev` — type `domain`, `*.schober.dev`
  - `Homelab CIDR` — type `subnet`, `10.1.40.0/24`
- Network router attached via the `kubernetes-routers` group, `masquerade: true`
- Policies: `Default`, `schober.dev Access`, `Homelab CIDR Access`
- Custom DNS zone `schober.dev` distributed to the client group **and**
  `kubernetes-routers` (the routing peer must receive the zone to answer queries)
- Authentik blueprint state (application, provider, MFA, registration disabled)

---

## 5. Hard-won gotchas — read before changing anything

These each cost a full debug cycle. Most share one theme: **every layer reported
success while the value was wrong.** Kubernetes and ESO can confirm a secret
*arrived*; they cannot confirm it is *valid*.

### 5.1 `server.auth.owner.password` must be a **bcrypt hash**, not plaintext

NetBird passes it verbatim into Dex's `Password.Hash` and never hashes it. The
upstream `config.yaml.example` showing `password: "initial-password"` is
misleading.

- Cost must be **≥ 10**; Dex rejects lower (`htpasswd -B` defaults to 5).
- Generate with: `python3 -c "import bcrypt; print(bcrypt.hashpw(b'<pw>', bcrypt.gensalt(rounds=12)).decode())"`
- **Always verify before deploying**: `bcrypt.checkpw(...)`, and check the
  rendered config contains `$2[aby]$<cost≥10>$`.
- Failures look like `hashedSecret too short` → `hash cost = 5` → `Invalid
  credentials`, i.e. one value, three different errors.

### 5.2 `encryptionKey` must be stable and non-empty

Empty ⇒ the server generates a **fresh random key on every boot**, making all
previously written user records undecryptable. Symptom is a **401** with
`decrypt: cipher: message authentication failed` — which looks like an auth
problem and is not.

Recovery: rows written under a lost key are unrecoverable; clear them so the IdP
re-provisions on next login.

### 5.3 The ExternalSecret is all-or-nothing

One unresolvable key blanks the **entire** rendered config. A missing Bitwarden
item therefore looks like the whole app failing, not one setting. Verify every
referenced item exists **before** pushing a change that adds one.

### 5.4 Config changes from Bitwarden do not roll the pod by themselves

The chart's `checksum/config` annotation hashes only Helm **values**. A rotated
secret lands in the Secret but is never re-read (config is read at startup).
Mitigated with `podAnnotations: reloader.stakater.com/auto: "true"`.

### 5.5 The server needs an explicit port in `signalUri`

The combined server derives the signal URI from `exposedAddress`. With no port,
clients dial the bare hostname and fail with
`dial tcp: address netbird.schober.dev: missing port in address` — surfacing only
as `failed to connect to the signalling server: context deadline exceeded`,
while **management keeps working** (its URL has `:443`). Live config now sets
`exposedAddress: "https://netbird.schober.dev:443"`.

### 5.6 The router client needs `/dev/net/tun` and a privileged context

Current deployment: `securityContext.privileged: true`, capabilities
`NET_ADMIN`, `SYS_RESOURCE`, `SYS_ADMIN`, and a `hostPath` volume `tun:
/dev/net/tun`. `NB_WG_KERNEL_DISABLED=true` is still set.

The `netbird-router` **namespace is PodSecurity `privileged`** — required for
this. It is a separate namespace specifically so the `netbird` namespace (which
runs the unprivileged server and dashboard) did not have to be relaxed.
`istio.io/dataplane-mode: none` is set to keep it out of the ambient mesh.

### 5.7 Setup keys: format, reusability, and consumption

- Must be a UUID — a 64-char value with no hyphen fails with
  `invalid UUID length: 64`.
- Must be **reusable**; a one-off key is consumed on first enrolment and every
  retry then fails with `setup key is invalid`.
- An **empty value** (`NB_SETUP_KEY=`) produces `no peer auth method provided`.
- Enable **Allow Extra DNS Labels** only if you intend to use peer-attached DNS
  labels; the chosen design uses custom zones instead, so leave it **off**.

### 5.8 RollingUpdate deadlocks on the RWO data volume

The chart only sets `Recreate` for its sqlite store. With external Postgres the
deployment is `RollingUpdate` against a `ReadWriteOnce` PVC, so a plain rollout
hangs: the new pod waits for a volume the old pod still holds. Reloader removes
the old pod first, which also avoids the deadlock.

### 5.9 `kubectl apply --dry-run=server` does **not** enforce PodSecurity

It only warns. Capabilities that violate the namespace's profile appear to pass
and then fail at runtime.

### 5.10 Always validate a component's own kustomize build

`kubectl kustomize k8s/infra/<parent>` does **not** evaluate a component's
manifest list — a bad resource path there passes and breaks only at reconcile.
Validate `k8s/infra/<component>/<chart>` in isolation.

### 5.11 Backups are now genuinely restorable

An earlier rebuild left **no base backup** (`BASE BACKUPS: NONE`) — archiving
was green while nothing could actually be restored. Nightly `ScheduledBackup`
now runs. If archiving fails after a rebuild, the cause is usually **stale WAL
history from a previous cluster** under the same S3 prefix: barman refuses with
`Expected empty archive`, and the fix is to purge `s3://cnpg-backups/netbird/`.

---

## 6. Outstanding tasks

### 6.1 Restore rehearsal — highest value

Backups are proven to be *written*; a restore has **never been tested**. The
plan's gate 6 requires it, and this cluster has already been rebuilt twice.

Do it **non-destructively** — restore into a scratch namespace/cluster — and
specifically verify the combination that previously broke: database **plus** the
`encryptionKey` from Bitwarden, then confirm user rows actually decrypt. A
restore that returns unreadable rows looks successful and is not.

### 6.2 STUN exposure unverified

`netbird-stun` is healthy at `10.1.40.90` UDP 3478, but no WAN forward has been
confirmed from outside. Without it, peers skip STUN and fall back to relay
(currently `Relays: 1/2`), which works but costs latency. Plan acceptance item 3.

### 6.3 JWT group gating not enabled

Account settings: `jwt_groups_enabled=false`, `user_approval_required=true`.
Any Authentik identity can reach NetBird and land pending; the plan's
`netbird_users` gating is not enforced. Authentik-side hardening (MFA,
registration disabled) covers most of the risk. Last piece of plan item 5.

### 6.4 No monitoring or alerting

Nothing watches control-plane availability, certificate expiry, backup failure,
or unusual enrolment volume. Given how many failures in this build reported
success at every layer, **backup-failure and cert-expiry alerts** would pay for
themselves. Also check the pre-existing `prometheus-server-0` crashloop, which
leaves several monitoring Kustomizations at `DependencyNotReady`.

### 6.5 Cleanup

- Stale `netbird-k8s-router` peer rows from early restarts (delete in dashboard).
- `Homelab CIDR` advertises `10.1.40.0/24`; the gateway VIPs are in
  `10.1.40.64/26`. Narrow it if you want tighter scope.
- CrowdSec (`NETBIRD_PUBLIC_GATEWAY_CROWDSEC_FOLLOW_UP_PLAN.md` phase 4) is still
  entirely undone and now unblocked, since the public gateway serves real traffic.

---

## 7. Quick diagnostic recipes

```bash
KC=home-ops/talos/generated/kubeconfig

# Is the route change actually live, and where does each hostname attach?
kubectl --kubeconfig $KC get httproute -A \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} -> {.spec.parentRefs[0].name} {.spec.hostnames}{"\n"}{end}'

# Router client state (management/signal/relay are the three things that matter)
kubectl --kubeconfig $KC exec -n netbird-router deploy/netbird-router -c netbird -- netbird status --detail

# The real error is in the CLIENT LOG FILE, not the truncated container log
kubectl --kubeconfig $KC exec -n netbird-router deploy/netbird-router -c netbird -- \
  sh -c 'tail -40 /var/log/netbird/client.log'

# Config as the server actually sees it (authoritative over git)
kubectl --kubeconfig $KC get secret -n netbird netbird-config -o jsonpath='{.data.config\.yaml}' \
  | base64 -d

# Backup health
kubectl --kubeconfig $KC get cluster -n netbird netbird-postgres \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
kubectl --kubeconfig $KC get backup.postgresql.cnpg.io -n netbird

# NB: `kubectl get backup` resolves to Longhorn's CRD — always qualify it.
```

**Reading logs carefully matters.** The container log frequently shows a
*wrapped* error (`context deadline exceeded`) while the underlying cause
(`missing port in address`) is only in the client log file or the barman
sidecar. Several hours were lost to reading wrapper messages.

---

## 8. Working agreements for this repo

- Flux reconciles infrastructure; **do not** `kubectl apply` workload changes by
  hand. Cluster-side fixes must be landed in git or a Helm reconcile will revert
  them.
- `git pull --rebase` before pushing — concurrent sessions caused a commit to be
  nearly orphaned once already.
- Prefer validating rendered output over trusting a plausible-looking diff.
  Several defects here were invisible in the diff and obvious in the render.
