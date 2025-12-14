# Run:AI Log Collector

A collection of diagnostic utilities for Run:AI environments. These scripts automate the collection of logs, configurations, and resource manifests from Kubernetes clusters to aid in debugging and troubleshooting.

## Prerequisites

- **kubectl** (with cluster access)
- **helm**

## Collectors

| Folder | Purpose |
|--------|---------|
| `cluster/` | Cluster-wide logs from Run:AI namespaces |
| `scheduler/` | Scheduler resources (projects, queues, nodepools, departments) |
| `workload/` | Individual workload diagnostics |
| `gpu/` | GPU Operator logs and configuration |

See each folder's README for usage instructions.
