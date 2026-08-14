# argocd

GitOps configuration for deploying the taskapp stack to Kubernetes using ArgoCD. A single centralized ArgoCD instance runs on a dedicated management cluster and manages dev, prod, and itself — there is no per-environment App-of-Apps anymore, only one root Application (`root-management.yaml`), because everything it renders reaches *out* to dev/prod rather than being deployed by something running *in* them.

This chart's own job has shrunk to almost nothing: it bootstraps **three ApplicationSets** and gets out of the way. Everything else — every service, every piece of cluster infrastructure, every versioned platform API package — is declared as a file in [`application-repositories`](https://github.com/entr0pian/application-repositories), read directly by whichever ApplicationSet owns that kind of file. No per-app Application template lives in this repo.

- **`taskapp-catalog`** reads `catalog/<service>/<env>.yaml` — one file per onboarded service per environment (`backend`, `frontend`, ...).
- **`taskapp-infra`** reads `infra/<component>/<env>.yaml` — one file per cluster-infrastructure component per environment (`kube-prometheus-stack`, `platform`, `crossplane`, ...).
- **`taskapp-packages`** reads `packages/<package>/<env>.yaml` — one file per versioned Crossplane platform API package per environment (`crossplane-compositions`, ...). Deploying a new version is a one-line `package.version` diff in `application-repositories` — publishing a new OCI package never deploys it by itself.
- `taskapp-catalog`/`taskapp-infra` merge their identity file against a paired `values/<name>/<env>.yaml` — identity (repo, chart path, namespace) and parameters (image tags, toggles) are separate concerns, kept in separate files on purpose. All three resolve their target cluster from ArgoCD's own registered clusters via an `environment`-label match. No CR, no operator, no write-back commit into this repo, ever.

## Repository Structure

```
argocd/
├── root-management.yaml        # Root ArgoCD Application — the only one, applied once
└── apps/
    ├── Chart.yaml
    └── templates/
        ├── catalog-appset.yaml    # taskapp-catalog ApplicationSet
        ├── infra-appset.yaml      # taskapp-infra ApplicationSet
        └── package-appset.yaml    # taskapp-packages ApplicationSet
```

No `values.yaml` — there's nothing left for it to hold. With only one root Application, `catalog`/`infra`/`packages` would always be `enabled: true` and `applicationRepositories.repoURL` would never vary, so both the `{{- if .Values.*.enabled }}` gates and the `.Values` indirection for repo definitions were pure ceremony — every template now renders unconditionally with its repo/revision/channel hardcoded directly.

There used to be a `root-dev.yaml`/`root-prod.yaml` pair too, rendering this same chart with `values-dev.yaml`/`values-prod.yaml`. Both were removed — they were a leftover of the old per-environment App-of-Apps model; once every ApplicationSet started resolving its own destination cluster directly, dev and prod stopped needing a root Application of their own at all.

## How the three ApplicationSets work

All three are the same overall shape — a `matrix` of one or two `git` generators and a `clusters` generator:

```
matrix:
  - merge(mergeKeys: [name]):        # catalog/infra only
      - git: files: ["catalog/*/*.yaml"]   # or "infra/*/*.yaml", "packages/*/*.yaml"
      - git: files: ["values/*/*.yaml"]    # catalog/infra only
  - clusters:
      selector.matchLabels.environment: "{{ trimSuffix \".yaml\" .path.filename }}"
```

