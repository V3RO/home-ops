# versitygw bootstrap

## IAM S3 backend bucket

`iam.type: s3` (see [helmrelease.yaml](helmrelease.yaml)) stores IAM accounts —
i.e. the access keys handed out to individual clients via the admin API — as
a single object inside a bucket on this same gateway, instead of the internal
flat-file store. The S3 IAM backend does not create its bucket for you, so
`iam` must exist before any `CreateAccount` admin call will succeed.

[templates/iam-bucket-setup.yaml](templates/iam-bucket-setup.yaml) is an
idempotent `Job` that ensures this — same `create-bucket` pattern as
`cnpg-bucket-policy.yaml`'s `cnpg-backups-bucket-setup` (owner in a
**header**, not a query param; bucket name as a **path** segment), just
with no bucket policy needed: this bucket is only ever read/written by
root (`VGW_S3_IAM_ACCESS_KEY`/`SECRET_KEY` in `helmrelease.yaml`), never by
a per-client account. No ordering dependency on anything else in this
chart — root doesn't need the IAM backend (or this bucket) to already be
readable, since root bypasses IAM/policy evaluation entirely.

Verify by creating a test account through the admin API/WebUI and confirming
`iam` now holds a `users.json` object.

### Why this needed two attempts (the second one caused a real outage)

versitygw's S3 IAM client always builds requests **virtual-hosted-style**
(`<bucket>.<endpoint-host>`) — there is no path-style option for it (unlike
the regular S3 API client config). Getting this working correctly took two
tries; the first "working" fix was actually a live production regression
that took ~25 minutes to notice. Both attempts, and why, are recorded here
so nobody repeats either mistake.

**Attempt 1 — DNS failure.** Pointed straight at the gateway's real Service
name, requests broke outright:

```
[INTERNAL ERROR]: get users.json: operation error S3: GetObject, ...
Get "http://iam.versitygw.versitygw.svc.cluster.local:7070/users.json?x-id=GetObject":
dial tcp: lookup iam.versitygw.versitygw.svc.cluster.local on 10.96.0.10:53: no such host
```

`iam.versitygw.versitygw.svc.cluster.local` isn't a name anything serves —
it doesn't match the `<service>.<namespace>.svc.cluster.local` shape
CoreDNS's Kubernetes plugin resolves. Fixed by adding a second Service named
`iam` **in the same `versitygw` namespace**, so `iam.versitygw.svc.cluster.local`
became a real, resolvable name, with `VGW_S3_IAM_ENDPOINT`'s host set to
`versitygw.svc.cluster.local` so the client's bucket-prefixed URL landed on
it.

That got the hostname resolving, but the gateway still needed to know that
`Host: iam.versitygw.svc.cluster.local` means bucket `iam` — otherwise it
falls through to ordinary path-style parsing, reads the literal path
`/users.json` as bucket **`users.json`**, and returns a second,
easy-to-mistake-for-the-first `NoSuchBucket`. Fixed by adding
`gateway.virtualDomain: "versitygw.svc.cluster.local"`, which makes the
`HostStyleParser` middleware rewrite that Host + path into path-style
`/iam/users.json` before routing.

**Attempt 2's fix was the actual outage.** `HostStyleParser` is mounted
globally (`app.Use("*", ...)` — upstream `s3api/router.go`), on *every*
request on the S3 port, not just the IAM backend's own calls. This
gateway's real Service happens to be named identically to its namespace
(`versitygw` in `versitygw`), so its own bare hostname —
`versitygw.versitygw.svc.cluster.local`, used directly by `mc` and by every
CNPG cluster's `scheduled-backup.yaml` (`endpointURL:
http://versitygw.versitygw.svc.cluster.local:7070`) — is *itself*
`"versitygw" + "." + "versitygw.svc.cluster.local"`, i.e. exactly matches
`<bucket>.<virtualDomain>` with bucket `versitygw`. Every real PUT/GET from
CNPG's WAL archiving got silently rewritten to `/versitygw/cnpg-backups/...`
and 404'd as `NoSuchBucket, BucketName: versitygw` — continuously, in
production, until caught by chance while testing something unrelated.

### The actual fix: alias in a different namespace, not the same one

