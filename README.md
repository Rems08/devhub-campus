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

```sh
# 1. outillage local
make tools-check

# 2. cluster Kubernetes local (kind, 2 nœuds)
make cluster-up

# 3. images des 3 services → GHCR
make images

# 4. ingress-nginx + ArgoCD via Helm
make argocd-install

# 5. hosts file (à ajouter manuellement)
make hosts-print

# 6. mot de passe admin initial
make argocd-password

# 7. UNIQUE kubectl apply du TP : la root Application
make bootstrap
```

Ouvrez ensuite https://argocd.devhub.local. Quatre Applications doivent
apparaître : `root`, `annuaire-dev`, `planning-dev`, `notif-dev`, toutes en
*Synced + Healthy*.

## Démos (étapes 7, 8, 9)

```sh
make demo-preview    # pousse une branche feature pour faire apparaître une preview
make demo-drift      # provoque un drift puis observe le selfHeal
make demo-rollback   # bump d'image puis git revert, mesure du time-to-converge
```

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
