SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

CLUSTER_NAME     ?= talos
TALOS_VERSION    ?= v1.14.0
FACTORY_URL      ?= https://factory.talos.dev
PLATFORM         ?= metal
ARCH             ?= amd64

VIP              ?= 10.1.40.10
CTRL01_IP        ?= 10.1.40.11
CTRL02_IP        ?= 10.1.40.12
CTRL03_IP        ?= 10.1.40.13
CLUSTER_ENDPOINT ?= https://$(VIP):6443

GENERATED := generated
TALOSCONFIG := $(GENERATED)/talosconfig
SECRETS    := $(GENERATED)/secrets.yaml

.DEFAULT_GOAL := help

.PHONY: help schematic-id iso-url render genconfig \
        apply apply-all validate \
        bootstrap kubeconfig health flux bitwarden-secret cluster clean

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*## "}; {printf "%-18s %s\n", $$1, $$2}'

schematic-id: ## Look up the Image Factory schematic ID for image/schematic.yaml
	mkdir -p $(GENERATED)
	FACTORY_URL=$(FACTORY_URL) ./scripts/schematic-id.sh > $(GENERATED)/schematic-id.txt
	@echo "Schematic ID: $$(cat $(GENERATED)/schematic-id.txt)"

iso-url: schematic-id ## Print the metal ISO URL to download and flash to a USB stick
	@echo "$(FACTORY_URL)/image/$$(cat $(GENERATED)/schematic-id.txt)/$(TALOS_VERSION)/$(PLATFORM)-$(ARCH).iso"

render: schematic-id ## Render the dynamic patches (install image + Cilium inline manifests)
	TALOS_VERSION=$(TALOS_VERSION) python3 scripts/render-patches.py

$(SECRETS): ## Persist cluster secrets ONCE (extracted from an existing controlplane.yaml if present)
	mkdir -p $(GENERATED)
	@if [ -f "$(GENERATED)/controlplane.yaml" ]; then \
	  echo "Reusing secrets already embedded in $(GENERATED)/controlplane.yaml"; \
	  talosctl gen secrets --from-controlplane-config "$(GENERATED)/controlplane.yaml" -o $@; \
	else \
	  echo "Generating fresh cluster secrets"; \
	  talosctl gen secrets -o $@; \
	fi

# Always reuses $(SECRETS) — regenerating cluster CAs and applying them to a
# bootstrapped node would rotate its identity and break the running cluster.
genconfig: $(SECRETS) ## Generate base controlplane/worker config + talosconfig (reuses persisted secrets)
	talosctl gen config $(CLUSTER_NAME) $(CLUSTER_ENDPOINT) --with-secrets $(SECRETS) --output-dir $(GENERATED) --force

# Requires the target node to already be booted from the USB stick into
# Talos maintenance mode and reachable at its static IP (set a DHCP
# reservation for its MAC so maintenance mode already gets that IP).
apply: render genconfig ## Apply config to one node: make apply NODE=ctrl-01 [IP=10.1.40.11]
	@if [ -z "$(NODE)" ]; then \
	  echo "Usage: make apply NODE=ctrl-01 [IP=10.1.40.11]" >&2; exit 1; \
	fi
	@ip="$(IP)"; \
	if [ -z "$$ip" ]; then \
	  case "$(NODE)" in \
	    ctrl-01) ip="$(CTRL01_IP)" ;; \
	    ctrl-02) ip="$(CTRL02_IP)" ;; \
	    ctrl-03) ip="$(CTRL03_IP)" ;; \
	    *) echo "Unknown NODE '$(NODE)', pass IP=... explicitly" >&2; exit 1 ;; \
	  esac; \
	fi; \
	talosctl apply-config --insecure --nodes "$$ip" \
	  --file $(GENERATED)/controlplane.yaml \
	  --config-patch @patches/machine.yaml \
	  --config-patch @$(GENERATED)/install-image.yaml \
	  --config-patch @patches/controlplane.yaml \
	  --config-patch @$(GENERATED)/cilium-inline-manifests.yaml \
	  --config-patch @patches/nodes/$(NODE).yaml

