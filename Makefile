# HomeCluster Makefile
# Native alternative to go-task (Taskfile)

# =============================================================================
# VARIABLES
# =============================================================================

# Directories
ROOT_DIR := $(shell pwd)
BOOTSTRAP_DIR := $(ROOT_DIR)/bootstrap
KUBERNETES_DIR := $(ROOT_DIR)/kubernetes
PRIVATE_DIR := $(ROOT_DIR)/.private
SCRIPTS_DIR := $(ROOT_DIR)/scripts
TF_PROXMOX_DIR := $(ROOT_DIR)/provision/terraform/proxmox

# Files
AGE_FILE := ~/.config/sops/age/keys.txt
BOOTSTRAP_CONFIG_FILE := $(ROOT_DIR)/config.yaml
KUBECONFIG_FILE := ~/.kube/config
MAKEJINJA_CONFIG_FILE := $(ROOT_DIR)/makejinja.toml
PIP_REQUIREMENTS_FILE := $(ROOT_DIR)/requirements.txt
SOPS_CONFIG_FILE := $(ROOT_DIR)/.sops.yaml

# Binaries
PYTHON_BIN := python3
VIRTUAL_ENV := $(ROOT_DIR)/.venv)

# Flux-specific paths
CLUSTER_SECRET_SOPS_FILE := $(KUBERNETES_DIR)/flux/vars/cluster-secrets.sops.yaml
CLUSTER_SETTINGS_FILE := $(KUBERNETES_DIR)/flux/vars/cluster-settings.yaml
GITHUB_DEPLOY_KEY_FILE := $(KUBERNETES_DIR)/bootstrap/flux/github-deploy-key.sops.yaml

# Workstation paths
BREWFILE := $(ROOT_DIR)/.taskfiles/Workstation/Brewfile
ARCHFILE := $(ROOT_DIR)/.taskfiles/Workstation/Archfile
GENERIC_BIN_DIR := $(ROOT_DIR)/.bin

# Environment exports
export KUBECONFIG := $(KUBECONFIG_FILE)
export PYTHONDONTWRITEBYTECODE := 1
export SOPS_AGE_KEY_FILE := $(AGE_FILE)
export VIRTUAL_ENV := $(VIRTUAL_ENV)

