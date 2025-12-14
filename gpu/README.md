# GPU Operator Log Collector

Collects NVIDIA GPU Operator logs and cluster GPU information.

## Usage

```bash
./start.sh
```

## Output

Creates `gpu-operator-logs-<timestamp>.tar.gz` containing:

- Cluster and node information
- GPU Operator pod logs (current + previous)
- Pod descriptions
- ConfigMaps, DaemonSets, Secrets
- Helm values
- ClusterPolicies and NodeFeatures
- GPU-related events

## Prerequisites

- `kubectl` with cluster access
- `helm` (optional, for values extraction)
- `jq` (optional, for Helm release detection)

