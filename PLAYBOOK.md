# PLAYBOOK de soutenance — DevHub Campus (TP 2 ArgoCD)

> But : pour **chaque critère de la grille d'évaluation**, savoir quelle URL ouvrir
> et quelle commande lancer pour *montrer* que c'est en place. Tout est aligné sur
> les noms de ressources réels du cluster `kind-devhub`.
>
> Ordre de démo conseillé dans le `README.md` (§ *Ordre de démo conseillé*).

---

## ⚠️ Si les URLs `*.devhub.local` ne répondent pas (HTTP 000)

Le cluster tourne dans **Colima** (kind-in-Docker), et l'accès `127.0.0.1:80/443`
passe par un **tunnel SSH de port-forward Colima**. Ce tunnel casse à **chaque
changement de réseau** (Wi-Fi, VPN, Netskope on/off). Symptôme : `curl` renvoie
`HTTP 000` alors que les pods sont `Running`.

```sh
# le cluster va bien en interne ? (doit répondre 200)
colima ssh -- curl -s -o /dev/null -w "%{http_code}\n" -H "Host: annuaire.devhub.local" http://localhost/healthz

# réparer le port-forward (sur un réseau STABLE), puis ATTENDRE ~30 s :
colima restart
sleep 30
curl -s http://annuaire.devhub.local/healthz     # doit renvoyer le JSON
```

> À faire **avant** la soutenance, une fois connecté au réseau définitif —
> et ne plus changer de réseau ensuite. `kubectl`/`argocd` (port API) ne sont
> pas affectés, seul l'accès HTTP aux services l'est.

---

## 0. Préparation (à lancer une fois, avant de présenter)

```sh
# contexte kubectl (le cluster kind bascule le contexte tout seul au cluster-up)
kubectl config current-context          # → kind-devhub

# mots de passe (cluster kind local de cours — jetable)
export ARGOCD_ADMIN_PW='DevHub-Admin-2026!'   # admin
export ARGOCD_DEV_PW='DevHub-Dev-2026!'       # compte dev (démo RBAC)

# login CLI ArgoCD
argocd login argocd.devhub.local --insecure --username admin \
  --password "$ARGOCD_ADMIN_PW" --grpc-web

# vue d'ensemble instantanée
make demo-status
```

**URLs à garder ouvertes dans le navigateur :**

| Quoi | URL | Identifiants |
|---|---|---|
| UI ArgoCD | <https://argocd.devhub.local> | admin / `$ARGOCD_ADMIN_PW` |
| annuaire (dev) | <http://annuaire.devhub.local/healthz> · <http://annuaire.devhub.local/students> | — |
| planning (dev) | <http://planning.devhub.local/healthz> | — |
| notif (dev) | <http://notif.devhub.local/healthz> | — |
| preview annuaire | <http://annuaire-feature-demo-prof.devhub.local/healthz> | — |
| webhook.site (notif) | <https://webhook.site/#!/50887b53-b660-4795-8889-0a5932f5f637> | — |

---

## Critère 1 — Qualité de l'image Docker (8 %)

**Ce qu'on veut voir :** multi-stage, non-root, tag = SHA, `/healthz`, labels OCI, scan trivy.

```sh
# non-root : l'utilisateur effectif DANS le pod qui tourne (toujours dispo)
kubectl -n devhub-dev exec deploy/annuaire-dev-annuaire -- id
# → uid=1001(app) ... (jamais uid=0)

# multi-stage + USER + labels OCI : lecture directe du Dockerfile (toujours vrai)
grep -nE 'FROM .* AS|^USER|opencontainers' annuaire-service/Dockerfile

# /healthz répond 200
curl -s http://annuaire.devhub.local/healthz          # {"ok":true,"service":"annuaire"}
```

Taille des images + tag SHA + scan trivy — nécessitent d'avoir les images en
local (`make images` d'abord, car le cluster tourne sur containerd de kind,
indépendant du docker du poste) :

```sh
make images                                           # build local des 3 images
docker images | grep -E 'annuaire|planning|notif'     # tailles + tags (:sha et :dev)
make images-scan                                      # trivy HIGH/CRITICAL bloquant
```

Dans le repo : `*-service/Dockerfile` (multi-stage, `USER`), `.github/workflows/ci.yml`
(job *Build + Trivy scan + Push GHCR*). `notif` est en distroless (≈18 Mo).

---

## Critère 2 — Qualité du chart Helm (12 %)

**Ce qu'on veut voir :** helpers, labels obligatoires, multi-env, schéma JSON, PDB, test Helm.

