SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---- Versions pinées (reproductibilité) ----
CLUSTER ?= devhub
ARGOCD_CHART_VERSION ?= 9.5.15
INGRESS_CHART_VERSION ?= 4.11.3
KUBECONFORM_K8S_VERSION ?= 1.30.0

GHCR_USER ?= rems08
GH_REPO ?= Rems08/devhub-campus
SERVICES := annuaire planning notif
SHA := $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

# Image du hook PreSync de migration (busybox : `notif` est distroless, pas de shell).
# Préchargée dans kind pour que la démo ne dépende pas du réseau.
MIGRATION_IMAGE ?= busybox:1.36

# Démo étape 7 — PR de preview
DEMO_BRANCH ?= feature/demo-prof
DEMO_PR ?= 1

# ---- Outillage ----
REQUIRED_TOOLS := docker kubectl helm kind argocd git jq openssl

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
	@# On ne met à jour QUE nos deux dépôts : `helm repo update` sans argument
	@# rafraîchit tous les dépôts du poste et échoue en bloc si l'un d'eux est
	@# mort (typiquement un vieux bitnami), ce qui ferait échouer l'install.
	helm repo update argo ingress-nginx
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
	@# Doit passer APRÈS le helm upgrade : le chart gère argocd-tls-certs-cm et
	@# écraserait la CA épinglée.
	$(MAKE) trust-ca

.PHONY: trust-ca
trust-ca:  ## fait confiance à la CA qui signe github.com (indispensable derrière un proxy TLS type Netskope/Zscaler)
	@# Un proxy d'inspection TLS d'entreprise ré-signe les certificats. Le
	@# repo-server ne reconnaît alors plus github.com et la root Application
	@# reste en `Unknown` : « x509: certificate signed by unknown authority ».
	@# On épingle donc la chaîne réellement présentée pour github.com (tout sauf
	@# le leaf) dans argocd-tls-certs-cm. Sans proxy, cette chaîne est celle de
	@# GitHub : la cible est correcte dans les deux cas.
	@# Rien n'est commité : la CA est lue à chaud sur le poste.
	@CHAIN=$$(mktemp -t corpca.XXXXXX); \
	echo | openssl s_client -connect github.com:443 -servername github.com -showcerts 2>/dev/null \
		| awk '/-----BEGIN CERTIFICATE-----/{n++} n>1' \
		| awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > $$CHAIN; \
	if ! grep -q "BEGIN CERTIFICATE" $$CHAIN; then \
		echo "❌ impossible de récupérer la chaîne TLS de github.com (réseau ?)"; rm -f $$CHAIN; exit 1; \
	fi; \
	echo "  CA épinglée : $$(openssl x509 -in $$CHAIN -noout -issuer | sed 's/.*CN *= *\([^,]*\).*/\1/')"; \
	kubectl -n argocd patch configmap argocd-tls-certs-cm --type merge \
		--patch "$$(jq -n --rawfile ca $$CHAIN '{data:{"github.com":$$ca}}')" >/dev/null; \
	rm -f $$CHAIN
	@kubectl -n argocd rollout restart deploy/argocd-repo-server >/dev/null
	@kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=120s >/dev/null
	@echo "✅ CA de github.com approuvée par le repo-server"

.PHONY: argocd-password
argocd-password:  ## affiche le mot de passe admin initial (À ROTATER)
	@kubectl -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath='{.data.password}' | base64 -d; echo

.PHONY: preview-token
preview-token:  ## crée le Secret github-token requis par l'ApplicationSet (étape 7)
	@TOKEN="$${GITHUB_TOKEN:-$$(gh auth token 2>/dev/null)}"; \
	if [ -z "$$TOKEN" ]; then \
		echo "❌ token GitHub introuvable — faites 'gh auth login' ou exportez GITHUB_TOKEN"; \
		exit 1; \
	fi; \
	kubectl -n argocd create secret generic github-token \
		--from-literal=token="$$TOKEN" \
		--dry-run=client -o yaml | kubectl apply -f -
	@echo "✅ secret github-token en place — le pullRequest generator peut interroger l'API"

.PHONY: bootstrap
bootstrap: preview-token  ## SEUL kubectl apply du TP : crée la root Application
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
		kind load docker-image ghcr.io/$(GHCR_USER)/$$svc:dev --name $(CLUSTER); \
	done
	@# Les Applications dev ET preview demandent le tag `dev` : sans ce chargement,
	@# les pods partent en ImagePullBackOff (l'image n'est pas publiée sur GHCR).
	@docker pull -q $(MIGRATION_IMAGE) >/dev/null 2>&1 || true
	@# `kind load docker-image` échoue sur les images multi-arch de Docker Hub :
	@# il importe avec --all-platforms alors que seule la plateforme locale a été
	@# tirée, d'où un « content digest not found ». On passe donc par une archive
	@# mono-plateforme.
	@ARCH=$$(docker version --format '{{.Server.Arch}}'); \
	TAR=$$(mktemp -t migration-image.XXXXXX); \
	docker save --platform linux/$$ARCH $(MIGRATION_IMAGE) -o $$TAR && \
	kind load image-archive $$TAR --name $(CLUSTER) && rm -f $$TAR
	@echo "✅ images $(SHA) + dev + $(MIGRATION_IMAGE) chargées dans kind-$(CLUSTER)"

