# Security Policy: Run:AI Log Collector

## Reporting a Vulnerability

If you discover a potential security vulnerability in Run:AI Log Collector, please **do not open a public issue, merge request, or discussion thread.** Public reports can expose affected users before NVIDIA has validated and remediated the issue.

Report potential vulnerabilities through one of these private channels:

- **NVIDIA Vulnerability Disclosure Program** (preferred): https://www.nvidia.com/en-us/security/
- **Email**: [psirt@nvidia.com](mailto:psirt@nvidia.com)
  - We encourage encrypted email using the [NVIDIA public PGP key](https://www.nvidia.com/en-us/security/pgp-key)
- **GitHub/GitLab Private Vulnerability Reporting**: use this repository's **Security** tab and select **Report a vulnerability** when available

Please include the following information:

- Product/project name: Run:AI Log Collector
- Version, branch, or commit affected
- Affected script or component, such as `cluster.sh`, `workload.sh`, `gpu.sh`, or `scheduler_snapshot.sh`
- Type of vulnerability, such as credential disclosure, command injection, unsafe archive generation, over-collection of sensitive data, or privilege misuse
- Step-by-step reproduction instructions
- Proof-of-concept code or command sequence, if available
- Expected and actual behavior
- Impact assessment, including whether Kubernetes Secrets, tokens, logs, tenant data, scheduler state, workload manifests, or control-plane API data can be exposed

Detailed reports help NVIDIA evaluate and address issues faster. NVIDIA PSIRT will acknowledge receipt, validate severity, coordinate remediation with maintainers, and publish security bulletins or other advisories as appropriate.

## Security Architecture & Context

Run:AI Log Collector is a set of Bash-based diagnostic utilities for Run:AI and Kubernetes environments. The repository contains four primary scripts:

- `cluster.sh` collects cluster-wide diagnostics from Run:AI namespaces, Knative namespaces, scheduler resources, Helm values, Kubernetes metadata, events, logs, and selected Run:AI control-plane API data.
- `workload.sh` collects diagnostics for a specific Run:AI workload by resolving the project namespace, detecting the workload CRD architecture, walking child resources, collecting pod logs, and archiving workload and namespace context.
- `gpu.sh` collects NVIDIA GPU Operator logs, GPU node data, ClusterPolicy and NodeFeature resources, ConfigMaps, Secret metadata, DaemonSets, events, and Helm values.
- `scheduler_snapshot.sh` discovers Run:AI scheduler deployments, starts a local `kubectl port-forward`, calls each scheduler's `/get-snapshot` endpoint with `curl`, and stores compressed scheduler snapshots.

This software operates at the **CLI tool / diagnostic automation** level. Its primary security responsibility is to collect troubleshooting data without unintentionally disclosing credentials, Kubernetes Secret values, personal credentials, tenant information, cluster topology, scheduler state, control-plane configuration, or other sensitive operational data.

**Repository Exposure Classification:** Internal.
Basis: origin remote is `gitlab-master.nvidia.com`, an internal/self-managed GitLab host; full internal detail is permitted.

**Service Exposure Classification:** Internal-Sensitive (medium confidence, inferred/unconfirmed).
Basis: internal diagnostic tooling for Run:AI and Kubernetes environments; handles cluster-admin context, logs, Helm values, Secret metadata, optional Secret values, bearer tokens, tenant/control-plane API data, scheduler snapshots, and GPU Operator configuration; no internet-facing service is implemented by this repository.

Key security boundaries and interfaces:

- **Operator workstation boundary:** Scripts run locally with the operator's shell privileges and inherit access to local tools, environment, kubeconfig, and filesystem permissions.
- **Kubernetes API boundary:** `cluster.sh`, `workload.sh`, `gpu.sh`, and `scheduler_snapshot.sh` issue `kubectl` or `oc` commands against the currently configured cluster. The scripts rely on existing Kubernetes RBAC and kubeconfig authentication.
- **Run:AI control-plane boundary:** `cluster.sh` reads admin credentials from the `runai-backend-tenants-manager` ConfigMap/Secret and exchanges them for a bearer token with `curl` to collect IDP, cluster, tenant, and Kubernetes settings.
- **Archive boundary:** The scripts write diagnostic files locally and package them into `.tar.gz` archives. Those archives are intended for troubleshooting and may contain sensitive operational data even when Secret values are withheld.
- **Sensitive-data opt-in boundary:** `cluster.sh` excludes Kubernetes Secret values by default and redacts credential-looking Helm values. The `--include-sensitive-data` flag changes this behavior and writes full Secret data plus unredacted Helm values into the archive.
- **Scheduler debug boundary:** `scheduler_snapshot.sh` uses `kubectl port-forward` to access scheduler debug snapshots on `localhost:8081`; the snapshot contains scheduler parameters and raw cluster objects used by scheduling decisions.
- **Input boundary:** `workload.sh` validates `--project` and `--workload` before using them in local paths and Kubernetes lookups. `cluster.sh`, `gpu.sh`, and `scheduler_snapshot.sh` primarily derive names from Kubernetes resources and local command output.

### Threat Model

The following scenarios represent the primary security concerns for this repository:

1. **Sensitive Kubernetes Data Disclosure Through Diagnostic Archives:** `cluster.sh`, `workload.sh`, and `gpu.sh` collect pod logs, pod descriptions, ConfigMaps, events, Helm values, workload manifests, PVCs, ingress/route data, scheduler resources, and Secret metadata. If generated archives are shared broadly or stored without controls, they can disclose cluster topology, image names, namespaces, workload names, tenant information, operational errors, configuration values, and references to Secrets. `cluster.sh --include-sensitive-data` further includes full Kubernetes Secret manifests and unredacted Helm values.

2. **Credential Exposure During Run:AI Control-Plane API Collection:** `cluster.sh` reads `ADMIN_USERNAME`, decodes `ADMIN_PASSWORD` from the `runai-backend-tenants-manager` Secret, requests a bearer token from `$RUNAI_CTRL_PLANE/api/v1/token`, and uses that token for IDP, cluster, tenant, and Kubernetes settings requests. A bug, shell tracing, process inspection, terminal capture, or archive/log change around this code path could expose admin credentials or bearer tokens.

3. **Over-Collection of Scheduler and Workload State:** `scheduler_snapshot.sh` saves `/get-snapshot` output from every Run:AI scheduler deployment, and `workload.sh` walks owner references and labels to collect workload children such as Jobs, Services, Ingresses, Routes, HTTPRoutes, Knative resources, PVCs, ConfigMaps, and Secret descriptions. These outputs can reveal scheduling policy, queue structure, priority classes, tenant/workload relationships, network exposure, and operational state beyond what a support case may require.

4. **Command and Path Injection From Cluster-Derived Names:** Several scripts use names returned by Kubernetes or Helm in output filenames and command arguments. `workload.sh` validates user-supplied `--project` and `--workload`, but `cluster.sh`, `gpu.sh`, and `scheduler_snapshot.sh` also process pod names, container names, release names, scheduler deployment names, and namespace names derived from the cluster. Kubernetes naming constraints reduce but do not eliminate risk from unusual resource names, shell word splitting, pathname expansion, or archive path manipulation if future code adds less constrained inputs.

5. **Unsafe Local Archive Handling:** The scripts create local directories and archives, then remove temporary directories. `gpu.sh` asks interactively whether to remove the uncompressed directory, while `cluster.sh` and `workload.sh` clean up collected directories automatically after archiving. If the scripts are run from a shared or untrusted working directory, archive names, generated files, symlinks, or concurrent local filesystem changes could lead to data exposure or unintended file operations.

6. **Privilege Amplification Through Operator Context:** The scripts do not implement their own authorization. They perform whatever `kubectl`, `oc`, `helm`, and `curl` operations are allowed by the operator's current environment. Running these scripts with cluster-admin credentials allows broad collection across Run:AI, Knative, GPU Operator, scheduler, and workload resources; compromise of the script execution environment can therefore expose privileged cluster data.

7. **Unprotected Local Scheduler Snapshot Access During Port-Forward:** `scheduler_snapshot.sh` forwards each scheduler deployment to `localhost:8081` and calls `/get-snapshot`. While intended to be local and short-lived, the forwarded endpoint temporarily exposes scheduler debug data to processes that can reach the local port on the operator workstation.

### Critical Security Assumptions

- **Trusted operator environment:** The scripts assume the operator workstation, shell history configuration, terminal, process table visibility, and current working directory are trusted while collection is running.
- **Kubernetes RBAC enforces authorization:** The scripts assume Kubernetes, OpenShift, and Helm permissions correctly restrict what the current kubeconfig can read. The scripts do not add a separate authorization layer.
- **Collected archives are handled as sensitive artifacts:** Even default-mode archives may contain logs, metadata, object names, URLs, tenant data, scheduler state, and Secret references. Operators are expected to review archives before sharing and store/transmit them through approved channels.
- **Default redaction is not a complete data-loss-prevention mechanism:** `cluster.sh` redacts credential-looking Helm value keys and withholds Secret values by default, but application logs, ConfigMaps, pod descriptions, events, and custom resources may still contain sensitive values if workloads or charts place secrets outside Kubernetes Secret data fields.
- **`--include-sensitive-data` is restricted to approved workflows:** Full Secret data and unredacted Helm values collected by `cluster.sh --include-sensitive-data` are assumed to be used only when necessary, with explicit review before transfer.
- **Cluster resource names are mostly constrained by Kubernetes:** The scripts rely on Kubernetes object naming rules for many cluster-derived filenames and command arguments. Future additions that consume less constrained annotations, labels, or arbitrary file paths must validate or quote those values carefully.
- **External command behavior is trusted:** The scripts assume installed `kubectl`, `oc`, `helm`, `curl`, `jq`, `tar`, `awk`, `sed`, `grep`, `base64`, and shell builtins are authentic and not replaced by malicious binaries in `PATH`.
- **Localhost port-forward access is local and temporary:** `scheduler_snapshot.sh` assumes the forwarded scheduler endpoint on `localhost:8081` is reachable only by trusted local processes during the short collection window.
- **No network service is exposed by this repository:** The repository contains CLI scripts, not a long-running service. Network access occurs through Kubernetes APIs, Helm, Run:AI control-plane API calls, and temporary local port-forwarding.
- **Callers select the correct scope:** The scripts assume operators intentionally choose the cluster, project, workload, namespace, and collection mode appropriate for the support case, and avoid collecting unrelated tenant or workload data where possible.

## Dependency Security

Run:AI Log Collector does not use a package manager manifest or vendored third-party libraries. Its runtime dependencies are external command-line tools and platform APIs:

- Bash
- `kubectl` or `oc`
- `helm`
- `curl`
- `jq` for selected JSON parsing in `cluster.sh` and `gpu.sh`
- Standard Unix utilities such as `tar`, `awk`, `sed`, `grep`, `base64`, `du`, `ls`, and `date`

Operators should install these dependencies from approved sources and keep them patched. The scripts inherit the behavior, authentication context, and security posture of those tools.

## Deployment and Operational Guidance

- Run the scripts from a trusted local directory with restrictive filesystem permissions.
- Use the least-privileged kubeconfig that can collect the data required for the support case.
- Prefer default collection mode in `cluster.sh`; use `--include-sensitive-data` only when specifically required.
- Treat all generated `.tar.gz`, `.gzip`, `.yaml`, `.json`, `.txt`, and log files as sensitive support artifacts.
- Review archives before sending them outside the immediate debugging workflow.
- Avoid enabling shell tracing (`set -x`) or terminal recording while collecting control-plane API data.
- Remove local archives when no longer needed according to the applicable data-retention policy.
- Do not run these scripts from untrusted automation or shared workstations where other users can observe local files, process arguments, terminal output, or forwarded ports.
