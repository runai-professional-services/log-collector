# Run:AI Log Collector

A collection of diagnostic utilities for Run:AI environments. These scripts automate the collection of logs, configurations, and resource manifests from Kubernetes clusters to aid in debugging and troubleshooting.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Scripts](#scripts)
- [cluster.sh](#clustersh)
  - [Prerequisites](#prerequisites-1)
  - [Usage](#usage)
  - [Output](#output)
- [workload.sh](#workloadsh)
  - [Prerequisites](#prerequisites-2)
  - [Usage](#usage-1)
  - [Output](#output-1)
- [gpu.sh](#gpush)
  - [Prerequisites](#prerequisites-3)
  - [Usage](#usage-2)
  - [Output](#output-2)

## Prerequisites

- **kubectl** (with cluster access)
- **helm**

## Scripts

| Script | Purpose |
|--------|---------|
| `cluster.sh` | Cluster-wide logs from Run:AI namespaces + scheduler resources |
| `workload.sh` | Individual workload diagnostics |
| `gpu.sh` | GPU Operator logs and configuration |

---

## cluster.sh

Collects Run:AI cluster logs via kubectl and generates a general information dump to aid in debugging and troubleshooting Run:AI environments. Also includes scheduler resources (projects, queues, nodepools, departments).

### Prerequisites

- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) (with admin access to the cluster)
- [helm](https://helm.sh/docs/intro/install/)

### Usage

```bash
chmod +x ./cluster.sh
./cluster.sh
```

### Output

Creates timestamped `tar.gz` archives per namespace (`runai` / `runai-backend`).

#### `runai` namespace

**Folder structure:**

```
runai-logs-07-07-2025_14-30
├── cm_runai-public.yaml
├── engine-config.yaml
├── helm_charts_list.txt
├── helm-values_runai-cluster.yaml
├── logs
│   ├── <POD_NAME>_<CONTAINER_NAME>.log
│   ├── ...
├── node-list.txt
├── pod-list_runai.txt
├── runaiconfig.yaml
└── scheduler
    ├── projects.run.ai_list.txt
    ├── project_*.yaml
    ├── queues.scheduling.run.ai_list.txt
    ├── queue_*.yaml
    ├── nodepools.run.ai_list.txt
    ├── nodepool_*.yaml
    ├── departments.scheduling.run.ai_list.txt
    └── department_*.yaml
```

**File mapping:**

| File | Command |
|------|---------|
| `logs/${POD}_${CONTAINER}.log` | `kubectl -n $NAMESPACE logs --timestamps $POD -c $CONTAINER` |
| `cm_runai-public.yaml` | `kubectl -n runai get cm runai-public -o yaml` |
| `engine-config.yaml` | `kubectl -n runai get configs.engine.run.ai engine-config -o yaml` |
| `helm_charts_list.txt` | `helm ls -A` |
| `helm-values_runai-cluster.yaml` | `helm -n runai get values runai-cluster` |
| `node-list.txt` | `kubectl get nodes -o wide` |
| `pod-list_runai.txt` | `kubectl -n runai get pods -o wide` |
| `runaiconfig.yaml` | `kubectl -n runai get runaiconfig runai -o yaml` |
| `scheduler/projects.run.ai_list.txt` | `kubectl get projects.run.ai` |
| `scheduler/project_*.yaml` | Individual project manifests |
| `scheduler/queues.scheduling.run.ai_list.txt` | `kubectl get queues.scheduling.run.ai` |
| `scheduler/queue_*.yaml` | Individual queue manifests |
| `scheduler/nodepools.run.ai_list.txt` | `kubectl get nodepools.run.ai` |
| `scheduler/nodepool_*.yaml` | Individual nodepool manifests |
| `scheduler/departments.scheduling.run.ai_list.txt` | `kubectl get departments.scheduling.run.ai` |
| `scheduler/department_*.yaml` | Individual department manifests |

#### `runai-backend` namespace

**Folder structure:**

```
runai-backend-logs-07-07-2025_14-31
├── helm-values_runai-backend.yaml
├── logs
│   ├── <POD_NAME>_<CONTAINER_NAME>.log
│   ├── ...
└── pod-list_runai-backend.txt
```

**File mapping:**

| File | Command |
|------|---------|
| `logs/${POD}_${CONTAINER}.log` | `kubectl -n $NAMESPACE logs --timestamps $POD -c $CONTAINER` |
| `helm-values_runai-backend.yaml` | `helm -n runai-backend get values runai-backend` |
| `pod-list_runai-backend.txt` | `kubectl -n runai-backend get pods -o wide` |

---

## workload.sh

Collects and archives Run:AI workload diagnostics into a single timestamped archive.

### Prerequisites

- `kubectl` installed and configured
- Access to Kubernetes cluster with Run:AI workloads

### Usage

```bash
chmod +x ./workload.sh
./workload.sh --project <PROJECT> --type <TYPE> --workload <WORKLOAD>
```

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `--project` | Run:AI project name |
| `--workload` | Workload name |
| `--type` | Workload type: `tw`, `iw`, `dw`, `infw`, `dinfw`, `ew` |

**Example:**

```bash
./workload.sh --project ml-team --type dw --workload bert-training
```

### Output

Creates `<PROJECT>_<TYPE>_<WORKLOAD>_v<VERSION>_<TIMESTAMP>.tar.gz` containing:

#### Workload Resources

- Workload YAML (TrainingWorkload, DistributedWorkload, etc.)
- RunAIJob YAML
- PodGroup YAML
- KSVC YAML (inference workloads only)

#### Pod Resources (per pod)

- Pod YAML manifest
- Pod describe output
- Container logs (all containers)
- nvidia-smi output (when available)

#### Namespace Resources

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

---

## gpu.sh

Collects NVIDIA GPU Operator logs and cluster GPU information.

### Prerequisites

- `kubectl` with cluster access
- `helm` (optional, for values extraction)
- `jq` (optional, for Helm release detection)

### Usage

```bash
chmod +x ./gpu.sh
./gpu.sh
```

### Output

Creates `gpu-operator-logs-<timestamp>.tar.gz` containing:

- Cluster and node information
- GPU Operator pod logs (current + previous)
- Pod descriptions
- ConfigMaps, DaemonSets, Secrets
- Helm values
- ClusterPolicies and NodeFeatures
- GPU-related events
