# Changelog

All notable changes to the Run:AI Log Collector will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