# Colors for output (optional)
BLUE := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
RED := \033[31m
NC := \033[0m # No Color

# =============================================================================
# DEFAULT TARGET
# =============================================================================

.PHONY: default
default: help

# =============================================================================
# HELP
# =============================================================================

.PHONY: help
help: ## Show this help message
	@echo "HomeCluster Makefile"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  $(BLUE)%-30s$(NC) %s\n", $$1, $$2}' $(MAKEFILE_LIST) | sort
	@echo ""
	@echo "For targets requiring arguments (like 'path=ns/app'), use:"
	@echo "  make flux-apply path=ns/app"

# =============================================================================
# CONFIGURATION
# =============================================================================

.PHONY: init
init: ## Initialize configuration files
	@if [ ! -f $(BOOTSTRAP_CONFIG_FILE) ]; then \
		cp -n $(subst .yaml,.sample.yaml,$(BOOTSTRAP_CONFIG_FILE)) $(BOOTSTRAP_CONFIG_FILE); \
		echo "=== Configuration file copied ==="; \
		echo "Proceed with updating the configuration files..."; \
		echo $(BOOTSTRAP_CONFIG_FILE); \
	else \
		echo "Configuration file already exists at $(BOOTSTRAP_CONFIG_FILE)"; \
	fi

.PHONY: configure
define CONFIGURE_PROMPT
WARNING: Any conflicting config in the kubernetes directory will be overwritten.
Continue? [y/N]
endef
export CONFIGURE_PROMPT

configure: init workstation-direnv workstation-venv sops-age-keygen ## Configure repository from bootstrap vars
	@echo "$$CONFIGURE_PROMPT" && read -r response && [ "$$response" = "y" ] && $(MAKE) .template sops-encrypt .validate || echo "Aborted"

.PHONY: .template
.template: ## Internal: Run makejinja templating
	@test -d $(VIRTUAL_ENV) || (echo "Missing virtual environment" && exit 1)
	@test -f $(MAKEJINJA_CONFIG_FILE) || (echo "Missing Makejinja config file" && exit 1)
	@test -f $(BOOTSTRAP_DIR)/scripts/plugin.py || (echo "Missing Makejinja plugin file" && exit 1)
	@test -f $(BOOTSTRAP_CONFIG_FILE) || (echo "Missing bootstrap config file" && exit 1)
	$(VIRTUAL_ENV)/bin/makejinja

.PHONY: .validate
.validate: ## Internal: Validate rendered configuration
	$(MAKE) kubernetes-kubeconform
	@echo "=== Done rendering and validating YAML ==="
	@if [ "$$KUBECONFIG" != "$(KUBECONFIG_FILE)" ]; then \
		echo "WARNING: KUBECONFIG is not set to the expected value, this may cause conflicts."; \
	fi
	@if [ "$$SOPS_AGE_KEY_FILE" != "$(AGE_FILE)" ]; then \
		echo "WARNING: SOPS_AGE_KEY_FILE is not set to the expected value, this may cause conflicts."; \
	fi
	@if test -f ~/.config/sops/age/keys.txt; then \
		echo "WARNING: SOPS Age key found in home directory, this may cause conflicts."; \
	fi

# =============================================================================
# WORKSTATION
# =============================================================================

.PHONY: workstation-direnv
workstation-direnv: ## Run direnv hooks
	@direnv allow .

.PHONY: workstation-venv
workstation-venv: $(VIRTUAL_ENV)/pyvenv.cfg ## Set up virtual environment

$(VIRTUAL_ENV)/pyvenv.cfg: $(PIP_REQUIREMENTS_FILE)
	$(PYTHON_BIN) -m venv $(VIRTUAL_ENV)
	$(VIRTUAL_ENV)/bin/python3 -m pip install --upgrade pip setuptools wheel
	$(VIRTUAL_ENV)/bin/python3 -m pip install --upgrade --requirement $(PIP_REQUIREMENTS_FILE)

.PHONY: workstation-brew
workstation-brew: ## Install workstation dependencies with Brew
	@test -f $(BREWFILE) || (echo "Missing Brewfile" && exit 1)
	@command -v brew >/dev/null 2>&1 || (echo "Homebrew is not installed" && exit 1)
	brew bundle --file $(BREWFILE)

.PHONY: workstation-arch
workstation-arch: ## Install Arch workstation dependencies with Paru or Yay
	@test -f $(ARCHFILE) || (echo "Missing Archfile" && exit 1)
	@helper=$$(command -v yay || command -v paru) && [ -n "$$helper" ] || (echo "Neither yay nor paru found" && exit 1)
	$$helper -Syu --needed --noconfirm --noprogressbar $$(cat $(ARCHFILE) | xargs)

.PHONY: workstation-generic-linux
workstation-generic-linux: ## Install CLI tools into the projects .bin directory using curl
	@mkdir -p $(GENERIC_BIN_DIR)
	@cd $(GENERIC_BIN_DIR) && \
	for tool in "budimanjojo/talhelper?as=talhelper&type=script" \
		"cloudflare/cloudflared?as=cloudflared&type=script" \
		"FiloSottile/age?as=age&type=script" \
		"fluxcd/flux2?as=flux&type=script" \
		"getsops/sops?as=sops&type=script" \
		"helmfile/helmfile?as=helmfile&type=script" \
		"jqlang/jq?as=jq&type=script" \
		"kubernetes-sigs/kustomize?as=kustomize&type=script" \
		"siderolabs/talos?as=talosctl&type=script" \
		"yannh/kubeconform?as=kubeconform&type=script" \
		"mikefarah/yq?as=yq&type=script"; do \
		curl -fsSL "https://i.jpillora.com/$$tool" | bash; \
	done
	@cd $(GENERIC_BIN_DIR) && \
	curl -LO "https://dl.k8s.io/release/$$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
	chmod +x kubectl
	@cd $(GENERIC_BIN_DIR) && \
	curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | USE_SUDO="false" HELM_INSTALL_DIR="." bash

# =============================================================================
# SOPS
# =============================================================================

.PHONY: sops-age-keygen
sops-age-keygen: $(AGE_FILE) ## Initialize Age Key for Sops

$(AGE_FILE):
	@mkdir -p $(dir $(AGE_FILE))
	age-keygen --output $(AGE_FILE)

.PHONY: sops-encrypt
sops-encrypt: ## Encrypt all Kubernetes SOPS secrets
	@test -f $(SOPS_CONFIG_FILE) || (echo "Missing Sops config file" && exit 1)
	@test -f $(AGE_FILE) || (echo "Missing Sops Age key file" && exit 1)
	@find $(KUBERNETES_DIR) -type f -name "*.sops.*" -exec grep -L "ENC\[AES256_GCM" {} \; | while read file; do \
		echo "Encrypting: $$file"; \
		sops --encrypt --in-place "$$file"; \
	done

.PHONY: sops-decrypt
sops-decrypt: ## Decrypt all Kubernetes SOPS secrets
	@find $(KUBERNETES_DIR) -type f -name "*.sops.*" | while read file; do \
		echo "Decrypting: $$file"; \
		sops --decrypt --in-place "$$file" || true; \
	done

# =============================================================================
# KUBERNETES
# =============================================================================

.PHONY: kubernetes-resources
kubernetes-resources: ## Gather common resources in your cluster
	@echo "=== Nodes ==="
	@kubectl get nodes
	@echo ""
	@echo "=== GitRepositories ==="
	@kubectl get gitrepositories -A
	@echo ""
	@echo "=== Kustomizations ==="
	@kubectl get kustomizations -A
	@echo ""
	@echo "=== HelmRepositories ==="
	@kubectl get helmrepositories -A
	@echo ""
	@echo "=== HelmReleases ==="
	@kubectl get helmreleases -A
	@echo ""
	@echo "=== Certificates ==="
	@kubectl get certificates -A
	@echo ""
	@echo "=== CertificateRequests ==="
	@kubectl get certificaterequests -A
	@echo ""
	@echo "=== Ingresses ==="
	@kubectl get ingresses -A
	@echo ""
	@echo "=== Pods ==="
	@kubectl get pods -A

.PHONY: kubernetes-kubeconform
kubernetes-kubeconform: ## Validate Kubernetes manifests with kubeconform
	@test -f $(SCRIPTS_DIR)/kubeconform.sh || (echo "Missing kubeconform script" && exit 1)
	@bash $(SCRIPTS_DIR)/kubeconform.sh $(KUBERNETES_DIR)

.PHONY: kubernetes-ceph-validate
kubernetes-ceph-validate: ## Validate Rook-Ceph configuration and deployment status
	@test -f $(SCRIPTS_DIR)/validate-ceph-setup.sh || (echo "Missing Ceph validation script" && exit 1)
	@bash $(SCRIPTS_DIR)/validate-ceph-setup.sh

.PHONY: kubernetes-ceph-status
kubernetes-ceph-status: ## Get detailed Ceph cluster status
	@kubectl get pods -n rook-ceph
	@kubectl get cephcluster -n rook-ceph
	@kubectl get storageclass | grep ceph
	@kubectl get cephobjectstore -n rook-ceph 2>/dev/null || echo "No object stores found"

.PHONY: kubernetes-ceph-health
kubernetes-ceph-health: ## Check Ceph cluster health using toolbox
	@kubectl get deployment -n rook-ceph rook-ceph-tools >/dev/null 2>&1 || (echo "Ceph tools pod not found" && exit 1)
	@kubectl exec -n rook-ceph deployment/rook-ceph-tools -- ceph status

# =============================================================================
# FLUX
# =============================================================================

.PHONY: flux-bootstrap
flux-bootstrap: ## Bootstrap Flux into a Kubernetes cluster
	@test -f $(KUBECONFIG_FILE) || (echo "Missing kubeconfig" && exit 1)
	@test -f $(AGE_FILE) || (echo "Missing Sops Age key file" && exit 1)
	@sops --decrypt $(CLUSTER_SECRET_SOPS_FILE) | kubectl apply --server-side --filename -
	@kubectl apply --server-side --filename $(CLUSTER_SETTINGS_FILE)
	@kubectl apply --server-side --kustomize $(KUBERNETES_DIR)/flux/config

.PHONY: flux-apply
flux-apply: ## Apply a Flux Kustomization resource for a cluster (requires: path=ns/app [ns=flux-system])
	@if [ -z "$(path)" ]; then \
		echo "Error: path argument required (e.g., path=ns/app)"; \
		echo "Usage: make flux-apply path=ns/app [ns=flux-system]"; \
		exit 1; \
	fi
	@ns="$(or $(ns),flux-system)"; \
	app_name=$$(basename $(path)); \
	kubectl apply --server-side --field-manager=kustomize-controller -f - \
		< <(flux --kubeconfig $(KUBECONFIG_FILE) build ks $$app_name \
			--namespace $$ns \
			--kustomization-file $(KUBERNETES_DIR)/apps/$(path)/ks.yaml \
			--path $(KUBERNETES_DIR)/apps/$(path))

.PHONY: flux-reconcile
flux-reconcile: ## Force update Flux to pull in changes from your Git repository
	@test -f $(KUBECONFIG_FILE) || (echo "Missing kubeconfig" && exit 1)
	@flux --kubeconfig $(KUBECONFIG_FILE) reconcile --namespace flux-system kustomization cluster --with-source

.PHONY: flux-github-deploy-key
flux-github-deploy-key: ## Apply GitHub deploy key to cluster
	@test -f $(KUBECONFIG_FILE) || (echo "Missing kubeconfig" && exit 1)
	@test -f $(AGE_FILE) || (echo "Missing Sops Age key file" && exit 1)
	@test -f $(GITHUB_DEPLOY_KEY_FILE) || (echo "Missing Github deploy key file" && exit 1)
	@kubectl create namespace flux-system --dry-run=client -o yaml | kubectl --kubeconfig $(KUBECONFIG_FILE) apply --filename -
	@sops --decrypt $(GITHUB_DEPLOY_KEY_FILE) | kubectl apply --kubeconfig $(KUBECONFIG_FILE) --server-side --filename -

# =============================================================================
# TERRAFORM/OPENTOFU
# =============================================================================

.PHONY: terraform-proxmox-refresh
terraform-proxmox-refresh: ## Refresh terraform
	@cd $(TF_PROXMOX_DIR) && tofu refresh

.PHONY: terraform-proxmox-init
terraform-proxmox-init: ## Initialize proxmox terraform
	@cd $(TF_PROXMOX_DIR) && tofu init -upgrade

.PHONY: terraform-proxmox-plan
terraform-proxmox-plan: ## Plan Proxmox VM creation
	@cd $(TF_PROXMOX_DIR) && tofu plan

.PHONY: terraform-proxmox-apply
terraform-proxmox-apply: ## Create Proxmox VMs
	@cd $(TF_PROXMOX_DIR) && tofu apply -auto-approve

.PHONY: terraform-proxmox-destroy
terraform-proxmox-destroy: ## Destroy all the k8s nodes
	@cd $(TF_PROXMOX_DIR) && tofu destroy

# =============================================================================
# SCRIPTS
# =============================================================================

.PHONY: scripts-add-schemas
scripts-add-schemas: ## Add YAML schema annotations to Kubernetes manifests
	@test -f $(SCRIPTS_DIR)/add-yaml-schemas.sh || (echo "Script not found at $(SCRIPTS_DIR)/add-yaml-schemas.sh" && exit 1)
	@bash $(SCRIPTS_DIR)/add-yaml-schemas.sh $(ARGS)

.PHONY: scripts-extract-ips
scripts-extract-ips: ## Extract hardcoded IPs to cluster-wide variables
	@test -f $(SCRIPTS_DIR)/extract-ips-to-vars.sh || (echo "Script not found at $(SCRIPTS_DIR)/extract-ips-to-vars.sh" && exit 1)
	@bash $(SCRIPTS_DIR)/extract-ips-to-vars.sh $(ARGS)

.PHONY: scripts-validate-schemas
scripts-validate-schemas: ## Validate YAML files against their schema annotations
	@test -f $(SCRIPTS_DIR)/validate-yaml-schemas.sh || (echo "Script not found at $(SCRIPTS_DIR)/validate-yaml-schemas.sh" && exit 1)
	@bash $(SCRIPTS_DIR)/validate-yaml-schemas.sh $(ARGS)

.PHONY: scripts-standardize-helmreleases
scripts-standardize-helmreleases: ## Standardize HelmRelease specifications
	@test -f $(SCRIPTS_DIR)/standardize-helmreleases.sh || (echo "Script not found at $(SCRIPTS_DIR)/standardize-helmreleases.sh" && exit 1)
	@bash $(SCRIPTS_DIR)/standardize-helmreleases.sh $(ARGS)

.PHONY: scripts-standardize-namespaces
scripts-standardize-namespaces: ## Standardize namespace labels
	@test -f $(SCRIPTS_DIR)/standardize-namespace-labels.sh || (echo "Script not found at $(SCRIPTS_DIR)/standardize-namespace-labels.sh" && exit 1)
	@bash $(SCRIPTS_DIR)/standardize-namespace-labels.sh $(ARGS)

# =============================================================================
# CLUSTER
# =============================================================================

.PHONY: cluster-verify
cluster-verify: ## Verify flux meets the prerequisites
	@flux check --pre

.PHONY: cluster-install
cluster-install: ## Install Flux into your cluster
	@test -f $(AGE_FILE) || (echo "Age key file is not found. Did you forget to create it?" && exit 1)
	@kubectl apply --kustomize $(KUBERNETES_DIR)/bootstrap
	@cat $(AGE_FILE) | kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=/dev/stdin
	@sops --decrypt $(KUBERNETES_DIR)/flux/vars/cluster-secrets.sops.yaml | kubectl apply -f -
	@sops --decrypt $(KUBERNETES_DIR)/flux/vars/cluster-secrets-user.sops.yaml | kubectl apply -f -
	@kubectl apply -f $(KUBERNETES_DIR)/flux/vars/cluster-settings.yaml
	@kubectl apply -f $(KUBERNETES_DIR)/flux/vars/cluster-settings-user.yaml
	@kubectl apply --kustomize $(KUBERNETES_DIR)/flux/config

.PHONY: cluster-reconcile
cluster-reconcile: ## Force update Flux to pull in changes from your Git repository
	@flux reconcile -n flux-system kustomization cluster --with-source

.PHONY: cluster-hr-restart
cluster-hr-restart: ## Restart all failed Helm Releases
	@kubectl get hr --all-namespaces | grep False | awk '{print $$2, $$1}' | xargs -L1 bash -c 'flux suspend hr $$0 -n $$1'
	@kubectl get hr --all-namespaces | grep False | awk '{print $$2, $$1}' | xargs -L1 bash -c 'flux resume hr $$0 -n $$1'

.PHONY: cluster-nodes
cluster-nodes: ## List all the nodes in your cluster
	@kubectl get nodes -o wide

.PHONY: cluster-pods
cluster-pods: ## List all the pods in your cluster
	@kubectl get pods -A

.PHONY: cluster-kustomizations
cluster-kustomizations: ## List all the kustomizations in your cluster
	@kubectl get kustomizations -A

.PHONY: cluster-helmreleases
cluster-helmreleases: ## List all the helmreleases in your cluster
	@kubectl get helmreleases -A

.PHONY: cluster-helmrepositories
cluster-helmrepositories: ## List all the helmrepositories in your cluster
	@kubectl get helmrepositories -A

.PHONY: cluster-gitrepositories
cluster-gitrepositories: ## List all the gitrepositories in your cluster
	@kubectl get gitrepositories -A

.PHONY: cluster-certificates
cluster-certificates: ## List all the certificates in your cluster
	@kubectl get certificates -A
	@kubectl get certificaterequests -A

.PHONY: cluster-ingresses
cluster-ingresses: ## List all the ingresses in your cluster
	@kubectl get ingress -A

.PHONY: cluster-resources
cluster-resources: cluster-nodes cluster-kustomizations cluster-helmreleases cluster-helmrepositories cluster-gitrepositories cluster-certificates cluster-ingresses cluster-pods ## Gather common resources in your cluster

# =============================================================================
# LOCAL TASKS
# =============================================================================

.PHONY: local-sops-encrypt
local-sops-encrypt: ## Encrypt all sops (local variant with age key from file)
	@cd $(KUBERNETES_DIR) && \
	find . -maxdepth 8 -name "*.sops.yaml" | xargs -L1 sops --encrypt --age $$(rg -ioP "public key: \K(.*$$)" $(SOPS_AGE_KEY_FILE)) -i

.PHONY: local-sops-decrypt
local-sops-decrypt: ## Decrypt all sops (local variant with age key from file)
	@cd $(KUBERNETES_DIR) && \
	find . -maxdepth 8 -name "*.sops.yaml" | xargs -L1 sops --decrypt --age $$(rg -ioP "public key: \K(.*$$)" $(SOPS_AGE_KEY_FILE)) -i

# =============================================================================
# BREW TASKS
# =============================================================================

BREW_DEPS := age cilium-cli cloudflared fluxcd/tap/flux helm jq k9s kubernetes-cli kustomize sops stern yq

.PHONY: brew-deps
brew-deps: ## Install workstation dependencies with Brew
	@command -v brew >/dev/null 2>&1 || (echo "Homebrew is not installed. Using MacOS, Linux or WSL? Head over to https://brew.sh to get up and running." && exit 1)
	@brew install $(BREW_DEPS)

# =============================================================================
# CLEANUP
# =============================================================================

.PHONY: clean
 clean: ## Clean generated files and virtual environment
	@rm -rf $(VIRTUAL_ENV)
	@echo "Virtual environment cleaned"

.PHONY: reset-kubernetes
reset-kubernetes: ## Remove rendered kubernetes configs
	@rm -rf $(KUBERNETES_DIR)
	@echo "Kubernetes directory cleaned"

.PHONY: reset-sops
reset-sops: ## Remove SOPS configuration
	@rm -rf $(SOPS_CONFIG_FILE)
	@echo "SOPS config cleaned"