```sh
# lint des 3 charts sur chaque environnement
make lint

# labels obligatoires rendus sur une ressource
helm template annuaire-dev annuaire-service/chart -f annuaire-service/chart/values-dev.yaml \
  | grep -A6 'app.kubernetes.io/'

# le schéma JSON rejette une valeur invalide (doit ÉCHOUER volontairement)
helm template annuaire-service/chart --set replicaCount=-1
# → Error: ... replicaCount: Must be greater than or equal to 0

# rendu multi-env : dev vs preview
diff <(helm template x annuaire-service/chart -f annuaire-service/chart/values-dev.yaml) \
     <(helm template x annuaire-service/chart -f annuaire-service/chart/values-preview.yaml) | head

# validation kubeconform de tous les manif(dev + preview)
make kubeconform
```

> ⚠️ **Écart connu** : `values-staging.yaml` n'existe pas encore (l'étape 4 demande
> dev + staging + preview). À corriger avant la note.

Dans le repo : `*-service/chart/` (`_helpers.tpl`, `values.schema.json`,
`templates/pdb.yaml`, `templates/tests/connection-test.yaml`).

---

## Critère 3 — Installation propre d'ArgoCD (8 %)

**Ce qu'on veut voir :** chart Helm, namespace dédié, ingress, mot de passe rotaté.

```sh
# ArgoCD installé via Helm dans le namespace argocd
helm -n argocd list
kubectl -n argocd get pods

# ingress sur argocd.devhub.local
kubectl -n argocd get ingress argocd-server

# le mot de passe a été rotaté : le secret initial ne sert plus à se connecter
argocd account get-user-info            # → logged in as: admin
```

**URL :** <https://argocd.devhub.local> — se connecter en `admin`.
Rotation documentée dans `RAPPORT.md` § Étape 5. Derrière un proxy TLS
(Netskope), `make trust-ca` épingle la CA de github.com.

---

## Critère 4 — App of Apps + AppProject sécurisé (14 %)

**Ce qu'on veut voir :** une root qui génère les enfants, un AppProject qui verrouille.

```sh
# l'arbre App of Apps : root + 6 enfants, tous Synced + Healthy
kubectl -n argocd get applications

# la root pointe vers platform/apps (et PAS vers bootstrap → pas de récursion)
kubectl -n argocd get application root \
  -o jsonpath='{.spec.source.path}{"\n"}'          # platform/apps

# AppProject : whitelist repos / destinations / clusterResources
kubectl -n argocd get appproject devhub -o yaml | \
  yq '.spec | {sourceRepos, destinations, clusterResourceWhitelist}'
# (si yq = wrapper python : remplace par la ligne ci-dessous)
kubectl -n argocd get appproject devhub -o jsonpath='{.spec.sourceRepos} {.spec.destinations}'; echo

# preuve du verrouillage : les rôles et la fenêtre de sync
kubectl -n argocd get appproject devhub -o jsonpath='{.spec.roles[*].name}'; echo
```

**Dans l'UI :** page *Applications* → la carte `root` a des flèches vers les
3 `*-dev` et les 3 ApplicationSets. Cliquer `annuaire-dev` → arbre
`Deployment → ReplicaSet → Pods`, `Service`, `Ingress`, `ConfigMap`.

Argument oral (« pourquoi ≠ `kubectl apply -f apps/dev/` ») : cf. `RAPPORT.md` § Étape 6.

---

## Critère 5 — ApplicationSet + previews, démo live (18 %) ⭐

**Ce qu'on veut voir :** une preview qui apparaît/disparaît toute seule, avec le code de la branche.

```sh
# les 3 ApplicationSets (generator pullRequest) génèrent bien
kubectl -n argocd get applicationset annuaire-preview \
  -o jsonpath='{.status.conditions[?(@.type=="ErrorOccurred")].message}'; echo
# → All applications have been generated successfully

# la preview existe dans son propre namespace, labellisée preview
kubectl get ns devhub-preview-feature-demo-prof --show-labels
kubectl -n devhub-preview-feature-demo-prof get all

# PREUVE que la preview sert le CODE DE LA BRANCHE (pas de main)
curl -s http://annuaire-feature-demo-prof.devhub.local/healthz
# → {"ok":true,"service":"annuaire","preview":"demo-prof"}   ← champ preview absent en dev
```

**Démo live devant le formateur :**

```sh
make demo-preview-close      # ferme la PR #1 → preview + namespace disparaissent (~60 s)
make demo-preview-open       # ré-ouvre + build l'image de branche → preview réapparaît
watch kubectl -n argocd get applications      # à laisser tourner pendant l'attente
```

