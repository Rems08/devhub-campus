SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---- Versions pinées (reproductibilité) ----
CLUSTER ?= devhub
ARGOCD_CHART_VERSION ?= 7.6.12
INGRESS_CHART_VERSION ?= 4.11.3
KUBECONFORM_K8S_VERSION ?= 1.30.0

GHCR_USER ?= rems08
SERVICES := annuaire planning notif
SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

# ---- Outillage ----
REQUIRED_TOOLS := docker kubectl helm kind argocd git yq

.PHONY: help
help:  ## affiche cette aide
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: tools-check
tools-check:  ## vérifie la présence + version des outils requis
	@set -e; for t in $(REQUIRED_TOOLS); do \
		command -v $$t >/dev/null 2>&1 || { echo "❌ manquant : $$t"; exit 1; }; \
	done
	@echo "✅ tous les outils sont présents"
	@docker version --format '  docker  : {{.Server.Version}}' 2>/dev/null || true
	@kubectl version --client 2>/dev/null | head -1 | sed 's/^/  kubectl : /'
	@helm version --short | sed 's/^/  helm    : /'
	@kind --version | sed 's/^/  /'
	@argocd version --client 2>/dev/null | head -1 | sed 's/^/  /'

# ---- Cluster local ----
.PHONY: cluster-up
cluster-up:  ## démarre le cluster kind à 2 nœuds
	kind create cluster --name $(CLUSTER) --config cluster/kind-config.yaml
	@echo "✅ cluster prêt — contexte courant : kind-$(CLUSTER)"

.PHONY: cluster-down
cluster-down:  ## détruit le cluster kind
	kind delete cluster --name $(CLUSTER)

# ---- ArgoCD ----
.PHONY: argocd-install
argocd-install:  ## installe ingress-nginx + ArgoCD via Helm
	helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
	helm repo update
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
		--namespace ingress-nginx --create-namespace \
		--version $(INGRESS_CHART_VERSION) \
		--set controller.service.type=NodePort \
		--set-string controller.nodeSelector."ingress-ready"=true \
		--set "controller.tolerations[0].key=node-role.kubernetes.io/control-plane" \
		--set "controller.tolerations[0].operator=Exists" \
		--set "controller.tolerations[0].effect=NoSchedule" \
		--set controller.hostPort.enabled=true \
		--set controller.publishService.enabled=false
	kubectl wait --namespace ingress-nginx \
		--for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller \
		--timeout=180s
	helm upgrade --install argocd argo/argo-cd \
		--namespace argocd --create-namespace \
		--version $(ARGOCD_CHART_VERSION) \
		-f platform/argocd/values.yaml
	kubectl -n argocd rollout status deploy/argocd-server --timeout=180s

.PHONY: argocd-password
argocd-password:  ## affiche le mot de passe admin initial (À ROTATER)
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: bootstrap
bootstrap:  ## SEUL kubectl apply du TP : crée la root Application
	kubectl apply -f platform/projects/devhub.yaml
	kubectl apply -f platform/bootstrap/root-app.yaml
	@echo "✅ root Application créée — observez la propagation dans l'UI ArgoCD"

.PHONY: hosts-print
hosts-print:  ## affiche les lignes à ajouter dans /etc/hosts
	@echo "Ajoutez ces lignes à votre fichier hosts :"
	@echo "  macOS/Linux : /etc/hosts"
	@echo "  Windows     : C:\\Windows\\System32\\drivers\\etc\\hosts"
	@echo ""
	@echo "127.0.0.1  argocd.devhub.local"
	@echo "127.0.0.1  annuaire.devhub.local"
	@echo "127.0.0.1  planning.devhub.local"
	@echo "127.0.0.1  notif.devhub.local"

# ---- Images ----
.PHONY: images
images:  ## build des 3 images locales et tag :$(SHA)
	@for svc in $(SERVICES); do \
		echo ">>> build $$svc"; \
		docker build \
			--label org.opencontainers.image.source=https://github.com/$(GHCR_USER)/devhub-campus \
			--label org.opencontainers.image.revision=$(SHA) \
			--label org.opencontainers.image.created=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
			-t ghcr.io/$(GHCR_USER)/$$svc:$(SHA) \
			-t ghcr.io/$(GHCR_USER)/$$svc:dev \
			$$svc-service; \
	done

.PHONY: images-push
images-push: images  ## push les images sur GHCR (login préalable requis)
	@for svc in $(SERVICES); do \
		docker push ghcr.io/$(GHCR_USER)/$$svc:$(SHA); \
		docker push ghcr.io/$(GHCR_USER)/$$svc:dev; \
	done

.PHONY: images-scan
images-scan:  ## scan trivy des 3 images (HIGH/CRITICAL bloquant)
	@for svc in $(SERVICES); do \
		echo ">>> trivy $$svc"; \
		trivy image --severity HIGH,CRITICAL --exit-code 1 \
			--ignore-unfixed ghcr.io/$(GHCR_USER)/$$svc:$(SHA); \
	done

.PHONY: images-load-kind
images-load-kind: images  ## charge les images locales dans le cluster kind (évite GHCR pour la démo TP)
	@for svc in $(SERVICES); do \
		kind load docker-image ghcr.io/$(GHCR_USER)/$$svc:$(SHA) --name $(CLUSTER); \
	done

# ---- Lint local ----
.PHONY: lint
lint:  ## helm lint + yamllint + hadolint sur tout le repo
	@for c in annuaire-service planning-service notif-service; do \
		echo ">>> helm lint $$c/chart"; helm lint $$c/chart || exit 1; \
	done
	@yamllint -c .yamllint.yml . || true
	@for d in annuaire-service planning-service notif-service; do \
		echo ">>> hadolint $$d/Dockerfile"; \
		docker run --rm -i hadolint/hadolint:v2.12.1-beta hadolint --ignore DL3018 - < $$d/Dockerfile || exit 1; \
	done

.PHONY: kubeconform
kubeconform:  ## rendu Helm + validation manifestes
	@for c in annuaire-service planning-service notif-service; do \
		echo ">>> kubeconform $$c"; \
		helm template $$c/chart -f $$c/chart/values-dev.yaml \
			| kubeconform -strict -ignore-missing-schemas \
				-kubernetes-version $(KUBECONFORM_K8S_VERSION) || exit 1; \
	done

# ---- Démos pédagogiques ----
.PHONY: demo-preview
demo-preview:  ## pousse une branche feature/demo-prof pour faire apparaître une preview
	git checkout -b feature/demo-prof
	@sed -i.bak 's/replicaCount: 1/replicaCount: 2/' annuaire-service/chart/values-preview.yaml || true
	@rm -f annuaire-service/chart/values-preview.yaml.bak
	git add annuaire-service/chart/values-preview.yaml
	git commit -m "demo: scale annuaire preview à 2"
	git push -u origin feature/demo-prof
	@echo "✅ branche poussée — attendez ≤ 3 min pour voir la preview apparaître dans l'UI"

.PHONY: demo-drift
demo-drift:  ## scale manuellement un deploy hors-Git pour provoquer un drift
	kubectl -n devhub-dev scale deploy annuaire-dev-annuaire --replicas=5
	@echo "✅ drift provoqué — l'UI ArgoCD va passer en OutOfSync, puis selfHeal ramènera à 2"

# ---- Nettoyage ----
.PHONY: clean
clean:  ## détruit le cluster
	-kind delete cluster --name $(CLUSTER)
