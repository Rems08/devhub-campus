# DevHub Campus — implémentation TP 2 ArgoCD

> Mono-repo « app + ops » qui matérialise sur disque la séparation
> applicative / plateforme du polycopié (`tp-argocd/POLYCOPIE-ARGOCD.md`).

## Arborescence

```
devhub-campus/
├── annuaire-service/   # repo APP — Node.js + chart Helm + CI
├── planning-service/   # repo APP — Python FastAPI + chart Helm + CI
├── notif-service/      # repo APP — Go + chart Helm + CI
└── platform/           # repo OPS — Application, AppProject, ApplicationSet
```

Pour un vrai setup multi-repo, chaque sous-dossier deviendrait un dépôt Git
indépendant. Ici, un seul `.git` racine — ArgoCD pointe vers la même URL avec
des `path:` différents (ex : `path: annuaire-service/chart`,
`path: platform/apps/dev`).

## Démarrage rapide (≈ 10 min)

> **Prérequis** : Docker démarré, et `gh auth login` fait (le token GitHub est
> nécessaire au `pullRequest` generator de l'étape 7).

```sh
# 1. outillage local (docker, kubectl, helm, kind, argocd, git, yq)
make tools-check

# 2. cluster Kubernetes local (kind, 2 nœuds)
make cluster-up

# 3. build des 3 images + chargement DANS kind (tags :sha ET :dev, + busybox)
#    Les images ne sont PAS publiées sur GHCR : le cluster les consomme
#    localement. `make images` seul ne suffit pas — il ne fait que builder.
make images-load-kind

# 4. ingress-nginx + ArgoCD via Helm
make argocd-install

# 5. hosts file (à ajouter manuellement, avec sudo)
make hosts-print

# 6. mot de passe admin initial (à rotater — cf. RAPPORT.md étape 5)
make argocd-password

# 7. UNIQUE kubectl apply du TP : la root Application
#    (crée aussi le Secret github-token via la dépendance `preview-token`)
make bootstrap
```

Ouvrez ensuite https://argocd.devhub.local. Quatre Applications doivent
apparaître : `root`, `annuaire-dev`, `planning-dev`, `notif-dev`, toutes en
*Synced + Healthy*, plus trois `ApplicationSet` de preview.

Vue d'ensemble à tout moment :

```sh
make demo-status
```

## Ordre de démo conseillé

| # | Commande | Ce que le formateur doit voir |
|---|---|---|
| 1 | `make demo-status` | 4 Applications *Synced + Healthy* |
| 2 | `make demo-waves` | hook PreSync → ConfigMap (wave -1) → Deployment (wave 0) |
| 3 | `make demo-hook-logs` | le Job de migration logge `migration ok` |
| 4 | `make demo-preview-close` | la preview et son namespace disparaissent (~60 s) |
| 5 | `make demo-preview-open` | la preview réapparaît (~60 s) — **étape 7, 18 % de la note** |
| 6 | `make demo-drift` | *OutOfSync* puis `selfHeal` ramène à 2 replicas |
| 7 | `make demo-break` | *Synced + Degraded* (`ImagePullBackOff`) |
| 8 | `make demo-rollback` | `git revert` → retour *Healthy* (chronométrez) |
| 9 | `make demo-hook-fail` | hook PreSync en échec → sync **bloquée** + notification |
| 10 | `make demo-hook-fix` | réparation **uniquement via Git** |
| 11 | `make demo-syncwindow` | fenêtre `deny` 18h→8h (défi bonus étape 6) |

Toutes ces cibles sont **rejouables** : on peut les enchaîner sans remettre la
plateforme à zéro.

> **Attention — sync window.** L'`AppProject` interdit les syncs automatiques
> entre 18h et 8h du lundi au vendredi (défi bonus de l'étape 6). Si vous
> démontrez en soirée, l'auto-sync ne partira pas : forcez avec
> `argocd app sync <app>` (`manualSync: true` l'autorise) et expliquez la
> fenêtre — c'est un point bonus, pas une panne.

## État de préparation (fait)

- [x] **webhook.site** — UUID câblé dans `platform/argocd/values.yaml`,
      notification `on-sync-failed` **testée de bout en bout** : `make
      demo-hook-fail` fait bien arriver un POST JSON (`app`, `revision`,
      `message`) sur webhook.site. Piège rencontré : le destinataire d'une
      souscription est le **nom** du service (`webhook-site`), pas
      `webhook:webhook-site`.
- [x] **Rotation du mot de passe admin** — faite (méthode documentée dans
      `RAPPORT.md` étape 5 ; le mot de passe lui-même n'est pas dans Git).
- [x] **Compte `dev`** — mot de passe défini, RBAC vérifié en direct : `dev`
      peut sync `annuaire-dev` mais reçoit `PermissionDenied` sur `planning-dev`.

> **Réseau d'entreprise (Netskope).** Sur le poste MOBIVIA, l'inspection TLS
> casse la vérif de certificat GitHub dans kind (`x509: unknown authority`) :
> `make argocd-install` lance `make trust-ca`, qui épingle la chaîne réellement
> présentée pour `github.com`. webhook.site est en plus **bloqué par catégorie**
> quand Netskope est actif — il faut le désactiver (ou un réseau perso) pour
> l'étape 9.

## Pratiques DevOps appliquées

Voir `RAPPORT.md` § *Pratiques DevOps* pour la liste exhaustive. En résumé :

- **séparation app/ops** matérialisée par les 4 sous-dossiers ;
- **image immutable** taguée par SHA court, jamais `latest`, scan trivy
  bloquant en CI ;
- **promotion d'image** par PR sur le repo platform — l'humain merge,
  ArgoCD synchronise ;
- **Helm + schema JSON** rejette les valeurs invalides ;
- **pre-commit hooks** : `yamllint`, `hadolint`, `helm lint`, `kubeconform`,
  `gitleaks` ;
- **AppProject** verrouille les sources Git et destinations autorisées ;
- **RBAC ArgoCD** : un rôle `developer` ne peut syncer que ses propres apps ;
- **notifications** vers webhook.site sur sync failed ;
- **previews éphémères** via `ApplicationSet` + `pullRequest` generator.

## Référence

- Polycopié : `tp-argocd/POLYCOPIE-ARGOCD.md`
- Rapport pédagogique : `RAPPORT.md`
- Squelette de départ du polycopié (intact, à des fins de comparaison) :
  `tp-argocd/devhub-campus/`
