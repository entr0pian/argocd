# argocd

GitOps configuration for deploying the taskapp stack to Kubernetes using ArgoCD. Implements the [App-of-Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) pattern with a centralized ArgoCD instance on a dedicated management cluster managing both dev and prod.

`backend`, `frontend`, `backend-operator`, and `application-repository-operator` each own their deployment chart in their own repo (`path: chart`). Shared/infra charts (`platform`, `crossplane-provider-config`, `crossplane-compositions`) live in the companion repo: [`taskapp-helmcharts`](https://github.com/entr0pian/helm-charts). Everything else (`kube-prometheus-stack`, `external-secrets`, `keda`, `crossplane`, `atlas-operator`) is a third-party Helm chart pulled directly from its upstream repo.

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
        ├── _helpers.tpl                              # shared `ignoreDifferences` block for autoscaled apps
        ├── kube-prometheus-stack-app.yaml             # Prometheus, Grafana, AlertManager (wave 0)
        ├── external-secrets-app.yaml                  # External Secrets Operator (wave 0)
        ├── keda-app.yaml                               # KEDA autoscaler (wave 0)
        ├── crossplane-app.yaml                        # Crossplane core (wave 0)
        ├── platform-app.yaml                          # Cluster-wide resources: LimitRange, PrometheusRules, Grafana dashboard, ClusterSecretStore (wave 1)
        ├── backend-operator-app.yaml                   # Backend operator; provisions RDS/SQS via Crossplane (wave 1)
        ├── application-repository-operator-app.yaml    # ApplicationRepository onboarding operator; management only (wave 1)
        ├── atlas-operator-app.yaml                     # Atlas schema-migration operator (wave 1)
        ├── crossplane-provider-config-app.yaml         # Crossplane ProviderConfig (wave 2)
        ├── crossplane-compositions-app.yaml            # Crossplane Compositions (wave 3)
        ├── backend-app.yaml                            # Go REST API (wave 4)
        └── frontend-app.yaml                           # React SPA (wave 4)
```

There is no `database-app.yaml` — the backend operator provisions RDS itself via Crossplane.

## Applications

| App | Namespace | Wave | Source | Slack notifications |
|---|---|---|---|---|
| `kube-prometheus-stack` | `monitoring` | 0 | prometheus-community Helm chart v84.4.0 | — |
| `external-secrets` | `external-secrets` | 0 | external-secrets Helm chart v0.14.4 | — |
| `keda` | `keda` | 0 | kedacore Helm chart v2.16.1 | — |
| `crossplane` | `crossplane-system` | 0 | charts.crossplane.io Helm chart v1.19.1 | — |
| `taskapp-platform` | `default` | 1 | `helm-charts/platform` | sync succeeded/failed |
| `taskapp-backend-operator` | `default` | 1 | operator's own repo (`backend-operator.git`), `path: chart` | sync succeeded/failed |
| `application-repository-operator` | `default` | 1 | operator's own repo (`application-repository-operator.git`), `path: chart`; management only | sync succeeded/failed |
| `atlas-operator` | `atlas-operator` | 1 | ghcr.io/ariga/charts v0.7.36 | sync succeeded/failed |
| `crossplane-provider-config` | `crossplane-system` | 2 | `helm-charts/crossplane-provider-config` | sync succeeded/failed |
| `crossplane-compositions` | `crossplane-system` | 3 | `helm-charts/crossplane-compositions` | sync succeeded/failed |
| `taskapp-backend` | `default` | 4 | backend's own repo (`backend.git`), `path: chart` | sync succeeded/failed, smoke-test failed |
| `taskapp-frontend` | `default` | 4 | frontend's own repo (`frontend.git`), `path: chart` | sync succeeded/failed |

Wave 0 installs cluster infrastructure (monitoring, secrets, autoscaling, Crossplane core). Wave 1 applies cluster-wide resources and the operators that depend on them. Waves 2–3 configure Crossplane provider auth and compositions. Wave 4 deploys the application components once their infrastructure dependencies exist.

All apps use `automated` sync with `selfHeal: true` and `prune: true`. `kube-prometheus-stack`, `keda`, `crossplane`, and `atlas-operator` use `ServerSideApply=true` to avoid annotation size limits on CRDs.

## Conditionally enabling apps (`enabled` flags)

Every Application template is wrapped in `{{- if .Values.<app>.enabled }}`. Whether an app renders is controlled per environment:

- **Platform-utility apps** (`kubePrometheusStack`, `externalSecrets`, `keda`, `crossplane`, `crossplaneProviderConfig`, `crossplaneCompositions`, `platform`, `atlasOperator`, `operator`) default to `enabled: true` in the base `apps/values.yaml`. They render in every environment unless an env file explicitly overrides that key to `false` — `values-management.yaml` does this for all of them except `externalSecrets` and `platform`, since the management cluster runs no application workloads.
- **`backend` and `frontend`** have no default in `apps/values.yaml` — they're optional per environment and must be explicitly set with `enabled: true` in `values-dev.yaml` / `values-prod.yaml` to render at all. Both currently do.
- **`applicationRepositoryOperator`** has no default either — it's only set `enabled: true` in `values-management.yaml`, since this operator runs centrally in the management cluster, not per dev/prod.

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

The `destinationServer` for dev/prod is the Docker internal IP of the kind cluster control plane, registered in ArgoCD during cluster bootstrap. `management` uses no override — `destinationServer` defaults to `https://kubernetes.default.svc`, deploying into wherever ArgoCD's own control plane runs, so no `argocd cluster add` registration is needed for it.

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

- `on-sync-succeeded` / `on-sync-failed` — `taskapp-platform`, `taskapp-backend-operator`, `application-repository-operator`, `atlas-operator`, `crossplane-provider-config`, `crossplane-compositions`, `taskapp-backend`, `taskapp-frontend`
- `on-smoke-test-failed` — `taskapp-backend` only (PostSync smoke-test job)

`kube-prometheus-stack`, `external-secrets`, `keda`, and `crossplane` are not subscribed to notifications.
