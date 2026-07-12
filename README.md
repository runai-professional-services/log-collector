# Run:AI Log Collector

A collection of diagnostic utilities for Run:AI environments. These scripts automate the collection of logs, configurations, and resource manifests from Kubernetes clusters to aid in debugging and troubleshooting.

## Version

Current version: **1.0.0** (see [CHANGELOG.md](CHANGELOG.md) for release history)

This project uses [Semantic Versioning](https://semver.org/). Each release is tagged as `v<MAJOR>.<MINOR>.<PATCH>` (e.g. `v1.0.0`).

## Table of Contents

- [Version](#version)
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
- [scheduler_snapshot.sh](#scheduler_snapshotsh)
  - [Usage](#usage-3)
  - [What the snapshot contains](#what-the-snapshot-contains)
  - [Output](#output-3)

## Prerequisites

- **kubectl** (with cluster access)
- **helm**

## Scripts

| Script | Purpose |
|--------|---------|
| `cluster.sh` | Cluster-wide logs from Run:AI namespaces + scheduler resources |
| `workload.sh` | Individual workload diagnostics |
| `gpu.sh` | GPU Operator logs and configuration |
| `scheduler_snapshot.sh` | Scheduler debug snapshots from all Run:AI scheduler deployments |

---

## cluster.sh

Collects Run:AI cluster logs via kubectl (or `oc` on OpenShift) and generates a general information dump to aid in debugging and troubleshooting Run:AI environments. It processes the following namespaces when present: `runai`, `runai-backend`, `knative-serving`, `knative-operator`, and `runai-reservation`. It also collects scheduler resources (projects, queues, nodepools, departments, access rules).

Namespaces that don't exist are skipped automatically. On OpenShift the script uses `oc` and collects Routes instead of Ingresses. If the Knative operator namespace uses the alternate spelling `knativeoperator`, it is detected and collected automatically.

### Prerequisites

- [kubectl](https://kubernetes.io/docs/tasks/tools/#kubectl) (with admin access to the cluster) — or `oc` on OpenShift
- [helm](https://helm.sh/docs/intro/install/)
- `curl` and `jq` (optional) — required only for the Run:AI control-plane API data (IDP settings, clusters, tenants, K8s settings)

### Usage

```bash
chmod +x ./cluster.sh
./cluster.sh
```

Color output is enabled automatically on interactive terminals. Set `NO_COLOR=1` to disable it.

### Output

Creates a **single** combined archive containing one folder per collected namespace:

```
<control-plane>-runai-log-collector-output-<DD-MM-YYYY_HH-MM>.tar.gz
```

`<control-plane>` is derived from the control-plane URL (e.g. `itay-sloth-gpu-runailabs-cs-com`). Producing one archive means there is always exactly one file to attach, regardless of how many namespaces exist.

**Top-level structure:**

```
<control-plane>-runai-log-collector-output-<timestamp>/
├── collection-summary.txt
├── runai/
├── runai-backend/
├── knative-serving/
├── knative-operator/        # or "knativeoperator"
└── runai-reservation/
```

- **`collection-summary.txt`** — an at-a-glance report: cluster/control-plane URLs, CLI used, a per-namespace table of pods / total container restarts / issues, and any skipped namespaces.

#### Common to every namespace folder

| File / dir | Description |
|------------|-------------|
| `logs/${POD}_describe.txt` | `kubectl describe pod $POD` |
| `logs/${POD}_${CONTAINER}.log` | Current container logs (`kubectl logs --timestamps`) |
| `logs/${POD}_${CONTAINER}_previous.log` | Previous (pre-restart) container logs — only present when a container had restarted |
| `logs/${POD}_${CONTAINER}_init.log` | Init container logs (and `_init_previous.log` when applicable) |
| `events_<namespace>.txt` | `kubectl -n <namespace> get events --sort-by=.lastTimestamp` |
| `script.log` | Failures-only log for that namespace: any failed command with its `stderr`, plus warnings. States "no failures" when everything succeeded. |

#### `runai` namespace

| File | Command |
|------|---------|
| `helm_charts_list.txt` | `helm ls -A` |
| `helm-values_runai-cluster.yaml` | `helm -n runai get values runai-cluster` |
| `cm_runai-public.yaml` | `kubectl -n runai get cm runai-public -o yaml` |
| `configmaps_runai.yaml` | `kubectl -n runai get cm -o yaml` |
| `secrets_runai.yaml` | `kubectl -n runai get secrets -o yaml` |
| `ingress_runai.yaml` / `routes_runai.yaml` | Ingresses (kubectl) or Routes (OpenShift) |
| `pod-list_runai.txt` | `kubectl -n runai get pods -o wide` |
| `node-list.txt` | `kubectl get nodes -o wide` |
| `node-list-detailed.txt` | `kubectl get nodes` with CPU/RAM/GPU/OS/kubelet/runtime columns |
| `runaiconfig.yaml` | `kubectl -n runai get runaiconfig runai -o yaml` |
| `engine-config.yaml` | `kubectl -n runai get configs.engine.run.ai engine-config -o yaml` |
| `scheduler/projects.run.ai_list.txt` + `scheduler/project_*.yaml` | Projects list and individual manifests |
| `scheduler/queues.scheduling.run.ai_list.txt` + `scheduler/queue_*.yaml` | Queues list and individual manifests |
| `scheduler/nodepools.run.ai_list.txt` + `scheduler/nodepool_*.yaml` | Nodepools list and individual manifests |
| `scheduler/departments.scheduling.run.ai_list.txt` + `scheduler/department_*.yaml` | Departments list and individual manifests |
| `scheduler/accessrules.run.ai_list.txt` + `scheduler/accessrule_*.yaml` | Access rules list and individual manifests |

#### `runai-backend` namespace

| File | Command |
|------|---------|
| `pod-list_runai-backend.txt` | `kubectl -n runai-backend get pods -o wide` |
| `helm-values_runai-backend.yaml` | `helm -n runai-backend get values runai-backend` |
| `configmaps_runai-backend.yaml` | `kubectl -n runai-backend get cm -o yaml` |
| `secrets_runai-backend.yaml` | `kubectl -n runai-backend get secrets -o yaml` |
| `ingress_runai-backend.yaml` / `routes_runai-backend.yaml` | Ingresses (kubectl) or Routes (OpenShift) |
| `idp-settings.json` | IDP settings from the Run:AI API (requires `curl` + `jq`) |
| `clusters.json` | Clusters from the Run:AI API |
| `tenants.json` | Tenants from the Run:AI API |
| `k8s-settings.json` | K8s settings from the Run:AI API |

> API data is fetched from the Run:AI control plane using admin credentials read from the `runai-backend-tenants-manager` config/secret. If `curl`/`jq` are missing or the API call fails, a `*-error.txt` is written instead and the failure is noted in `script.log`.

#### `knative-serving` namespace

| File | Command |
|------|---------|
| `pod-list_knative-serving.txt` | `kubectl -n knative-serving get pods -o wide` |
| `configmaps_knative-serving.yaml` | `kubectl -n knative-serving get cm -o yaml` |
| `secrets_knative-serving.yaml` | `kubectl -n knative-serving get secrets -o yaml` |
| `knativeserving.yaml` | The `KnativeServing` object (`knativeserving_all.yaml` as a fallback) |
| `knative-services.yaml` | `kubectl -n knative-serving get services.serving.knative.dev -o yaml` |
| `knative-revisions.yaml` | `kubectl -n knative-serving get revisions.serving.knative.dev -o yaml` |
| `knative-routes.yaml` | `kubectl -n knative-serving get routes.serving.knative.dev -o yaml` |
| `knative-configurations.yaml` | `kubectl -n knative-serving get configurations.serving.knative.dev -o yaml` |
| `knative-domainmappings.yaml` | `kubectl -n knative-serving get domainmappings.serving.knative.dev -o yaml` |
| `mutatingwebhooks_knative.yaml` | Knative mutating webhook configurations |
| `validatingwebhooks_knative.yaml` | Knative validating webhook configurations |

#### `knative-operator` namespace

| File | Command |
|------|---------|
| `pod-list_<namespace>.txt` | `kubectl -n <namespace> get pods -o wide` |
| `configmaps_<namespace>.yaml` | `kubectl -n <namespace> get cm -o yaml` |
| `secrets_<namespace>.yaml` | `kubectl -n <namespace> get secrets -o yaml` |

#### `runai-reservation` namespace

| File | Command |
|------|---------|
| `pod-list_runai-reservation.txt` | `kubectl -n runai-reservation get pods -o wide` |
| `configmaps_runai-reservation.yaml` | `kubectl -n runai-reservation get cm -o yaml` |
| `secrets_runai-reservation.yaml` | `kubectl -n runai-reservation get secrets -o yaml` |
| `services_runai-reservation.yaml` | `kubectl -n runai-reservation get svc -o yaml` |
| `deployments_runai-reservation.yaml` | `kubectl -n runai-reservation get deployments -o yaml` |
| `statefulsets_runai-reservation.yaml` | `kubectl -n runai-reservation get statefulsets -o yaml` |
| `daemonsets_runai-reservation.yaml` | `kubectl -n runai-reservation get daemonsets -o yaml` |
| `pvcs_runai-reservation.yaml` | `kubectl -n runai-reservation get pvc -o yaml` |

> **Note:** Secrets are collected in full (base64-encoded, as stored in the cluster). Review the archive before sharing if that is a concern.

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

---

## scheduler_snapshot.sh

Collects scheduler snapshots from all Run:AI scheduler deployments in the `runai` namespace. For each deployment, calls the `/get-snapshot` endpoint and saves the response.

### Usage

```bash
chmod +x ./scheduler_snapshot.sh
./scheduler_snapshot.sh
```

Optional: set `RUNAI_NAMESPACE` to use a different namespace (default: `runai`).

### What the snapshot contains

- **config** – Scheduler actions and plugin tiers
- **schedulerParams** – RunAI params (partition, fairness, schedule period, etc.)
- **rawObjects** – Cluster state the scheduler uses: pods, nodes, queues, podGroups, bindRequests, priorityClasses, configMaps, PVCs, storageClasses, csiDrivers, etc.

### Output

One gzip file per scheduler deployment: `<deployment-name>-snapshot.gzip` (e.g. `runai-scheduler-default-snapshot.gzip`).

---

## Contributing

This project is currently not accepting contributions.

## License

This project is licensed under the [Apache License 2.0](LICENSE).

Copyright 2025-2026 NVIDIA CORPORATION & AFFILIATES. See [NOTICE](NOTICE) for third-party attributions.