# Offline dry-run of the same patch stack `apply` pushes: merges the patches
# into the base config and validates the result, without touching a node.
validate: render genconfig ## Validate the merged config for all 3 nodes offline (no node needed)
	@for node in ctrl-01 ctrl-02 ctrl-03; do \
	  talosctl machineconfig patch $(GENERATED)/controlplane.yaml \
	    --patch @patches/machine.yaml \
	    --patch @$(GENERATED)/install-image.yaml \
	    --patch @patches/controlplane.yaml \
	    --patch @$(GENERATED)/cilium-inline-manifests.yaml \
	    --patch @patches/nodes/$$node.yaml \
	    -o $(GENERATED)/merged-$$node.yaml; \
	  talosctl validate -m metal -c $(GENERATED)/merged-$$node.yaml; \
	done

apply-all: render genconfig ## Apply config to all 3 control-plane nodes
	$(MAKE) apply NODE=ctrl-01 IP=$(CTRL01_IP)
	$(MAKE) apply NODE=ctrl-02 IP=$(CTRL02_IP)
	$(MAKE) apply NODE=ctrl-03 IP=$(CTRL03_IP)

# `talosctl gen config` writes a talosconfig with an empty `endpoints: []`, so
# every talosctl call has to name an endpoint explicitly or it fails with
# "failed to determine endpoints". Endpoints are always the real per-node IPs,
# never the VIP - see the note at the top of README.md.
bootstrap: ## Bootstrap etcd on the first control-plane node (one-time)
	talosctl --talosconfig $(TALOSCONFIG) bootstrap \
	  --endpoints $(CTRL01_IP) --nodes $(CTRL01_IP)

kubeconfig: ## Fetch the kubeconfig into generated/kubeconfig
	talosctl --talosconfig $(TALOSCONFIG) kubeconfig \
	  --endpoints $(CTRL01_IP) --nodes $(CTRL01_IP) --force $(GENERATED)

# `--nodes` is the single node the check runs FROM (talosctl rejects more than
# one); `--control-plane-nodes` is the set being checked.
health: ## Wait for the cluster to report healthy
	talosctl --talosconfig $(TALOSCONFIG) health \
	  --endpoints $(CTRL01_IP),$(CTRL02_IP),$(CTRL03_IP) \
	  --nodes $(CTRL01_IP) \
	  --control-plane-nodes $(CTRL01_IP),$(CTRL02_IP),$(CTRL03_IP)

flux: ## Install/upgrade the Flux Operator and apply the Flux bootstrap kustomization (safe to re-run)
	KUBECONFIG=$(GENERATED)/kubeconfig helm upgrade --install flux-operator \
	  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
	  -n flux-system --create-namespace
	# The FluxInstance must be applied and reconciled FIRST: the operator
	# installs the Flux controllers and their CRDs, and infra.yaml is a
	# kustomize.toolkit.fluxcd.io Kustomization that cannot be applied until
	# that CRD exists. Applying the whole directory in one shot races.
	KUBECONFIG=$(GENERATED)/kubeconfig kubectl apply --server-side \
	  -f ../k8s/bootstrap/flux/flux-instance.yaml
	KUBECONFIG=$(GENERATED)/kubeconfig kubectl -n flux-system wait fluxinstance/flux \
	  --for=condition=Ready --timeout=5m
	KUBECONFIG=$(GENERATED)/kubeconfig kubectl wait \
	  --for=create crd/kustomizations.kustomize.toolkit.fluxcd.io --timeout=2m
	KUBECONFIG=$(GENERATED)/kubeconfig kubectl apply --server-side -k ../k8s/bootstrap/flux

bitwarden-secret: ## Create the Bitwarden access-token secret used by external-secrets (needs BITWARDEN_ACCESS_TOKEN)
	KUBECONFIG=$(GENERATED)/kubeconfig ./scripts/create-bitwarden-secret.sh

cluster: apply-all bootstrap health flux ## Full bring-up once all 3 nodes are booted in maintenance mode

clean: ## Remove generated files (WARNING: deletes cluster secrets, kubeconfig, talosconfig)
	rm -rf $(GENERATED)
