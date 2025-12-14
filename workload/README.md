# Log collector: Workload

Collects and archives Run:AI workload diagnostics into a single timestamped archive.

## Prerequisites

- `kubectl` installed and configured
- Access to Kubernetes cluster with Run:AI workloads

## Usage

```bash
chmod +x ./start.sh
./start.sh --project <PROJECT> --type <TYPE> --workload <WORKLOAD>
```

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `--project` | Run:AI project name |
| `--workload` | Workload name |
| `--type` | Workload type: `tw`, `iw`, `dw`, `infw`, `dinfw`, `ew` |

**Example:**

```bash
./start.sh --project ml-team --type dw --workload bert-training
```

## Output

Creates `<PROJECT>_<TYPE>_<WORKLOAD>_v<VERSION>_<TIMESTAMP>.tar.gz` containing:

### Workload Resources

- Workload YAML (TrainingWorkload, DistributedWorkload, etc.)
- RunAIJob YAML
- PodGroup YAML
- KSVC YAML (inference workloads only)

### Pod Resources (per pod)

- Pod YAML manifest
- Pod describe output
- Container logs (all containers)
- nvidia-smi output (when available)

### Namespace Resources

- All Pods (list with wide output)
- All ConfigMaps
- All PVCs
- All Services
- All Ingresses
- All Routes (OpenShift)

**Features:**

- Resilient collection (continues on individual failures)
- Optimized pod discovery (single kubectl call)
- Clear naming: `<workload>_<type>_<resource>.yaml`
