# argocd

GitOps configuration for deploying the taskapp stack to Kubernetes using ArgoCD. Implements the [App-of-Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/) pattern with a centralized ArgoCD instance on a dedicated management cluster managing both dev and prod.

Helm charts for all components live in the companion repo: [`taskapp-helmcharts`](https://github.com/entr0pian/helm-charts).

## Repository Structure

```
argocd/
├── root-dev.yaml               # Root ArgoCD Application for dev
├── root-prod.yaml              # Root ArgoCD Application for prod
└── apps/
    ├── Chart.yaml
    ├── values.yaml             # Shared defaults (repoURL, targetRevision)
    ├── values-dev.yaml         # Dev environment overrides
    ├── values-prod.yaml        # Prod environment overrides
    └── templates/
        ├── kube-prometheus-stack-app.yaml  # Prometheus, Grafana, AlertManager (wave 0)
        ├── external-secrets-app.yaml       # External Secrets Operator (wave 0)
        ├── keda-app.yaml                   # KEDA autoscaler (wave 0)
        ├── platform-app.yaml               # Cluster-wide resources (wave 1)
        ├── database-app.yaml               # PostgreSQL (wave 2)
        ├── backend-app.yaml                # Go REST API (wave 2)
        └── frontend-app.yaml               # React SPA (wave 2)
```

## Applications

| App | Namespace | Wave | Source |
|---|---|---|---|
| `kube-prometheus-stack` | `monitoring` | 0 | prometheus-community Helm chart v84.4.0 |
| `external-secrets` | `external-secrets` | 0 | external-secrets Helm chart v0.14.4 |
| `keda` | `keda` | 0 | kedacore Helm chart v2.16.1 |
| `taskapp-platform` | `default` | 1 | `helm-charts/platform` |
| `taskapp-database` | `default` | 2 | `helm-charts/database` |
| `taskapp-backend` | `default` | 2 | `helm-charts/backend` |
| `taskapp-frontend` | `default` | 2 | `helm-charts/frontend` |

Wave 0 installs cluster infrastructure (monitoring, secrets, autoscaling). Wave 1 applies cluster-wide resources including the `ClusterSecretStore` and `ExternalSecrets` that wave 2 depends on. Wave 2 deploys the application components.

All apps use `automated` sync with `selfHeal: true` and `prune: true`. `kube-prometheus-stack` and `keda` use `ServerSideApply=true` to avoid annotation size limits on CRDs.

## Environments

| Environment | Cluster | Secret Path | Root Manifest |
|---|---|---|---|
| `dev` | `kind-dev` | `taskapp/dev/database` | `root-dev.yaml` |
| `prod` | `kind-prod` | `taskapp/prod/database` | `root-prod.yaml` |

The `destinationServer` for each environment is the Docker internal IP of the kind cluster control plane, registered in ArgoCD during cluster bootstrap.

## Bootstrap

ArgoCD runs on the management cluster. After bootstrapping (see `bootstrap-cluster/`), apply the root manifest for each environment:

```bash
kubectl apply -f root-dev.yaml --context kind-management
kubectl apply -f root-prod.yaml --context kind-management
```

ArgoCD creates all child applications automatically and syncs them in wave order.

## Notifications

Deployment events are sent to the `#deployments` Slack channel via ArgoCD Notifications. Subscribed events per app:

- `on-sync-succeeded` / `on-sync-failed` — backend, frontend, database, platform
- `on-smoke-test-failed` — backend only (PostSync smoke-test job)
