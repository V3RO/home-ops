# OpenCode

A long-lived [OpenCode](https://opencode.ai) server for the homelab. It runs in
the `opencode` namespace, keeps sessions and checkouts on Longhorn, and is
reachable at `https://opencode.schober.dev` through the internal Gateway.

This is deliberately a **single-user** deployment. Do not scale it: both PVCs
are `ReadWriteOnce`, and multiple replicas would mean multiple schedulers and
agent identities.

## Prerequisites

Create these items in Bitwarden (the `bitwarden-app-secrets` project) before
syncing the app:

| Bitwarden item | Purpose |
| --- | --- |
| `opencode-deepseek-api-key` | DeepSeek API key |
| `opencode-forgejo-token` | PAT for the `opencode-bot` Forgejo user |
| `opencode-server-password` | Password for the OpenCode web/API server (long random value) |
| `opencode-moonshot-api-key` | Optional. Uncomment the Kimi entry in `values.yaml` after adding it |

### Forgejo bot

Create a dedicated Forgejo user `opencode-bot` and give it access only to the
repositories the agent should work on. Create a PAT with repository read/write
scope. If your Forgejo version supports repository-scoped tokens, scope it to
those repositories; otherwise use a dedicated bot and rely on branch
protection.

Enable branch protection on `main` (no direct pushes, PR required). The bot
does not need admin, organization, Actions-secret, or user scopes.

## First start

```bash
kubectl -n opencode get pods
kubectl -n opencode logs deploy/opencode -f
```

Open `https://opencode.schober.dev` from the LAN or from a device on NetBird.
The username is `opencode`; the password is the `opencode-server-password`
item. The deployment intentionally does not add Authentik forward-auth: the
server has its own basic auth, and forward-auth would break the mobile/API
clients.

If you want to expose it publicly later, put Authentik in front of the route
and expect the mobile app pairing flow to need the browser-based path.

### Clone a repository

```bash
kubectl -n opencode exec -it deploy/opencode -- /tools/bin/bash
cd /workspace
git clone https://git.schober.dev/<org>/<repo>.git
```

The git credential helper reads `FORGEJO_TOKEN` from the environment, so the
token is not written to `~/.git-credentials` or the repository's
`.git/config`. It only answers for `git.schober.dev`, so the PAT is not sent
to GitHub or another HTTPS remote. The agent can still read its own
environment; the PAT is scoped to limit the damage.

Use HTTPS clone URLs. SSH egress is deliberately not allowed, so an
`ssh://` or `git@` remote will not work.

From a PC you can attach the TUI to the same server. Keep the local CLI in
sync with the server version (the deployment currently pins 2.2.5):

```bash
opencode attach https://opencode.schober.dev --dir /workspace/<repo>
```

## Agent behaviour

The configuration is in `templates/configmap.yaml` and
`templates/agents-configmap.yaml`:

- `coder` — default primary agent. Edits code, asks before shell commands,
  and can delegate to the subagents below.
- `planner` — read-only investigation and planning.
- `reviewer` — read-only diff review.
- `ops-triage` — read-only `kubectl` access for pod logs, events and workload
  status.

Global rules deny reads/edits of `.env` files, deny access outside
`/workspace`, block `sudo`, `kubectl`, container runtimes and force-pushes, and
ask before arbitrary shell commands. Review these rules before enabling
unattended schedules.

### Scheduled work

`experimental.schedules` is enabled. Create the schedule in a dedicated
session with the **`ops-triage` agent selected**, so its `kubectl` permission
applies to the schedule's condition. Use `/schedule` to run a prompt daily, or
create a schedule through the API. A shell or Code Mode condition can wake the
model only when something changed, for example:

```json
{
  "sessionID": "ses_...",
  "name": "daily-log-triage",
  "when": { "cron": "0 8 * * *", "tz": "Europe/Berlin" },
  "if": {
    "run": "kubectl logs -n media --all-containers --since=24h | grep -c ERROR",
    "changes": true
  },
  "prompt": "Use the ops-triage workflow. Summarize any new errors, identify the affected workloads, and open a Forgejo issue if this is actionable."
}
```

For guaranteed execution use a Kubernetes CronJob or n8n instead, so a stopped
OpenCode pod cannot miss the run:

```bash
opencode run --server http://opencode.opencode.svc:4096 \
  --agent ops-triage --auto \
  "Scan the last 24h of logs for new errors and summarize them."
```

## Security model

What is enforced:

- Non-root UID/GID 1000, read-only root filesystem, all capabilities dropped,
  `RuntimeDefault` seccomp, no hostPath, no Docker socket.
- Cilium egress allowlist: Forgejo, DeepSeek/Moonshot, the Kubernetes API and
  common package registries only. Everything else is denied.
- Ingress only from the internal Gateway and host probes.
- OpenCode permission rules for shell, edits, `.env` files and external paths.
- Read-only cluster RBAC for `ops-triage` (pods, logs, events, workloads,
  services, nodes; **no Secrets or ConfigMaps**).
- Scoped Forgejo bot PAT and branch protection.

What is **not** enforced:

- The permission rules are guardrails, not a security boundary. A shell
  command runs with the container's authority, and the agent can read its own
  environment, including `FORGEJO_TOKEN` and the model API keys.
- This is a container sandbox, not a VM. If you want a stronger boundary, add a
  Talos `gvisor` system extension and run this pod with
  `runtimeClassName: gvisor`.
- Longhorn persistence is not a backup. Uncommitted work and session history
  are only as safe as the Longhorn volume. Add a Longhorn/VolSync backup if
  that matters.

To remove cluster log access, set `rbac.enabled: false` in `values.yaml`; the
ServiceAccount then does not mount a token, and the `ops-triage` agent stops
working.

To narrow the network allowlist, edit `templates/networkpolicy.yaml`. Adding a
new package registry or MCP endpoint requires adding its host there as well.

## Image and tooling

The main image is the official `ghcr.io/anomalyco/opencode:2.2.5`, pinned by
digest. The upstream image intentionally contains only OpenCode, ripgrep and
the Alpine base, so `install-tools` adds `git`, `bash`, `curl`, `jq`, `kubectl`
and `tzdata` into a shared `emptyDir` at pod start. This avoids maintaining a
custom image; the trade-off is a package download on each pod start and a
dependency on `dl-cdn.alpinelinux.org`.

When OpenCode is upgraded, keep the Alpine major/minor in the init container
(`alpine:3.24.3`) aligned with the base image, or the dynamically linked tools
will not run.