[templates/iam-service.yaml](templates/iam-service.yaml) is a Kubernetes
`Service` of `type: ExternalName` (pure DNS CNAME — no selector, no
ClusterIP, no Istio involvement) living in the **`external-services`**
namespace, not `versitygw`, even though it's part of this chart — Helm/Flux
applies whatever namespace a rendered manifest declares, it doesn't force
everything into the release's `targetNamespace`. `VGW_S3_IAM_ENDPOINT`'s
host and `gateway.virtualDomain` are both `external-services.svc.cluster.local`
instead of anything under the `versitygw` namespace.

This is deliberately **not** an Istio ServiceEntry (the tool for something
genuinely outside Kubernetes' registry, e.g.
[truenas](../../../apps/external-services/truenas/templates/service.yaml)'s
bare LAN IP — not the case here, the target is Kubernetes-tracked pods) and
**not** a same-namespace Service (attempt 2's mistake). `ExternalName` is
the plain, native mechanism for "give this real in-cluster thing a second,
different name," and putting it in a different namespace is what actually
breaks the collision: `versitygw.versitygw.svc.cluster.local` shares no
suffix with `external-services.svc.cluster.local`, so `HostStyleParser`
never touches it. Verified against every real Host this gateway serves
(`versitygw.versitygw.svc.cluster.local`, `s3.versitygw.schober.dev`,
`admin.…`, `web.…`) — none match; only the intended
`iam.external-services.svc.cluster.local` does.

Note: the gateway runs with `replicaCount: 3` behind a single Service, and
neither the internal nor the S3 IAM backend coordinate writes across
replicas — each pod only locks in-process. Send account-management calls
(create/update/delete access keys) consistently, and avoid firing concurrent
admin requests at different pods, to avoid a lost update.

---

## Per-client credentials via a Helm list

[create-user-job.example.yaml](create-user-job.example.yaml) is a
standalone reference (`curl --aws-sigv4`, no `versitygw` binary or
`aws-cli` needed — HTTP 201/409 both count as success). The actual,
deployed version of that idea lives in
[templates/cnpg-client-credentials.yaml](templates/cnpg-client-credentials.yaml),
templated from `.Values.cnpgClients` (a plain list of app names, set in
[helmrelease.yaml](helmrelease.yaml)) rather than copy-pasted per app.

**Why this runs here, in the versitygw namespace, and not in each
consuming app's own namespace:** the naive version needs each app's
namespace to hold its own copy of the root credentials, so its
`create-user` Job can authenticate — that's root credentials duplicated
into every namespace that ever provisions an account, real secret sprawl
for no benefit. Root credentials already live in this namespace
(`versitygw-credentials`) — running everything (generator, `create-user`
Job, `PushSecret`) here means they never need
to leave it. Every consuming app then needs nothing more than a plain
`ExternalSecret` pulling its own key back down from Bitwarden — the exact
same shape every app's `backup-secret.yaml` already used for the shared
root credentials, just repointed at a per-app key (see
[authentik's backup-secret.yaml](../../authentik/authentik/templates/backup-secret.yaml)
for the worked example).

Per app, this generates a `Password` generator + a `CreatedOnce`
`ExternalSecret` (one stable local Secret, never silently regenerated), a
`create-user` Job reading it, and a `PushSecret` pushing the same Secret's
values to Bitwarden. The Job and the `PushSecret` deliberately both read
from that *same* local Secret rather than either one calling the generator
directly — a generator is a stateless factory, so two independent calls to
it could produce two different random values, desyncing what's in
Bitwarden from what versitygw actually has registered.

Verified end-to-end against the real `authentik-backup` account and the
real `cnpg-backups` bucket (not a throwaway):
`GET`ting an actual existing WAL object with the new credential returned
`200`; writing into `grafana`'s prefix (not yet provisioned) returned `403`
(access denied, not 404 — the isolation from the section below is real);
root's own WAL archiving kept succeeding throughout, untouched, since root
bypasses policy evaluation entirely.

---

## Sharing one bucket across clients (e.g. all CNPG backups)

`cnpg-backups` currently holds every CNPG cluster's backups under a
per-app prefix (`cnpg-backups/<app>/<app>-postgres/...`), and every app
authenticates with the same **root** credentials to write there —
i.e. no real per-app isolation exists yet, despite each app having its own
`user`-role account available (see above).

Two ways to fix that were considered:

1. **One dedicated bucket per app**, each owned by that app's own access
   key (a `user`-role account already has full access to buckets it
   owns — no policy needed). Rejected: every CNPG cluster would need to
   start writing to a brand-new, empty bucket, losing continuity with the
   existing base backups under the current prefixes until a fresh base
   backup completes.
2. **Keep the one shared bucket**, and use a **bucket policy** to grant
   each app's access key permission on just its own prefix. No data
   migration, and — verified below — this gives the *same* isolation as
   separate buckets would.

Went with (2). Verified end-to-end against a throwaway bucket/accounts
before touching the real one (all cleaned up afterward, nothing left on
the cluster):

| Test | Result |
|---|---|
| `test-app-a` PUT/GET its own prefix (`test-shared-bucket/app-a/*`) | `200` |
| `test-app-a` PUT into `test-app-b`'s prefix | `403 AccessDenied` |
| `test-app-b` GET from `test-app-a`'s prefix | `403 AccessDenied` |
| Shared, bucket-wide `ListBucket` grant for both principals | `200`, sees both apps' keys |
| `Condition: {"StringLike": {"s3:prefix": ["app-a/*"]}}` meant to scope `ListBucket` to just that app's prefix | **silently not enforced** — `test-app-a` still got `200` listing with no prefix at all, and even with `prefix=app-b/` explicitly |

Bucket policies are **resource-based**, so — unlike identity policies —
they work regardless of IAM backend (`internal` or `s3`); only
identity-policy grants need the separate `standalone` IAM backend. This is
why option (2) works today with no other config change. `Resource`
wildcards (`arn:aws:s3:::cnpg-backups/<app>/*`) are matched and enforced
correctly for object actions — verified above. `Condition` blocks are
*accepted* by `PutBucketPolicy` (no validation error) but not actually
evaluated, at least for `s3:prefix`/`StringLike` — don't rely on them for
anything security-relevant. Practical consequence: `s3:ListBucket` has to
be granted bucket-wide to the whole set of backup principals as a group —
every app can see the other apps' object *keys*, but not read or write
their *contents*.

### The policy

Bucket policies are **replace, not merge** — the whole document has to be
re-declared, with one statement per app, every time a new app onboards:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": ["<app>-backup"]},
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::cnpg-backups/<app>/*"]
    },
    { "...one such statement per app..." },
    {
      "Effect": "Allow",
      "Principal": {"AWS": ["<app>-backup", "...every app's access key..."]},
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::cnpg-backups"]
    }
  ]
}
```

### Applying it

[templates/cnpg-bucket-policy.yaml](templates/cnpg-bucket-policy.yaml) is
one Job, `cnpg-backups-bucket-setup`, built from the same
`.Values.cnpgClients` list as the per-client credentials above (one
`Resource`-scoped statement per app, plus the one shared `ListBucket`
statement), authenticating as root with the same `curlimages/curl` +
`--aws-sigv4` pattern as everywhere else in this chart:

**1. Ensure the bucket exists first** — `PutBucketPolicy` on a nonexistent
bucket 404s. The admin `create-bucket` endpoint takes the owner as a
**header**, not a query param (`x-vgw-owner: <access-key>` — a query param
here 500s, it doesn't 400; this cost real debugging time), and the bucket
name as a **path** segment, not a query param. `HTTP 201` (created) or a
response body containing `BucketAlreadyOwnedByYou`/`BucketAlreadyExists`
both count as success.

**2. Re-apply the full policy document** — plain `PutBucketPolicy`, the
standard S3 API (not the admin API), on the S3 port. Bucket policies are
**replace, not merge**, so the whole document is re-declared every run,
not just the one app that changed.

**A real race, found by testing this against production rather than
assuming it would work:** `PutBucketPolicy` validates that every
`Principal` names an *existing* account (`400 MalformedPolicy: Invalid
principal in policy` otherwise) — and this Job has no ordering guarantee
relative to each app's own `create-user` Job from
`cnpg-client-credentials.yaml`. Deploying both at once raced in exactly
this way: the policy Job ran and failed validation before `create-user`
had finished creating `authentik-backup`, and only passed on a second
attempt because Kubernetes' own Job-level pod-restart backoff happened to
retry after the account existed by then — an accident, not a guarantee,
and it could genuinely exhaust its retries under load. Fixed with an
explicit, bounded retry loop around just the `PutBucketPolicy` call (10
attempts, 3s apart), rather than relying on that accident.