`catalog`/`infra`'s `merge` left-joins each identity file (e.g. `catalog/backend/dev.yaml`) with its optional counterpart (`values/backend/dev.yaml`) on a flat `name: <service>-<env>` field every file carries explicitly — **not** on `path.basename`/`path.filename`, even though those are real, correctly-populated fields (confirmed by using the `values/*/*.yaml` generator standalone). ArgoCD's `merge` generator does a flat top-level key lookup, not a nested-path walk, so a nested field always evaluated to `null` there — invisible with one file per side, but a hard "duplicate key" error the moment `values/` held more than one file, since every item collapsed onto the same `null` key. A values file is never required — every identity file carries a `values: ""` default the paired file can override. `packages` skips the `merge` entirely — it only has one git generator, since a package's contract file isn't split into a separate identity/values pair (see `application-repositories`' README for why). All three then join their result against whichever registered ArgoCD cluster carries a matching `environment` label via the outer `matrix`, resolving `destination.server` live — never hardcoded anywhere in any of these repos.

**Why identity and values are separate files, for `catalog`/`infra`:** they hold onboarding-time facts (repo, chart path, namespace) that rarely change; `values/` holds what actually changes on every deploy (image tags, toggles). Keeping them apart is a deliberate separation of concerns — it means a CI bot's write access can eventually be scoped to `values/` alone, physically unable to touch where a chart lives, even before that CI wiring exists. `packages` doesn't need this split: the one field that changes on every promotion, `package.version`, *is* the deployed identity, so there's no separate "identity" half to carve out.

**Why `source.helm.values` (a raw string) and not `source.helm.parameters` (a list) for overrides:** ApplicationSet's own template is a fixed-shape object, not a Helm-style whole-file text template — `{{ range }}`/`{{ if }}` can compute what a *string field's value* is, but can't add or remove array entries or YAML keys. A single `values: "..."` string field sidesteps this entirely: the source data just holds a raw, already-shaped YAML block, passed through verbatim (`catalog`/`infra` take it straight from their `values/` file; `package-appset.yaml` builds it inline from `.name`/`.package.*`/`.values.*` since a package contract has no pre-shaped `values` string to pass through). The same constraint is why `infra-appset.yaml` always has both `chart` and `path` fields present (empty string on whichever side is unused — ArgoCD omits an empty scalar field from the rendered Application) rather than trying to branch between them structurally, and why `syncOptions` is a fixed two-slot array (`CreateNamespace={{.createNamespace}}`, `ServerSideApply={{.serverSideApply}}`) instead of a variable-length list — an explicit `=false` is a no-op, same as the option being absent. This same reasoning is why the old `crossplane-compositions-package` Application couldn't just join `infra/` as another entry — it was a raw `source.directory` `Configuration` CR, and `source.helm`/`source.directory` are both structs that can't cleanly vanish when "unused" the way scalar fields can. `package-appset.yaml` sidesteps this permanently: every package is installed via the same tiny `charts/configuration-installer` Helm chart (from `crossplane-compositions`), so every generated Application is `source.helm`-shaped like `catalog`/`infra`, with no structural exception needed.

There is no `database-app.yaml` — the backend operator (when enabled) provisions RDS itself via Crossplane.

## Onboarding

**A new service:** add `application-repositories/catalog/<service>/<env>.yaml`, plus `values/<service>/<env>.yaml` if it needs anything beyond the chart's own defaults. Nothing in this repo changes.

**A new piece of infrastructure:** add `application-repositories/infra/<component>/<env>.yaml` the same way. See that repo's README for the exact shape.

**A new versioned platform API package:** add `application-repositories/packages/<package>/<env>.yaml` the same way. `package-appset.yaml` is generic over the contract — nothing here changes, for this package or any future one.

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

ArgoCD creates the three ApplicationSets and everything they generate automatically, including everything deployed into dev and prod.

## Notifications

Deployment events are sent to the `#deployments` Slack channel via ArgoCD Notifications.

- Every `taskapp-packages`-generated Application — always subscribed (`on-sync-succeeded`/`on-sync-failed`), fixed in `package-appset.yaml`'s template.
- Every `taskapp-infra`-generated Application — controlled per-file by that component's `notify: true`/`false` field in `application-repositories/infra/<component>/<env>.yaml`.
- Every `taskapp-catalog`-generated Application — never subscribed; not a field in the catalog file shape.