# ---- Lint local ----
.PHONY: preview-image
preview-image:  ## build les images de la branche de démo et les charge dans kind (tag preview-<slug>)
	@# Les ApplicationSets de preview demandent le tag `preview-<branch_slug>` :
	@# sans ces images, les previews partent en ImagePullBackOff.
	@# En production, la CI construirait et pousserait l'image à l'ouverture de
	@# la PR ; ici on émule ce maillon localement.
	@# On build depuis un worktree de la branche pour ne pas toucher à l'arbre
	@# de travail courant — c'est bien le CODE DE LA BRANCHE qui est packagé.
	@SLUG=$$(echo "$(DEMO_BRANCH)" | tr '/' '-' | tr '[:upper:]' '[:lower:]'); \
	WT=$$(mktemp -d -t preview-src.XXXXXX); rm -rf $$WT; \
	git worktree add -f --detach $$WT $(DEMO_BRANCH) >/dev/null 2>&1 || \
		{ echo "❌ branche $(DEMO_BRANCH) introuvable"; exit 1; }; \
	for svc in $(SERVICES); do \
		echo ">>> build $$svc depuis $(DEMO_BRANCH) → tag preview-$$SLUG"; \
		docker build -q -t ghcr.io/$(GHCR_USER)/$$svc:preview-$$SLUG $$WT/$$svc-service >/dev/null; \
		kind load docker-image ghcr.io/$(GHCR_USER)/$$svc:preview-$$SLUG --name $(CLUSTER); \
	done; \
	git worktree remove --force $$WT >/dev/null 2>&1 || true; \
	echo "✅ images preview-$$SLUG chargées — les previews peuvent démarrer"

.PHONY: lint
lint:  ## helm lint + yamllint + hadolint sur tout le repo
	@# On lint AVEC chaque fichier de values : linter les values par défaut
	@# laisse passer les bugs des templates gardés par un `if` (ingress, pdb).
	@for c in annuaire-service planning-service notif-service; do \
		for v in values-dev values-preview; do \
			echo ">>> helm lint $$c/chart ($$v)"; \
			helm lint $$c/chart -f $$c/chart/$$v.yaml || exit 1; \
		done; \
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
# Toutes les cibles ci-dessous sont REJOUABLES : vous pouvez les enchaîner
# plusieurs fois sans remettre la plateforme à zéro.

.PHONY: demo-status
demo-status:  ## vue d'ensemble : Applications, previews, pods (à garder ouvert pendant la démo)
	@echo "──────── Applications ────────"
	@kubectl -n argocd get applications -o custom-columns=\
NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REV:.status.sync.revision 2>/dev/null
	@echo "──────── ApplicationSets ────────"
	@kubectl -n argocd get applicationsets 2>/dev/null
	@echo "──────── Namespaces devhub ────────"
	@kubectl get ns -l kubernetes.io/metadata.name --no-headers 2>/dev/null | awk '/devhub/ {print $$1}'
	@echo "──────── Pods dev ────────"
	@kubectl -n devhub-dev get pods 2>/dev/null

# ---- Étape 7 : previews éphémères ----
# L'ApplicationSet utilise le pullRequest generator filtré sur le label `preview`.
# La démo la plus lisible consiste donc à fermer / rouvrir la PR devant le formateur.

.PHONY: demo-preview-open
demo-preview-open: preview-image  ## étape 7 : (r)ouvre la PR de démo + label `preview` → la preview apparaît (~60 s)
	-gh pr reopen $(DEMO_PR) --repo $(GH_REPO)
	gh pr edit $(DEMO_PR) --repo $(GH_REPO) --add-label preview
	@echo "✅ PR #$(DEMO_PR) ouverte et labellisée — l'Application annuaire-preview-* apparaît sous ~60 s"
	@echo "   surveillez : watch kubectl -n argocd get applications"

.PHONY: demo-preview-close
demo-preview-close:  ## étape 7 : ferme la PR de démo → la preview est prunée (~60 s)
	gh pr close $(DEMO_PR) --repo $(GH_REPO)
	@echo "✅ PR #$(DEMO_PR) fermée — l'Application preview et son namespace disparaissent sous ~60 s"

.PHONY: demo-preview-branch
demo-preview-branch:  ## étape 7 (variante) : pousse un commit sur la branche de démo
	git checkout $(DEMO_BRANCH) 2>/dev/null || git checkout -b $(DEMO_BRANCH)
	git commit --allow-empty -m "demo: nouveau commit sur la branche de preview"
	git push -u origin $(DEMO_BRANCH)
	@echo "✅ commit poussé — la preview se re-synchronise sous ~60 s"

# ---- Étape 8 : drift, rollback, hooks, waves ----

.PHONY: demo-drift
demo-drift:  ## étape 8 : scale hors-Git → OutOfSync puis selfHeal ramène à 2
	kubectl -n devhub-dev scale deploy annuaire-dev-annuaire --replicas=5
	@echo "✅ drift provoqué — l'UI passe OutOfSync, puis selfHeal ramène à 2"
	@echo "   surveillez : kubectl -n devhub-dev get deploy annuaire-dev-annuaire -w"

