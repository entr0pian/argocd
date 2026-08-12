# argocd

GitOps configuration for deploying the taskapp stack to Kubernetes using ArgoCD. A single centralized ArgoCD instance runs on a dedicated management cluster and manages dev, prod, and itself — there is no per-environment App-of-Apps anymore, only one root Application (`root-management.yaml`), because everything it renders reaches *out* to dev/prod rather than being deployed by something running *in* them.

This chart's own job has shrunk to almost nothing: it bootstraps **two ApplicationSets** and one legacy Application, and gets out of the way. Everything else — every service, every piece of cluster infrastructure — is declared as a file in [`application-repositories`](https://github.com/entr0pian/application-repositories), read directly by whichever ApplicationSet owns that kind of file. No per-app Application template lives in this repo anymore.

- **`taskapp-catalog`** reads `catalog/<service>/<env>.yaml` — one file per onboarded service per environment (`backend`, `frontend`, ...).
- **`taskapp-infra`** reads `infra/<component>/<env>.yaml` — one file per cluster-infrastructure component per environment (`kube-prometheus-stack`, `platform`, `crossplane`, ...).
- Both are structurally identical: one file holds everything, including Helm overrides — no separate values tree. Both resolve their target cluster from ArgoCD's own registered clusters via an `environment`-label match. No CR, no operator, no write-back commit into this repo, ever.
- **`crossplane-compositions-package`** is the one exception, still a hand-written Application template — it's a raw `directory` source (an OCI `Configuration` CR), structurally incompatible with the two ApplicationSets' shared Helm-chart-shaped template (`source.helm` and `source.directory` don't cleanly disappear when "unused" the way scalar fields do — confirmed empirically, not assumed).

## Repository Structure

```
argocd/
├── root-management.yaml        # Root ArgoCD Application — the only one, applied once
└── apps/
    ├── Chart.yaml
    ├── values.yaml                  # applicationRepositories.repoURL, notifications channel, catalog/infra enabled defaults
    ├── values-management.yaml       # env: management, catalog/infra/crossplaneCompositionsPackage enabled: true
    └── templates/
        ├── catalog-appset.yaml              # taskapp-catalog ApplicationSet
        ├── infra-appset.yaml                # taskapp-infra ApplicationSet
        └── crossplane-compositions-package-app.yaml   # the one hand-written exception
```

There used to be a `root-dev.yaml`/`root-prod.yaml` pair too, rendering this same chart with `values-dev.yaml`/`values-prod.yaml`. Both were removed — `.Values.env` is referenced in exactly one place in this whole chart (`crossplane-compositions-package-app.yaml`, management-only), so rendering with the dev/prod values files produced zero resources. They were a leftover of the old per-environment App-of-Apps model; once both ApplicationSets started resolving their own destination cluster directly, dev and prod stopped needing a root Application of their own at all.

## How the two ApplicationSets work

Both are the same shape — a `matrix` of one `git` generator and a `clusters` generator:

```
matrix:
  - git: files: ["catalog/*/*.yaml"]   # or "infra/*/*.yaml"
  - clusters:
      selector.matchLabels.environment: "{{ trimSuffix \".yaml\" .path.filename }}"
```

The `git` generator produces one item per matched file; the `matrix` joins each against whichever registered ArgoCD cluster carries a matching `environment` label, resolving `destination.server` live — never hardcoded anywhere in either repo.

**No separate values file, for either.** A `catalog/`+`values/` split (governed separately, so a CI bot's write access could be scoped away from `repoURL`/`chartPath`) was tried and reverted — the boundary only earns its keep once something actually writes to it at high frequency, and nothing does yet: the old write-back path was retired along with `repositories-app.yaml`, and CI hasn't been repointed to write anywhere new (see the CI item below). Building the split ahead of that writer existing was speculative structure with no real benefit yet. Re-introduce it — for `catalog/` specifically, or for any one `infra/` component — exactly when something starts writing there on every push, not before.

**Why `source.helm.values` (a raw string) and not `source.helm.parameters` (a list) for overrides:** ApplicationSet's own template is a fixed-shape object, not a Helm-style whole-file text template — `{{ range }}`/`{{ if }}` can compute what a *string field's value* is, but can't add or remove array entries or YAML keys. A single `values: "{{.values}}"` string field sidesteps this entirely: the file just holds a raw, already-shaped YAML block. The same constraint is why `infra-appset.yaml` always has both `chart` and `path` fields present (empty string on whichever side is unused — ArgoCD omits an empty scalar field from the rendered Application) rather than trying to branch between them structurally, and why `syncOptions` is a fixed two-slot array (`CreateNamespace={{.createNamespace}}`, `ServerSideApply={{.serverSideApply}}`) instead of a variable-length list — an explicit `=false` is a no-op, same as the option being absent. This same reasoning is why `crossplane-compositions-package` can't just join `infra/` as another entry — `source.helm` and `source.directory` are both structs, and unlike scalar fields, an "unused" struct doesn't cleanly vanish from the rendered Application.

There is no `database-app.yaml` — the backend operator (when enabled) provisions RDS itself via Crossplane.

## Onboarding

**A new service:** add `application-repositories/catalog/<service>/<env>.yaml` — one file. Nothing in this repo changes.

**A new piece of infrastructure:** add `application-repositories/infra/<component>/<env>.yaml` — one file, no pairing needed. See that repo's README for the exact shape.

## Environments

| Environment | Cluster |
|---|---|
| `dev` | `kind-dev` |
| `prod` | `kind-prod` |
| `management` | `kind-management` (where ArgoCD itself runs — the only cluster this repo has a root Application for) |

All three clusters are registered in ArgoCD with an `environment: <name>` label on their cluster Secret — `dev`/`prod` via `bootstrap-cluster/kind/setup-clusters.sh`'s Docker-internal-IP registration, `management` via an explicit Secret for the otherwise-implicit `https://kubernetes.default.svc` local cluster (same script). This label is what every `clusters` generator in this repo matches on; nothing here references a cluster URL directly.

## Bootstrap

ArgoCD runs on the management cluster. After bootstrapping (see `bootstrap-cluster/`), apply the one root manifest:

```bash
kubectl apply -f root-management.yaml --context kind-management
```

ArgoCD creates the two ApplicationSets and everything they generate automatically, including everything deployed into dev and prod.

## Notifications

Deployment events are sent to the `#deployments` Slack channel via ArgoCD Notifications.

- `crossplane-compositions-package` — always subscribed (`on-sync-succeeded`/`on-sync-failed`), fixed in its template.
- Every `taskapp-infra`-generated Application — controlled per-file by that component's `notify: true`/`false` field in `application-repositories/infra/<component>/<env>.yaml`.
- Every `taskapp-catalog`-generated Application — never subscribed; not a field in the catalog file shape.
