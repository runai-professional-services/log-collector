# Changelog

All notable changes to the Run:AI Log Collector will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **cluster.sh** – Control-plane API collection was skipped on current Run:AI
  self-hosted backends, so `idp-settings.json`, `clusters.json`, `tenants.json`,
  and `k8s-settings.json` were never written. The admin password was read from
  the `runai-backend-tenants-manager` Secret, which on these versions holds only
  `DB_USER`; the empty password failed the credential guard and the run reported
  `Could not retrieve RunAI credentials or control plane URL` and moved on. The
  archive was otherwise complete and the run exited as a success, so an
  SSO-integrated environment looked like one with no IDP configured. The
  password is now resolved from `runai-backend-credentials` (keys
  `ADMIN_PASSWORD` then `admin-password`), falling back to
  `runai-backend-tenants-manager` for older backends.

### Changed

- **cluster.sh** – When control-plane API collection is skipped, the warning
  names the specific lookup that came up empty (admin username, auth service
  URL, or password) instead of reporting all three together.

## [1.2.1] - 2026-09-06

### Fixed

- **cluster.sh** – Collection wrote each namespace into a folder named after the
  namespace in the current working directory, so a file or directory that
  already carried one of those names took its place. Reported from the field
  with a `runai` CLI binary sitting in the directory the script was run from:
  `mkdir -p ./runai` failed against the existing file, every write into
  `./runai/...` failed after it, and `tar` archived the binary in place of the
  logs — the summary still reported the namespace as collected (56 pods) and the
  run still exited as a success. The cleanup step then deleted the binary. Each
  run now collects into its own directory, named after the archive and created
  by the script, and only that directory is archived and removed. A run that
  cannot create it stops instead of producing an archive of nothing.
- **cluster.sh** – A failed `tar` was not detected, and cleanup deleted the
  collected logs regardless. The logs are now kept and the run exits non-zero.

### Changed

- **cluster.sh** – The archive unpacks into a single top-level folder rather
  than scattering namespace folders into the current directory. This is the
  layout the README already described.

## [1.2.0] - 2026-09-02

### Changed

- **gpu.sh** – The GPU Operator namespace is detected from the cluster instead of
  being hardcoded to `gpu-operator`, which collected nothing on installs that use
  another name (the OpenShift/OLM bundle uses `nvidia-gpu-operator`). Detection
  matches the operator's own labels on pods and Deployments, then a Deployment
  named `gpu-operator`, then the namespace names the installers use — the last
  step covering credentials that cannot list across all namespaces. `-n/--namespace`
  and `GPU_OPERATOR_NAMESPACE` override detection, and the resolved namespace is
  recorded in `collection-summary.txt`.
- **gpu.sh** – Helm values are read from the release whose chart is the GPU
  Operator rather than the first release in the namespace, so a namespace hosting
  more than one release no longer yields the wrong values.

### Added

- **gpu.sh** – `nvidiadrivers.yaml`, the NVIDIADriver CRs used by installs that
  manage the driver through its own resource rather than the ClusterPolicy.

### Fixed

- **gpu.sh** – `clusterpolicies.yaml` could contain Kyverno's ClusterPolicy
  objects instead of NVIDIA's. `kubectl` resolves a bare plural to whichever API
  group sorts first, and `kyverno.io` precedes `nvidia.com`, so a cluster running
  both silently returned the wrong resource. ClusterPolicy is now requested as
  `clusterpolicies.nvidia.com`. A CRD that is not installed is recorded as such,
  so an empty collection can no longer be mistaken for the operator reporting
  nothing.
- **gpu.sh** – `nodefeatures.yaml` was always empty. NodeFeature is namespaced
  and no namespace was passed, so the collection ran against whichever namespace
  the kubeconfig pointed at and returned an empty list with a success exit code.
  Every namespace is now searched, and the API group is resolved from discovery
  because it has changed between NFD releases.
- **gpu.sh**, **cluster.sh** – Every cluster with `oc` installed locally was
  reported as OpenShift. `oc api-resources --api-group=<group>` exits 0 and prints
  only a header for a group the server does not serve, so testing its exit code
  detected the local binary rather than the cluster. Both scripts now test the
  command's output, matching the check `workload.sh` already used; cluster-type
  detection and CLI selection are also separated, so an OpenShift cluster reached
  with only `kubectl` installed is still identified as OpenShift.

## [1.1.1] - 2026-07-26

### Security

- **cluster.sh** – Kubernetes Secret values are excluded from archives by
  default (metadata remains). Helm values are always collected; credential-looking
  keys (`password`, `token`, `clientSecret`, …) are replaced with `"<REDACTED>"`.
  Secret *references* and key-name fields (`existingSecret`, `extraEnvVarsSecret`,
  `passwordKey`, `adminPasswordKey`, …) are left intact. `--include-sensitive-data`
  opts into full Secret data and unredacted Helm values.
- **workload.sh** – Project and workload arguments are validated before they are
  used to construct local output paths.

## [1.1.0] - 2026-07-26

### Changed

- **workload.sh** – `--project` and `--workload` are now the only arguments. `--type` has been removed.
  - The workload type is detected from the cluster instead of being supplied by the caller.
  - The CR architecture is detected: native Run:AI workload CRDs, the `WorkloadRunner` introduced in 2.26 for the any-workload controller, or an `ExternalWorkload` wrapping a third-party resource. Both shapes can coexist on a 2.26 cluster, so `workloadrunners.run.ai` is probed before the native CRDs.
  - Child resources are discovered by walking owner references from the workload's UID rather than assuming a fixed layout, which covers the 2.26 relocation of networking resources under the `Job` and the replacement of `RunaiJob` with a `batch/v1 Job`.
  - Output is now a single folder inside the archive (`detection.txt`, `workload/`, `pods/`, `namespace/`) and includes a detection report with the resolved type, architecture and resource tree.
  - Secrets in the workload tree are captured with `describe` so credential values stay out of the archive.
  - Added namespace events and previous-instance container logs; dropped the `jq` dependency.
  - Every resource fetch retries once, so a transient API error no longer drops a resource from an archive that still looks complete.
  - Container logs are kept even when empty: a running container that has never logged is a real signal, and a missing file cannot be told apart from a failed collection.

## [1.0.0] - 2025-04-28

Initial versioned release of the Run:AI Log Collector.

### Included

- **cluster.sh** – Cluster-wide log collection from Run:AI namespaces, scheduler resources, and optional backend API data
- **workload.sh** (v2.5.1) – Per-workload diagnostics with OpenShift support and external workload types
- **gpu.sh** (v1.1.0) – GPU Operator log and configuration collection
- **scheduler_snapshot.sh** – Scheduler debug snapshot collection via port-forward
