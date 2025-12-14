# Log collector: GPU

Collects NVIDIA GPU Operator logs and cluster GPU information.

## Prerequisites

- `kubectl` with cluster access
- `helm` (optional, for values extraction)
- `jq` (optional, for Helm release detection)

## Usage

```bash
chmod +x ./start.sh
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