Dans le repo : `platform/apps/preview/*.yaml` (generator, prune, CreateNamespace,
`branch_slug`, label `devhub.io/env: preview`).

---

## Critère 6 — Bestiaire ArgoCD : drift / rollback / hooks / waves (12 %)

**Ce qu'on veut voir :** les 6 comportements du tableau de l'étape 8, observés en direct.

```sh
# --- (a) DRIFT + selfHeal ---
make demo-drift              # scale hors-Git à 5
kubectl -n devhub-dev get deploy annuaire-dev-annuaire -w   # OutOfSync → selfHeal → 2
#   dans l'UI : l'app passe OutOfSync (jaune) puis revient Synced

# --- (b) SYNC WAVES : ConfigMap (-1) avant Deployment (0) ---
make demo-waves
kubectl -n devhub-dev get cm,job,deploy -l app.kubernetes.io/instance=annuaire-dev
#   comparer les AGE : Job (hook) puis ConfigMap puis Deployment

# --- (c) HOOK PreSync : le job de migration ---
make demo-hook-logs          # doit afficher "migration ok"

# --- (d) IMAGE CASSÉE : Synced + Degraded ---
make demo-break              # commit un tag d'image inexistant
kubectl -n devhub-dev get pods -w            # ImagePullBackOff
#   dans l'UI : Synced mais Degraded (rouge)

# --- (e) ROLLBACK = un commit ---
make demo-rollback           # git revert → re-converge Healthy (chronométrer)

# --- (f) HOOK EN ÉCHEC bloque la sync (+ déclenche la notif, cf. critère 7) ---
make demo-hook-fail
kubectl -n devhub-dev logs job/annuaire-dev-annuaire-migration   # échec volontaire
make demo-hook-fix           # réparation UNIQUEMENT via Git
```

Heuristique de diagnostic (`OutOfSync + Degraded`) à réciter : cf. `RAPPORT.md` § Étape 8.

---

## Critère 7 — Sécurité & observabilité (12 %)

**Ce qu'on veut voir :** RBAC qui refuse, notification sur échec, métriques Prometheus.

### RBAC — le compte `dev` ne peut syncer que son service

```sh
# se connecter en tant que dev
argocd login argocd.devhub.local --insecure --username dev \
  --password "$ARGOCD_DEV_PW" --grpc-web

argocd app sync annuaire-dev --grpc-web      # ✅ AUTORISÉ (son service)
argocd app sync planning-dev --grpc-web      # ❌ permission denied

# revenir en admin
argocd login argocd.devhub.local --insecure --username admin \
  --password "$ARGOCD_ADMIN_PW" --grpc-web
```

### Notifications — un échec de sync poste sur webhook.site

```sh
make demo-hook-fail          # provoque l'échec
# puis ouvrir : https://webhook.site/#!/50887b53-b660-4795-8889-0a5932f5f637
#   → un POST JSON {app, revision, message} apparaît
make demo-hook-fix           # réparer ensuite
```

### Observabilité — métriques Prometheus

```sh
# exposer et interroger les métriques du controller
kubectl -n argocd port-forward svc/argocd-application-controller-metrics 8082:8082 &
curl -s localhost:8082/metrics | grep -E '^argocd_app_info|argocd_app_sync_total|argocd_app_reconcile' | head
kill %1
```

Les 3 métriques retenues et leur interprétation : `RAPPORT.md` § Étape 9.

---

## Critères 8 & 9 — Synthèse + lisibilité du rapport (12 % + 4 %)

Pas de commande : lecture du `RAPPORT.md`.

- **Étape 11 « Ce qu'ArgoCD ne sait pas faire »** : `RAPPORT.md` § Étape 11 (7 thèmes).
- **Étape 10 (bonus) comparaison GitOps** : `RAPPORT.md` § Étape 10.

```sh
# ouvrir le rapport et le sommaire
grep -n '^## ' RAPPORT.md
```

> ⚠️ **À finaliser** : remplir le tableau des versions (§ Étape 0) et insérer les
> captures marquées « à coller ».

---

## Défi bonus — la fenêtre de synchronisation (étape 6)

```sh
make demo-syncwindow         # montre le deny 18h→8h + l'heure courante
```

---

## Reset rapide entre deux répétitions

```sh
# si une démo a laissé un état sale, tout re-converge depuis Git :
kubectl -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite
make demo-status
```

> Reconstruction totale (dernier recours, ~10 min) :
> `make clean && make cluster-up && make images-load-kind && make argocd-install && make bootstrap`
