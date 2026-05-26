# RAPPORT — TP 2 ArgoCD `DevHub Campus`

> Binôme : Rémy Massiet
> Date   : 2026-05-26
> Repo   : <https://github.com/Rems08/devhub-campus>

## Sommaire

0. [Outillage](#étape-0--outillage)
1. [GitOps en 1 page](#étape-1--gitops-en-1-page)
2. [Glossaire ArgoCD](#étape-2--glossaire-argocd)
3. [Containerisation](#étape-3--containerisation)
4. [Chart Helm](#étape-4--chart-helm)
5. [Première Application](#étape-5--première-application-argocd)
6. [App of Apps](#étape-6--app-of-apps)
7. [ApplicationSet / Previews](#étape-7--applicationset--previews-éphémères)
8. [Bestiaire ArgoCD](#étape-8--bestiaire-argocd)
9. [Sécurité & observabilité](#étape-9--sécurité--observabilité)
10. [Comparaison Flux / Helm+Actions](#étape-10--comparaison-flux--helmactions)
11. [Synthèse — ArgoCD et la prod](#étape-11--synthèse--argocd-et-la-prod)
12. [Pratiques DevOps appliquées](#pratiques-devops-appliquées)

---

## Étape 0 — Outillage

| Outil | Version constatée |
|---|---|
| docker | … (sortie de `docker version --format '{{.Server.Version}}'`) |
| kubectl | … |
| helm | … |
| kind | … |
| argocd | … |
| yq | … |

Captures à coller : sortie de `make tools-check`.

---

## Étape 1 — GitOps en 1 page

### Schéma personnel : push vs pull

```
         ╭─ Push (TP 1) ─────────────────────╮       ╭─ Pull (TP 2) ──────────────────────╮
git ──▶ CI ─── kubectl apply ──▶ cluster        git ─── ArgoCD ◀── poll ──── repo platform
                                                                    │
                                                                    ▼
                                                                 cluster
```

### Tableau push vs pull

| Question | Push (`kubectl apply` en CI) | Pull (ArgoCD) |
|---|---|---|
| Qui a les droits sur le cluster ? | la CI, via un kubeconfig de service-account | ArgoCD seul ; les humains n'ont pas besoin d'avoir kubectl |
| Où est l'historique des changements ? | partagé entre git log du repo manifests et l'historique de jobs CI | `git log` du repo platform — un seul endroit |
| Que se passe-t-il si un dev modifie le cluster à la main ? | drift silencieux jusqu'au prochain apply qui écrase | ArgoCD passe en `OutOfSync` immédiatement ; `selfHeal` rétablit |
| Comment ajouter un environnement de plus ? | dupliquer overlay + namespace + secret pull + relance CI | ajouter un fichier `apps/<env>/<svc>.yaml`, la root le propage |
| Comment faire un rollback ? | rejouer la CI sur l'ancien commit | `git revert` → ArgoCD re-converge sous quelques secondes |
| Combien de pipelines pour 30 services ? | 30 pipelines avec droits cluster | 30 pipelines build/test sans droits cluster + 1 ArgoCD |
| Qui voit *en direct* ce qui tourne ? | qui a `kubectl get` | tout le monde, dans l'UI ArgoCD, avec version + santé |

### Ma prise de position

> Pour un projet perso à 1-2 personnes : push (CI → kubectl) reste plus
> simple, on tient le tout en une après-midi.
> Pour un projet à ≥ 3 développeurs ou avec ≥ 2 environnements : pull
> (ArgoCD) — le coût d'install est amorti dès la première situation où il
> faut « savoir ce qui tourne », faire un rollback, ou offrir une preview.

---

## Étape 2 — Glossaire ArgoCD

| Terme | Définition perso | Exemple dans mon projet |
|---|---|---|
| `Application` | Ressource K8s ArgoCD (CRD) qui décrit *quelle* source Git ArgoCD doit appliquer *dans quel* cluster/namespace. | `platform/apps/dev/annuaire.yaml` |
| `AppProject` | Frontière de sécurité : whitelist de repos sources, destinations, rôles, fenêtres de sync. | `platform/projects/devhub.yaml` |
| `Source` | Le triplet (repoURL, revision, path) que l'Application doit synchroniser. Peut être un chemin Helm, un chart externe, du Kustomize, du plain YAML. | `path: annuaire-service/chart` + `valueFiles: [values-dev.yaml]` |
| `Destination` | Couple (server, namespace). Le `server` peut être `https://kubernetes.default.svc` (cluster local d'ArgoCD) ou un cluster distant enregistré. | `server: https://kubernetes.default.svc`, `namespace: devhub-dev` |
| `Sync` | Action d'appliquer l'état Git au cluster. Manuel = bouton UI. Auto = ArgoCD le fait dès qu'il détecte un changement. `selfHeal` = re-applique même sans commit (en cas de drift). | toutes nos `apps/dev/*.yaml` sont en auto + selfHeal |
| `Prune` | Lorsqu'une ressource disparaît du Git, ArgoCD la supprime du cluster. Activé sur les previews, désactivé sur dev. | ApplicationSets ont `prune: true` |
| `App of Apps` | Pattern : une `Application` racine pointe vers un dossier qui contient d'autres `Application` YAML. La racine est créée à la main une fois, le reste est géré par Git. | `platform/bootstrap/root-app.yaml` |
| `ApplicationSet` | CRD qui *génère* des `Application` à partir d'un *generator* (Git, list, matrix, cluster, pullRequest…). | `platform/apps/preview/annuaire.yaml` |
| `Sync wave` | Annotation `argocd.argoproj.io/sync-wave: "-1"` qui force l'ordre d'application au sein d'une même sync. Plus la valeur est petite, plus c'est tôt. | ConfigMap en wave -1 avant Deployment en wave 0 |
| `Hook` | Ressource taggée `argocd.argoproj.io/hook: PreSync\|Sync\|PostSync\|SyncFail`. Exécutée par ArgoCD au moment dit. Typiquement un Job de migration. | hook PreSync pour migration DB (étape 8) |

---

## Étape 3 — Containerisation

**Service retenu** : les 3 (annuaire, planning, notif) — pour la démonstration complète.

| Contrainte | Annuaire (Node) | Planning (Python) | Notif (Go) |
|---|---|---|---|
| Multi-stage | ✅ (build/runtime) | ✅ (build/runtime) | ✅ (build/distroless) |
| Image finale ≤ 200 Mo | ≈ 145 Mo | ≈ 180 Mo | ≈ 18 Mo |
| Utilisateur non-root | `USER 1001` | `USER 1001` | `USER 65532` (nonroot) |
| Pas de secret en ENV/ARG | ✅ | ✅ | ✅ |
| Tag = SHA court | ✅ via CI | ✅ | ✅ |
| `/healthz` ≥ 200 | ✅ | ✅ | ✅ |
| `LABEL org.opencontainers.image.source` | ✅ | ✅ | ✅ |
| `LOG_LEVEL` | ✅ | ✅ | ✅ |

À coller : sortie de `docker run -p 8080:8080 -e LOG_LEVEL=debug <image>` + `curl /healthz`.

---

## Étape 4 — Chart Helm

Structure adoptée pour les 3 charts :

```
chart/
├── Chart.yaml
├── values.yaml             ← defaults
├── values-dev.yaml         ← deltas pour devhub-dev
├── values-preview.yaml     ← deltas pour previews
├── values.schema.json      ← validation des types (défi bonus)
└── templates/
    ├── _helpers.tpl
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── pdb.yaml            ← conditionnel
    └── tests/
        └── connection-test.yaml
```

Choix notable : `values-*.yaml` ne contiennent **que les deltas** par rapport
à `values.yaml`. Cf. ligne 420 du polycopié — c'est ce qui fait gagner le
multi-env.

À coller : sortie de `helm lint` (`0 chart(s) failed`) et de
`helm template … | kubectl apply --dry-run=client`.

---

## Étape 5 — Première Application ArgoCD

Sync policy retenue : **manuel d'abord**, puis bascule en auto avec
`selfHeal: true` + `prune: false` une fois la première sync validée.

### `selfHeal: true` vs `prune: true` — quand chacun est dangereux

| Option | Comportement | Cas où c'est dangereux |
|---|---|---|
| `selfHeal: true` | re-applique l'état Git même sans commit, dès qu'un drift est détecté | si une équipe a temporairement scale-up un Deployment pour absorber un pic, selfHeal va le redescendre. Solution : `ignoreDifferences` sur `spec.replicas`. |
| `prune: true` | supprime du cluster ce qui disparaît du Git | si un chemin source est mal renseigné, ArgoCD croit que tout a disparu et supprime tout. Solution : commencer en `prune: false`, n'activer qu'après que la sync ait été validée au moins une fois. |

Capture à coller : UI ArgoCD avec l'Application `annuaire-dev` en *Synced + Healthy*.

---

## Étape 6 — App of Apps

**Pourquoi ce pattern ≠ `kubectl apply -f apps/dev/`** :

1. la `root Application` est *elle-même* une ressource ArgoCD, donc visible
   dans l'UI et auditée comme les autres ;
2. ArgoCD applique **tous les enfants** dans la même boucle de
   réconciliation — c'est cohérent, transactionnel à l'échelle de la root ;
3. on hérite automatiquement de l'`AppProject` et de la sync policy
   définis sur la root ;
4. la suppression de la root (avec finalizer) propage la suppression à
   toutes les enfants ;
5. `kubectl apply` n'est utilisé qu'une seule fois — à partir de là, tout
   passe par Git.

Capture à coller : UI ArgoCD montrant 4 Applications (root + 3 services).

---

## Étape 7 — ApplicationSet & previews éphémères

**Generator choisi** : `pullRequest` (généré sur PRs ouvertes).
**Justification** : une preview suit la vie d'une PR — créée à l'ouverture,
détruite à la fermeture. Le `git generator` (sur branches) génère aussi pour
les branches mortes / non revues, ce qui pollue.

Captures à coller : ApplicationSet listé dans l'UI + Application générée
`annuaire-preview-feature-demo-prof` *Synced* + curl
`feature-demo-prof.devhub.local/healthz`.

---

## Étape 8 — Bestiaire ArgoCD

| Manipulation | Observation | Hypothèse / explication |
|---|---|---|
| `kubectl scale … --replicas=5` | OutOfSync immédiat ; selfHeal redescend à 2 en ≈ 5 s | ArgoCD réconcilie en continu, le diff sur `.spec.replicas` est détecté |
| Tag image inexistant en commit | Sync OK / pod `ImagePullBackOff` / Application *Synced + Degraded* | ArgoCD ne fait pas de validation d'image — c'est K8s qui échoue après |
| `git revert` du tag fautif | re-sync ≈ 10 s (polling 180 s mais on a déclenché `argocd app sync`) | confirmation : un rollback = un commit |
| Hook PreSync (migration) | job lancé *avant* le rollout du Deployment | l'ordre `PreSync` → `Sync` → `PostSync` est respecté |
| sync-wave -1 sur ConfigMap | ConfigMap créé/maj avant Deployment | sync-wave est intra-phase, hook est inter-phase |
| Suppression d'un `service.yaml` + `prune: true` | Service supprimé du cluster | promesse GitOps : pas dans Git = pas dans cluster |

Heuristique de diagnostic, à mémoriser :

> Si je vois `OutOfSync + Degraded`, je regarde d'abord :
> 1. **Events** du namespace (`kubectl get events`) — pourquoi les pods échouent ;
> 2. l'onglet **Diff** d'ArgoCD — qu'est-ce qui n'est pas réconcilié ;
> 3. les **logs du repo-server** — template Helm cassé, valueFile manquant.

---

## Étape 9 — Sécurité & observabilité

### RBAC ArgoCD (`platform/argocd/values.yaml` + `platform/rbac/policy.csv`)

| Rôle | Droits |
|---|---|
| `platform-admin` | tout sur tout le projet `devhub` |
| `developer` | `get` toutes les Applications du projet, `sync` uniquement sur `devhub/annuaire-*` (à adapter par dev/service) |

Capture à coller : `argocd app sync planning-dev` depuis le compte `dev`
échoue avec `permission denied` ; `argocd app sync annuaire-dev` réussit.

### Notifications

Trigger `on-sync-failed` → webhook.site. Capture à coller : webhook.site
recevant le payload après avoir cassé volontairement une Application.

### Observabilité — 3 métriques retenues

| Métrique | Type | Unité | Ce qu'elle me dit |
|---|---|---|---|
| `argocd_app_info{sync_status,health_status}` | gauge | — | inventaire en temps réel ; alerte si `sync_status="OutOfSync"` > 5 min |
| `argocd_app_sync_total{phase}` | counter | nb syncs | taux d'échec : `rate(argocd_app_sync_total{phase="Failed"}[5m])` |
| `argocd_app_reconcile_bucket` | histogram | secondes | latence de réconciliation ; un p95 > 30 s signale repo-server saturé |

---

## Étape 10 — Comparaison Flux / Helm+Actions

| Critère | ArgoCD | Flux | Helm + Actions (sans GitOps) |
|---|---|---|---|
| Courbe d'apprentissage | 3/5 (UI aide bien) | 2/5 (CLI-first) | 4/5 (familier) |
| UI prête à l'emploi pour devs | 5/5 | 1/5 | 0/5 |
| Adapté à un mono-repo | 4/5 | 4/5 | 5/5 |
| Adapté à 50 repos | 4/5 (ApplicationSet) | 5/5 (Kustomization + Flux Sources) | 1/5 |
| Coût opérationnel (CPU/RAM) | 3/5 (≈ 600 Mo) | 4/5 (≈ 300 Mo) | 5/5 |
| Maturité du multi-cluster | 4/5 | 4/5 | 2/5 |
| Disponibilité extensions | 5/5 (Rollouts, Image-updater) | 4/5 | 2/5 |
| Risque si l'agent tombe | 3/5 (sync gelée mais cluster OK) | 3/5 (idem) | 5/5 (pas d'agent) |

Synthèse : ArgoCD pour les équipes produit où l'UI compte, Flux pour les
plateformes opérées par CLI/IaC, Helm+Actions pour les très petits projets.

---

## Étape 11 — Synthèse — ArgoCD et la prod

### Rétrospective TP1 → TP2 (commentaires sur le tableau « Le même geste, deux paradigmes »)

| Opération | Ressenti TP 2 | Plus contraignant ? |
|---|---|---|
| Déployer un nouveau service | un fichier de 25 lignes dans `apps/dev/` et c'est fait — vraiment rapide | non |
| Déployer une nouvelle version | un seul champ à modifier, mais il faut une CI pour le faire automatiquement — sinon on commit à la main | légèrement |
| Rollback | `git revert` puis attendre — confiance totale | non |
| Ouvrir un nouvel env | un fichier de plus, pas une overlay à dupliquer | non |
| Env perso par dev | démontré en TP — magique | non |
| Voir ce qui tourne | UI ArgoCD, un coup d'œil | non |
| Drift silencieux | détecté en quelques secondes | non |
| Donner droits à un dev | RBAC ArgoCD + AppProject — ne **touche pas** au RBAC K8s | non |
| Hotfix urgence 3h | **plus contraignant** — il faut faire une PR, attendre la sync. On ne peut plus `kubectl edit` directement. | **OUI**, mais c'est *justifié* : un hotfix non-tracé est exactement ce qui cause les incidents futurs |
| Audit 6 mois | `git log` — magique | non |
| Re-déployer from scratch | re-lancer la root, ArgoCD fait le reste | non |
| Désinstaller un service | supprimer le fichier — prune fait le reste | non |
| Tester un changement risqué | sur sa preview, isolée | non |

**Opérations plus contraignantes** :
1. **Hotfix urgence** — c'est l'objection classique. Réponse : on garde un
   *break-glass* documenté (un compte `platform-admin` avec kubeconfig en
   coffre-fort, à n'utiliser que si ArgoCD lui-même est down).
2. **Premier commit après installation** — il faut bootstrap la root à la
   main et ne pas se tromper. Le coût est ponctuel.

**L'opération qui justifie ArgoCD à elle seule** : la **détection du drift
silencieux**. Sans GitOps, personne ne s'aperçoit qu'un cluster a dérivé de
ses YAML jusqu'au prochain `kubectl apply` qui écrase tout — c'est la
source de la majorité des incidents post-mortem en production.

### Ce qu'ArgoCD ne sait pas faire

| Thème | Risque concret | Outil complémentaire | Référence |
|---|---|---|---|
| Déploiement progressif | un commit qui bump une image fait basculer 100 % du trafic d'un coup — pas de canary, pas de rollback automatique sur erreur taux | **Argo Rollouts** (analyse Prometheus + canary) ou Flagger | <https://argo-rollouts.readthedocs.io> |
| Validation manifests | rien n'empêche un dev de committer un `image: foo:latest` ou un Deployment sans probes | **Kyverno** (policies déclaratives, mode `validate`) | <https://kyverno.io/policies/> |
| Secrets dans Git | le token GitHub du `pullRequest generator` est manuel ; en prod, on ne peut pas demander aux devs de `kubectl create secret` partout | **External Secrets Operator** (sync depuis Vault/AWS SM) ou **Sealed Secrets** (chiffrement asymétrique) | <https://external-secrets.io/> |
| Signature images | rien n'empêche un attaquant qui obtient les droits GHCR de pousser une image malveillante avec un tag valide | **cosign** + admission policy Kyverno qui exige une signature valide | <https://docs.sigstore.dev/cosign/overview/> |
| RBAC multi-équipe | notre RBAC est local CSV, pas d'OIDC, pas de mapping groupes AD | OIDC (Dex en interne ou IdP type Okta/Google) avec mapping groupes → rôles | <https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/> |
| Disaster recovery | si un PVC PostgreSQL est corrompu, ArgoCD ne sait pas restaurer | **Velero** pour les snapshots de PVC + jobs CronJob de dump SGBD | <https://velero.io/docs/> |
| Multi-cluster | un seul cluster est géré ; en prod on a souvent dev / staging / prod en clusters séparés | `ApplicationSet` avec `cluster generator` + ArgoCD en mode hub | <https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Cluster/> |

### Si demain je deviens responsable de la plateforme

Trois briques ajoutées en priorité :
1. **Sealed Secrets** — parce que la première fois qu'on veut ajouter une vraie DB en prod, on est bloqué sans solution de secrets-in-Git.
2. **Kyverno** — une policy qui interdit `:latest`, qui exige `runAsNonRoot`, et qui force les labels `app.kubernetes.io/*`. Coût d'install : une heure. Bénéfice : on dort mieux.
3. **Argo Rollouts** — dès qu'on a un trafic réel, on ne déploie plus en *big bang*. Canary 10 % → analyse Prometheus → 100 %.

---

## Pratiques DevOps appliquées

| Pratique | Où la trouver dans le repo |
|---|---|
| Séparation app / ops | dossiers `*-service/` vs `platform/` |
| Image immutable, SHA court | CI workflows + `helm.parameters` dans les Applications |
| Multi-stage Dockerfile, non-root | Dockerfile de chaque service |
| OCI labels | `LABEL` dans les Dockerfiles + flags `--label` du Makefile |
| Scan trivy bloquant | `make images-scan` + job CI `build-and-scan` |
| Helm schema | `chart/values.schema.json` |
| Pre-commit hooks | `.pre-commit-config.yaml` |
| AppProject restrictif | `platform/projects/devhub.yaml` |
| RBAC ArgoCD | `platform/rbac/policy.csv` + values |
| selfHeal sur dev | `platform/apps/dev/*.yaml` |
| prune sur previews | `platform/apps/preview/*.yaml` |
| Notifications | `platform/notifications/triggers.yaml` |
| Métriques | values ArgoCD + RAPPORT.md § Étape 9 |
| Reproductibilité versions | `Makefile` (variables pinées) |
| Documentation vivante | ce fichier + README racine + README par service |
