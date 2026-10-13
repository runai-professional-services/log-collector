# Run:AI Log Collector

A collection of diagnostic utilities for Run:AI environments. These scripts automate the collection of logs, configurations, and resource manifests from Kubernetes clusters to aid in debugging and troubleshooting.

## Version

Current version: **1.2.0** (see [CHANGELOG.md](CHANGELOG.md) for release history)

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
  - [Detection](#detection)
  - [Output](#output-1)
- [gpu.sh](#gpush)
  - [Prerequisites](#prerequisites-3)
  - [Usage](#usage-2)
  - [Namespace detection](#namespace-detection)
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

By default, Kubernetes Secret *values* are withheld (metadata only) and Helm
values are collected with credential values redacted to `"<REDACTED>"`
(`password`, `clientSecret`, `apiToken`, and similar). Configuration used for
upgrades and debugging — images, resources, feature flags, URLs, Secret
*references* (`existingSecret`, `extraEnvVarsSecret`, `imagePullSecrets`), and
Secret key *names* (`passwordKey`, `adminPasswordKey`) — is kept.

To include full Secret data and leave Helm values unredacted:

```bash
./cluster.sh --include-sensitive-data
```

Review an archive created with this option carefully before sharing it.

### Output

Creates a **single** combined archive containing one folder per collected namespace:

```
<control-plane>-runai-log-collector-output-<DD-MM-YYYY_HH-MM>.tar.gz
```

`<control-plane>` is derived from the control-plane URL (e.g. `itay-sloth-gpu-runailabs-cs-com`). Producing one archive means there is always exactly one file to attach, regardless of how many namespaces exist.

Collection happens inside a directory of the same name, created next to the archive and removed once the archive is written. Nothing else in the working directory is read, written, or deleted.

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
| `helm-values_runai-cluster.yaml` | `helm -n runai get values runai-cluster` (credential keys redacted by default) |
| `cm_runai-public.yaml` | `kubectl -n runai get cm runai-public -o yaml` |
| `configmaps_runai.yaml` | `kubectl -n runai get cm -o yaml` |
| `secret-metadata_runai.txt` | Secret names, types, and creation times; values withheld |
| `secrets_runai.yaml` | Full Secret manifests; present only with `--include-sensitive-data` |
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
| `helm-values_runai-backend.yaml` | `helm -n runai-backend get values runai-backend` (credential keys redacted by default) |
| `configmaps_runai-backend.yaml` | `kubectl -n runai-backend get cm -o yaml` |
| `secret-metadata_runai-backend.txt` | Secret names, types, and creation times; values withheld |
| `secrets_runai-backend.yaml` | Full Secret manifests; present only with `--include-sensitive-data` |
| `ingress_runai-backend.yaml` / `routes_runai-backend.yaml` | Ingresses (kubectl) or Routes (OpenShift) |
| `idp-settings.json` | IDP settings from the Run:AI API (requires `curl` + `jq`) |
| `clusters.json` | Clusters from the Run:AI API |
| `tenants.json` | Tenants from the Run:AI API |
| `k8s-settings.json` | K8s settings from the Run:AI API |

> API data is fetched from the Run:AI control plane using the admin username and
> `AUTH_SERVICE_URL` from the `runai-backend-tenants-manager` ConfigMap, plus the admin
> password from the `runai-backend-credentials` Secret (falling back to
> `runai-backend-tenants-manager` on older backends). If `curl`/`jq` are missing or the
> API call fails, a `*-error.txt` is written instead and the failure is noted in
> `script.log`, which names the specific lookup that came up empty.

#### `knative-serving` namespace

| File | Command |
|------|---------|
| `pod-list_knative-serving.txt` | `kubectl -n knative-serving get pods -o wide` |
| `configmaps_knative-serving.yaml` | `kubectl -n knative-serving get cm -o yaml` |
| `secret-metadata_knative-serving.txt` | Secret names, types, and creation times; values withheld |
| `secrets_knative-serving.yaml` | Full Secret manifests; present only with `--include-sensitive-data` |
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
| `secret-metadata_<namespace>.txt` | Secret names, types, and creation times; values withheld |
| `secrets_<namespace>.yaml` | Full Secret manifests; present only with `--include-sensitive-data` |

#### `runai-reservation` namespace

| File | Command |
|------|---------|
| `pod-list_runai-reservation.txt` | `kubectl -n runai-reservation get pods -o wide` |
| `configmaps_runai-reservation.yaml` | `kubectl -n runai-reservation get cm -o yaml` |
| `secret-metadata_runai-reservation.txt` | Secret names, types, and creation times; values withheld |
| `secrets_runai-reservation.yaml` | Full Secret manifests; present only with `--include-sensitive-data` |
| `services_runai-reservation.yaml` | `kubectl -n runai-reservation get svc -o yaml` |
| `deployments_runai-reservation.yaml` | `kubectl -n runai-reservation get deployments -o yaml` |
| `statefulsets_runai-reservation.yaml` | `kubectl -n runai-reservation get statefulsets -o yaml` |
| `daemonsets_runai-reservation.yaml` | `kubectl -n runai-reservation get daemonsets -o yaml` |
| `pvcs_runai-reservation.yaml` | `kubectl -n runai-reservation get pvc -o yaml` |

> **Security note:** Full Kubernetes Secret data is excluded by default (metadata
> only). Helm values are always collected; credential values (`password`,
> `clientSecret`, …) are replaced with `"<REDACTED>"`, while Secret references and
> key-name fields are kept. Use `--include-sensitive-data` for unredacted output.

---

## workload.sh

Collects and archives Run:AI workload diagnostics into a single timestamped archive.

The workload type and the CR architecture are detected from the cluster, so only the project and the workload name are needed. This matters from Run:AI 2.26 on, where the native per-type CRDs (`InteractiveWorkload`, `TrainingWorkload`, …) can be replaced by a single generic `WorkloadRunner` reconciled by the any-workload controller. The two shapes coexist on the same cluster — conversion is opt-in per workload type — and a converted Workspace and a converted Training workload have identical kinds at every level, so the type can no longer be inferred from the CR kind.

### Prerequisites

- `kubectl` installed and configured — or `oc` on OpenShift
- Access to Kubernetes cluster with Run:AI workloads

### Usage

```bash
chmod +x ./workload.sh
./workload.sh --project <PROJECT> --workload <WORKLOAD>
```

**Parameters:**

| Parameter | Description |
|-----------|-------------|
| `--project` | Run:AI project name (required) |
| `--workload` | Workload name (required) |

**Example:**

```bash
./workload.sh --project ml-team --workload bert-training
```

### Detection

The script resolves the project's namespace from `projects.run.ai` (falling back to the `runai/queue` label), then probes for the workload in this order:

1. **`workloadrunners.run.ai`** — the 2.26+ architecture. Probed first because the native CRDs remain registered on 2.26 and still receive workloads whose type is not enabled for any-workload submission, so a single cluster can hold both shapes at once. The logical type is read from the embedded template's `workloadKind` label; the `WorkloadRunner`'s own labels only describe the wrapped GVK.
2. **The native workload CRDs** — `interactiveworkloads`, `trainingworkloads`, `distributedworkloads`, `inferenceworkloads`, `distributedinferenceworkloads`. Probed one at a time, because kubectl aborts an entire multi-kind `get` when a single type is unknown to the server.
3. **`externalworkloads.run.ai`** — a third-party resource (Deployment, StatefulSet, …) scheduled by Run:AI, matched on `spec.originalWorkloadName`.

Nothing in the detection path touches pods, so stopped and suspended workloads resolve correctly.

Child resources are then collected by walking owner references outward from the workload's UID. The tree is traversed by UID membership rather than down a single spine: on 2.26 the PVCs and personal-credential secrets hang off the `WorkloadRunner` while the networking resources hang off the `Job` one level below. Non-controller owner references are followed deliberately — 2.26 networking uses plain owner references, so filtering on `controller: true` would drop all of it.

### Output

Creates `<PROJECT>_<TYPE>_<WORKLOAD>_v<VERSION>_<TIMESTAMP>.tar.gz` containing a single folder:

```
<project>_<type>_<workload>_v<version>_<timestamp>/
├── detection.txt
├── workload/
├── pods/
└── namespace/
```

#### `detection.txt`

The detection result and the resource tree that drove collection: architecture, workload type, top-level CR, the template GVK a `WorkloadRunner` runs, whether the workload was converted from a native type, `workloadId`, root UID, and the owner-reference tree with non-controller references marked. For example:

```
architecture    : workloadrunner (WorkloadRunner / any-workload controller (2.26+))
workload type   : Workspace
top-level CR    : workloadrunners.run.ai/workspace-test
runs template   : batch/v1 Job
converted       : true

resource tree (by owner reference)
---------------------------------
  WorkloadRunner/workspace-test
    Job/workspace-test
      Pod/workspace-test-ldgs5
      Service/job-workspace-test-url   [owner ref, not controller]
      Ingress/job-workspace-test-url   [owner ref, not controller]
```

#### `workload/`

The top-level CR plus every resource discovered in its tree, one file per object named `<kind>_<name>.yaml`. Depending on the era and type this includes the `RunaiJob` or `batch/v1 Job`, kubeflow jobs, Knative Services/Configurations/Revisions, LeaderWorkerSets, NIMServices, Services, Ingresses, Routes, HTTPRoutes, ConfigMaps, PVCs and ComputeDomains. PodGroups are also collected by `workloadName` label, since the scheduler does not own them through the workload tree in every era.

Secrets found in the tree are captured as `secret_<name>_describe.txt` — `describe` lists the keys and their sizes without exporting the values, which keeps personal-credential tokens out of the archive.

#### `pods/`

Per pod, discovered from the resource tree unioned with a `run.ai/workload-id` label lookup:

- `<pod>.yaml` — manifest
- `<pod>_describe.txt` — describe output
- `<pod>_<container>.log` — logs for every container, including init containers
- `<pod>_<container>_previous.log` — pre-restart logs, only when the container has restarted
- `<pod>_<container>_nvidia-smi.txt` — only when the command succeeds in that container

#### `namespace/`

Surrounding context: `pod-list.txt`, `events.txt`, `configmaps.yaml`, `pvcs.yaml`, `services.yaml`, `ingresses.yaml`, and `routes.yaml` on OpenShift. Empty collections are skipped rather than written as an empty list.

**Features:**

- Resilient collection (continues on individual failures)
- No `jq` or `python` dependency
- Works unchanged across pre-2.26 and 2.26+ clusters, and on OpenShift via `oc`

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
./gpu.sh                          # namespace detected from the cluster
./gpu.sh -n nvidia-gpu-operator   # or name it explicitly
```

| Option | Description |
|--------|-------------|
| `-n`, `--namespace <name>` | Namespace the GPU Operator is installed in. Detected from the cluster when omitted. Also settable via `GPU_OPERATOR_NAMESPACE`. |
| `-h`, `--help` | Show help and exit. |

### Namespace detection

The install namespace is not fixed — the Helm chart defaults to `gpu-operator`, the OpenShift/OLM bundle uses `nvidia-gpu-operator`, and either can be overridden at install time. The namespace is resolved before collection starts, in this order:

1. `-n/--namespace` or `GPU_OPERATOR_NAMESPACE`, if given. The namespace must exist or the script exits.
2. Pods and Deployments labelled `app.kubernetes.io/component=gpu-operator`, then `app=gpu-operator`, across all namespaces. Deployments are matched alongside pods so an operator scaled to zero or failing to schedule is still found.
3. A Deployment named `gpu-operator` in any namespace.
4. The namespace names the installers use — `gpu-operator`, `nvidia-gpu-operator`, `gpu-operator-resources` — probed one by one. This is the path taken when the credentials cannot list across all namespaces.

If the operator is found in more than one namespace, the first is used and a warning names the others so the run can be repeated with `-n`. The resolved namespace is recorded in `collection-summary.txt`.

### Output

Creates `gpu-operator-logs-<timestamp>.tar.gz` containing:

- Cluster and node information
- GPU Operator pod logs (current + previous)
- Pod descriptions
- ConfigMaps, DaemonSets, Secrets
- Helm values
- ClusterPolicies, NVIDIADrivers and NodeFeatures
- GPU-related events

Custom resources are requested by fully qualified name (`clusterpolicies.nvidia.com`), because `kubectl` resolves a bare plural to whichever API group sorts first — on a cluster running Kyverno, `clusterpolicies` returns Kyverno's objects instead of NVIDIA's. A CRD that is not installed is recorded as such, so an empty file is never mistaken for the operator having reported nothing.

---

## scheduler_snapshot.sh

Collects scheduler snapshots from all Run:AI scheduler deployments in the `runai` namespace. For each deployment, calls the `/get-snapshot` endpoint and saves the response.

### Prerequisites

- `kubectl`, configured for the intended cluster, with permission to list Deployments and port-forward to scheduler Pods
- `curl`, `unzip`, `gzip`, and `jq`
- A trusted local directory for sensitive scheduler diagnostics

### Usage

```bash
chmod +x ./scheduler_snapshot.sh
./scheduler_snapshot.sh
```

Optional: set `RUNAI_NAMESPACE` to use a different namespace (default: `runai`).

Port-forward startup is limited to 30 seconds, and each snapshot request to 120 seconds.
Set `RUNAI_PORT_FORWARD_TIMEOUT_SECONDS` or `RUNAI_SNAPSHOT_TIMEOUT_SECONDS` to change these limits (positive integers, up to 99999 seconds).
The script chooses an available local port, binds only to `127.0.0.1`, and bypasses HTTP proxies and curl configuration for that local request.

Exit status is zero only when every discovered scheduler returns a validated snapshot.
Discovery errors, no matching schedulers, failed port-forwards, and missing or invalid captures exit nonzero.
Collection continues after an individual scheduler fails, retaining valid captures from other schedulers.

### What the snapshot contains

- **config** – Scheduler actions and plugin tiers
- **schedulerParams** – RunAI params (partition, fairness, schedule period, etc.)
- **rawObjects** – Cluster state the scheduler uses: pods, nodes, queues, podGroups, bindRequests, priorityClasses, configMaps, PVCs, storageClasses, csiDrivers, etc.

### Output

Each run creates a private directory named `scheduler-snapshots-<UTC-timestamp>-<random-suffix>` in the current directory.
It contains one validated archive per successful scheduler deployment, named `<deployment-name>-snapshot.gzip`, plus a port-forward log for each attempted deployment.
Repeated or concurrent runs use separate directories and do not overwrite earlier captures. Partial downloads are removed, and the final count includes only validated archives.

The `.gzip` filename is retained for compatibility; it does not identify the encoding.
[KAI's snapshot endpoint](https://github.com/kai-scheduler/KAI-Scheduler/blob/main/pkg/scheduler/plugins/snapshot/snapshot.go) returns a ZIP archive containing `snapshot.json`.
The collector accepts that format and gzip-compressed JSON, checking archive integrity, exactly one `snapshot.json` ZIP entry, and exactly one JSON object with object-valued `config`, `schedulerParams`, and `rawObjects` fields.
HTTP errors, redirects, corrupt archives, and malformed or incomplete JSON are rejected.

These checks validate the downloaded artifact, not allocation correctness, freshness, or complete scheduler state.
Port-forwarding to a Deployment can select a non-leader Pod when it has multiple replicas.
Confirm the leader and commercial-version format with the support owner before using a capture as authoritative scheduling evidence; see [KAI's multiple-replica guidance](https://github.com/kai-scheduler/KAI-Scheduler/blob/main/docs/plugins/snapshot.md#capturing-a-snapshot-with-multiple-replicas).
Treat snapshots and logs as sensitive diagnostics and review them before sharing.

### Local validation

The regression suite uses a mock `kubectl` and local HTTP fixtures; it never contacts a Kubernetes cluster or an external scheduler.
Python 3.7 or newer is required for these tests only.

```bash
bash -n scheduler_snapshot.sh
shellcheck scheduler_snapshot.sh
python3 -m unittest discover -s tests -p 'test_scheduler_snapshot.py' -v
```

---

## Contributing

This project is currently not accepting contributions.

## License

This project is licensed under the [Apache License 2.0](LICENSE).

Copyright 2025-2026 NVIDIA CORPORATION & AFFILIATES. See [NOTICE](NOTICE) for third-party attributions.
