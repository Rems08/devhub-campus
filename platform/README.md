# platform — repo Ops

Tout l'état désiré du cluster `DevHub Campus` est ici. ArgoCD le lit en
continu et y fait converger le cluster.

## Arbo

```
platform/
├── argocd/
│   └── values.yaml          ← values Helm pour installer ArgoCD lui-même
├── projects/
│   └── devhub.yaml          ← AppProject : sécurité (sourceRepos, dest, roles, syncWindows)
├── bootstrap/
│   ├── root-app.yaml        ← Application racine (App of Apps) — SEUL kubectl apply
│   └── namespaces.yaml      ← namespace devhub-dev (géré par la root)
├── apps/
│   ├── dev/                 ← Applications stables (branche main)
│   │   ├── annuaire.yaml
│   │   ├── planning.yaml
│   │   └── notif.yaml
│   └── preview/             ← ApplicationSets (pullRequest generator)
│       ├── annuaire.yaml
│       ├── planning.yaml
│       └── notif.yaml
├── notifications/
│   └── triggers.yaml        ← argocd-notifications : on-sync-failed → webhook.site
└── rbac/
    └── policy.csv           ← rôles developer / platform-admin
```

## Cycle de vie

1. Installation initiale d'ArgoCD via Helm + `argocd/values.yaml`.
2. Un **seul** `kubectl apply -f bootstrap/root-app.yaml` — c'est lui qui
   instancie tout le reste.
3. Toute modification passe par PR : un commit dans `apps/`, ArgoCD synchronise.

## Garde-fous

- `AppProject devhub` whitelist explicitement les `sourceRepos` autorisés ;
- les Applications `dev/*` sont en `selfHeal: true, prune: false` (drift
  auto-corrigé, mais suppression conserve la ressource pour audit) ;
- les ApplicationSets `preview/*` sont en `prune: true` (sinon les previews
  ne se nettoient jamais).
