# argocd

GitOps configuration for deploying the taskapp stack to Kubernetes using ArgoCD. Implements the [App-of-Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) pattern with a centralized ArgoCD instance on a dedicated management cluster managing both dev and prod.

`backend-operator` owns its deployment chart in its own repo (`path: chart`), sourced by its own dedicated Application template. `backend` and `frontend` also own their chart in their own repo, but are onboarded through a `taskapp-catalog` `ApplicationSet` instead: it reads `catalog/<service>/<env>.yaml` files directly from [`application-repositories`](https://github.com/entr0pian/application-repositories) (a `git` generator) and resolves each entry's target cluster from ArgoCD's own registered clusters via an `environment`-label match (a `clusters` generator, joined with the catalog via `matrix`) — no CR, no operator, no write-back commit into this repo. Shared/infra charts (`platform`, `crossplane-provider-config`) live in the companion repo: [`taskapp-helmcharts`](https://github.com/entr0pian/helm-charts). `helm-charts/crossplane-compositions` (the old RDS/SQS compositions, built on Crossplane 1.x cluster-scoped resources) still exists in that repo but is no longer referenced from here — superseded by the OCI-packaged `crossplane-compositions-package`. Everything else (`kube-prometheus-stack`, `external-secrets`, `keda`, `crossplane`, `atlas-operator`) is a third-party Helm chart pulled directly from its upstream repo.

## Repository Structure

```
argocd/
├── root-dev.yaml               # Root ArgoCD Application for dev
├── root-prod.yaml              # Root ArgoCD Application for prod
├── root-management.yaml        # Root ArgoCD Application for management
└── apps/
    ├── Chart.yaml
    ├── values.yaml              # Shared defaults + per-app `enabled` defaults
    ├── values-dev.yaml          # Dev environment overrides (image tags, secret paths, enabled flags)
    ├── values-prod.yaml         # Prod environment overrides
    ├── values-management.yaml  # Management environment overrides (minimal footprint - no workloads)
    └── templates/
        ├── kube-prometheus-stack-app.yaml             # Prometheus, Grafana, AlertManager (wave 0)
        ├── external-secrets-app.yaml                  # External Secrets Operator (wave 0)
        ├── keda-app.yaml                               # KEDA autoscaler (wave 0)
        ├── crossplane-app.yaml                        # Crossplane core (wave 0)
        ├── platform-app.yaml                          # Cluster-wide resources: LimitRange, PrometheusRules, Grafana dashboard, ClusterSecretStore (wave 1)
        ├── backend-operator-app.yaml                   # Backend operator; provisions RDS/SQS via Crossplane (wave 1)
        ├── atlas-operator-app.yaml                     # Atlas schema-migration operator (wave 1)
        ├── crossplane-provider-config-app.yaml         # Crossplane ProviderConfig (wave 2)
        ├── crossplane-compositions-package-app.yaml    # Crossplane Configuration package (OCI); management only (wave 1)
        └── catalog-appset.yaml                         # taskapp-catalog ApplicationSet: one Application per catalog/<service>/<env>.yaml; management only (wave 5)
```

There is no `database-app.yaml` — the backend operator provisions RDS itself via Crossplane.

## Applications

| App | Namespace | Wave | Source | Slack notifications |
|---|---|---|---|---|
| `kube-prometheus-stack` | `monitoring` | 0 | prometheus-community Helm chart v84.4.0 | — |
| `external-secrets` | `external-secrets` | 0 | external-secrets Helm chart v0.14.4 | — |
| `keda` | `keda` | 0 | kedacore Helm chart v2.16.1 | — |
| `crossplane` | `crossplane-system` | 0 | charts.crossplane.io Helm chart | — |
| `taskapp-platform` | `default` | 1 | `helm-charts/platform` | sync succeeded/failed |
| `taskapp-backend-operator` | `default` | 1 | operator's own repo (`backend-operator.git`), `path: chart` | sync succeeded/failed |
| `atlas-operator` | `atlas-operator` | 1 | ghcr.io/ariga/charts v0.7.36 | sync succeeded/failed |
| `crossplane-provider-config` | `crossplane-system` | 2 | `helm-charts/crossplane-provider-config` | sync succeeded/failed |
| `crossplane-compositions-package` | `crossplane-system` | 1 | `crossplane-compositions.git` (directory source, OCI `Configuration` CR); management only | sync succeeded/failed |
| `<service>-<env>` (one per `catalog/<service>/<env>.yaml`, e.g. `backend-dev`) | per-entry | 5 | onboarded repo's own chart, `taskapp-catalog` ApplicationSet | — |

Wave 0 installs cluster infrastructure (monitoring, secrets, autoscaling, Crossplane core). Wave 1 applies cluster-wide resources, the operators that depend on them, and the Crossplane Configuration package. Wave 2 configures Crossplane provider auth. Wave 5 deploys catalog-onboarded application components (`catalog-appset.yaml`) once every earlier wave's infrastructure exists — see [`application-repositories`](https://github.com/entr0pian/application-repositories) for how `backend`/`frontend` get onboarded here instead of a per-app template.

All apps use `automated` sync with `selfHeal: true` and `prune: true`. `kube-prometheus-stack`, `keda`, `crossplane`, and `atlas-operator` use `ServerSideApply=true` to avoid annotation size limits on CRDs.

## Conditionally enabling apps (`enabled` flags)

Every Application template is wrapped in `{{- if .Values.<app>.enabled }}`. Whether an app renders is controlled per environment:

- **Platform-utility apps** (`kubePrometheusStack`, `externalSecrets`, `keda`, `crossplane`, `crossplaneProviderConfig`, `platform`, `atlasOperator`, `operator`) default to `enabled: true` in the base `apps/values.yaml`. They render in every environment unless an env file explicitly overrides that key to `false` — `values-management.yaml` does this for all of them except `externalSecrets` and `platform`, since the management cluster runs no application workloads.
- **`catalog`** has no default either — it's only set `enabled: true` in `values-management.yaml`, since the `taskapp-catalog` ApplicationSet is a singleton that must exist exactly once, wherever ArgoCD's own ApplicationSet controller runs.
- **`backend` and `frontend`** are not top-level keys at all — they're onboarded by adding a file to `catalog/<service>/<env>.yaml` in [`application-repositories`](https://github.com/entr0pian/application-repositories) rather than a `.Values.<app>.enabled` flag. See that repo's README for the file shape.

Helm/ArgoCD deep-merges `values.yaml` with the env's `valueFiles` entry, so an env file only needs to specify the keys it's overriding — e.g. to turn an app off in prod without touching dev:

```yaml
# values-prod.yaml
crossplane:
  enabled: false
```

## Environments

| Environment | Cluster | Secret Path | Root Manifest |
|---|---|---|---|
| `dev` | `kind-dev` | `taskapp/dev/crossplane-aws`, `taskapp/dev/backend-credentials` | `root-dev.yaml` |
| `prod` | `kind-prod` | `taskapp/prod/crossplane-aws`, `taskapp/prod/backend-credentials` | `root-prod.yaml` |
| `management` | `kind-management` (where ArgoCD itself runs) | `taskapp/platform/argocd-write-token` | `root-management.yaml` |

The `destinationServer` for dev/prod is the Docker internal IP of the kind cluster control plane, registered in ArgoCD during cluster bootstrap. Cluster registration also carries an `environment: dev`/`environment: prod` label on the registered cluster Secret, which the `taskapp-catalog` ApplicationSet's `clusters` generator matches on. `management` uses no override — `destinationServer` defaults to `https://kubernetes.default.svc`, deploying into wherever ArgoCD's own control plane runs, so no separate cluster registration is needed for it.

## Bootstrap

ArgoCD runs on the management cluster. After bootstrapping (see `bootstrap-cluster/`), apply the root manifest for each environment:

```bash
kubectl apply -f root-management.yaml --context kind-management
kubectl apply -f root-dev.yaml --context kind-management
kubectl apply -f root-prod.yaml --context kind-management
```

ArgoCD creates all child applications automatically and syncs them in wave order.

## Notifications

Deployment events are sent to the `#deployments` Slack channel via ArgoCD Notifications. Subscribed events per app:

- `on-sync-succeeded` / `on-sync-failed` — `taskapp-platform`, `taskapp-backend-operator`, `atlas-operator`, `crossplane-provider-config`, `crossplane-compositions-package`
- Catalog-onboarded apps rendered by `catalog-appset.yaml` (e.g. `backend-dev`) are not currently subscribed to any notification.

`kube-prometheus-stack`, `external-secrets`, `keda`, and `crossplane` are not subscribed to notifications.
