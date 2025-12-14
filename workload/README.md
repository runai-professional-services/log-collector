# Workload Info Dump v2.4.0

Collects and archives Run:AI workload diagnostics into a single timestamped archive.

## Usage

```sh
./start.sh --project <PROJECT> --type <TYPE> --workload <WORKLOAD>
```

**Parameters:**
- `--project` - Run:AI project name
- `--workload` - Workload name
- `--type` - Workload type: `tw`, `iw`, `dw`, `infw`, `dinfw`, `ew`

**Example:**
```sh
./start.sh --project ml-team --type dw --workload bert-training
```

## Resources Collected

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

## Output

Creates: `<PROJECT>_<TYPE>_<WORKLOAD>_v<VERSION>_<TIMESTAMP>.tar.gz`

**Features:**
- ✅ Resilient collection (continues on individual failures)
- ✅ Optimized pod discovery (single kubectl call)
- ✅ Clear naming: `<workload>_<type>_<resource>.yaml`