.PHONY: demo-break
demo-break:  ## étape 8 : pousse un image.tag inexistant → Synced + Degraded (ImagePullBackOff)
	@# sed et non yq : le yq installé ici est le wrapper Python (kislyuk), dont
	@# la sortie -y reformate le YAML et supprime tous les commentaires du fichier.
	sed -i '' '/name: image.tag/{n;s/value: ".*"/value: "v0-nexiste-pas"/;}' \
		platform/apps/dev/annuaire.yaml
	@grep -A1 "name: image.tag" platform/apps/dev/annuaire.yaml
	git add platform/apps/dev/annuaire.yaml
	git commit -m "demo(etape 8): bump annuaire vers un tag inexistant"
	git push
	@echo "⏱  CHRONO — ArgoCD sync sous ≤ 180 s : Synced + Degraded (ImagePullBackOff)"
	@echo "   pour accélérer : argocd app sync annuaire-dev"

.PHONY: demo-rollback
demo-rollback:  ## étape 8 : git revert du commit fautif → retour Healthy (mesure du time-to-converge)
	git revert --no-edit HEAD
	git push
	@echo "⏱  CHRONO — un rollback = un commit. ArgoCD re-sync → annuaire-dev revient Healthy"
	@echo "   pour accélérer : argocd app sync annuaire-dev"

.PHONY: demo-hook-fail
demo-hook-fail:  ## étape 8/9 : casse le hook PreSync → la sync est BLOQUÉE + notif on-sync-failed
	sed -i '' 's/^  fail: false$$/  fail: true/' annuaire-service/chart/values-dev.yaml
	@grep -A1 "^migration:" annuaire-service/chart/values-dev.yaml
	git add annuaire-service/chart/values-dev.yaml
	git commit -m "demo(etape 8): hook PreSync en echec volontaire"
	git push
	@echo "⏱  le Job de migration échoue → la phase Sync ne démarre JAMAIS"
	@echo "   logs : kubectl -n devhub-dev logs job/annuaire-dev-annuaire-migration"
	@echo "   c'est aussi ce qui déclenche la notification webhook (étape 9)"

.PHONY: demo-hook-fix
demo-hook-fix:  ## étape 8 : répare le hook PreSync (uniquement via Git)
	sed -i '' 's/^  fail: true$$/  fail: false/' annuaire-service/chart/values-dev.yaml
	@grep -A1 "^migration:" annuaire-service/chart/values-dev.yaml
	git add annuaire-service/chart/values-dev.yaml
	git commit -m "demo(etape 8): repare le hook PreSync"
	git push
	@echo "✅ correction poussée — la sync repart et le Deployment se déploie"

.PHONY: demo-waves
demo-waves:  ## étape 8 : montre l'ordre des waves (ConfigMap -1 avant Deployment 0)
	@echo "──────── ordre d'application rendu par Helm ────────"
	@helm template annuaire-dev annuaire-service/chart -f annuaire-service/chart/values-dev.yaml \
		| grep -B4 "sync-wave\|argocd.argoproj.io/hook" | grep -A4 "kind:\|annotations:" || true
	@echo ""
	@echo "──────── ce qu'ArgoCD a réellement exécuté ────────"
	@kubectl -n devhub-dev get configmap,job,deploy \
		-l app.kubernetes.io/instance=annuaire-dev 2>/dev/null
	@echo ""
	@echo "Hook PreSync (migration) → puis wave -1 (ConfigMap) → puis wave 0 (Deployment)"

.PHONY: demo-hook-logs
demo-hook-logs:  ## étape 8 : logs du hook PreSync (doit afficher « migration ok »)
	kubectl -n devhub-dev logs job/annuaire-dev-annuaire-migration 2>/dev/null \
		|| echo "job déjà nettoyé (ttlSecondsAfterFinished=300) — relancez une sync"

# ---- Étape 6 (bonus) : sync window ----

.PHONY: demo-syncwindow
demo-syncwindow:  ## étape 6 bonus : montre la fenêtre de sync (deny 18h→8h en semaine)
	@echo "──────── fenêtres déclarées sur l'AppProject devhub ────────"
	@kubectl -n argocd get appproject devhub -o yaml | sed -n '/syncWindows:/,/^  [a-z]/p' | head -12
	@echo ""
	@echo "──────── état courant vu par ArgoCD ────────"
	@argocd proj windows list devhub 2>/dev/null || echo "(connectez-vous : argocd login argocd.devhub.local --insecure)"
	@echo ""
	@echo "Heure locale : $$(date '+%A %H:%M %Z')"
	@echo "deny 18h→8h lun-ven, manualSync autorisé : un 'argocd app sync' explicite passe,"
	@echo "mais l'auto-sync est suspendu. C'est le défi bonus de l'étape 6."

# ---- Nettoyage ----
.PHONY: clean
clean:  ## détruit le cluster
	-kind delete cluster --name $(CLUSTER)
