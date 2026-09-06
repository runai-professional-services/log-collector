#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Cluster Log Collection Script
VERSION="1.2.1"

# Global variable to store the kubectl command (kubectl or oc)
KUBECTL_CMD=""
INCLUDE_SENSITIVE_DATA=false

# Per-namespace failure log. When set, warnings/errors and the stderr of any
# failed collection command are appended here. It is intentionally empty
# outside of namespace processing so global helpers don't write to a stale file.
SCRIPT_LOG=""
SCRIPT_LOG_FAILURES=0

# ----------------------------------------------------------------------------
# Output styling helpers
# ----------------------------------------------------------------------------
# Colors are enabled only when stdout is an interactive terminal and NO_COLOR
# is not set. They only affect the terminal; script.log is written as plain
# text by the logging helpers below, so log files stay clean and readable.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_MAGENTA=$'\033[0;35m'
  C_CYAN=$'\033[0;36m'
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
fi

RULE="════════════════════════════════════════════════════════════"

banner() {
  echo "${C_BOLD}${C_GREEN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  printf "║  %-56s║\n" "Run:AI Cluster Log Collector"
  printf "║  %-56s║\n" "v$VERSION"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo "${C_RESET}"
}

# Major section header
section() {
  echo ""
  echo "${C_BOLD}${C_BLUE}${RULE}${C_RESET}"
  echo "${C_BOLD}${C_BLUE}  $*${C_RESET}"
  echo "${C_BOLD}${C_BLUE}${RULE}${C_RESET}"
}

# Namespace-scoped header
ns_header() {
  echo ""
  echo "${C_BOLD}${C_MAGENTA}${RULE}${C_RESET}"
  echo "${C_BOLD}${C_MAGENTA}  ▶ Namespace: $*${C_RESET}"
  echo "${C_BOLD}${C_MAGENTA}${RULE}${C_RESET}"
}

# Sub-section / grouping header
group() { echo "${C_BOLD}${C_CYAN}▶ $*${C_RESET}"; }

# A task being started
task()   { echo "${C_CYAN}→${C_RESET} $*"; }
# Dim detail line for deeply-nested output
detail() { echo "    ${C_DIM}$*${C_RESET}"; }
# Success / info lines (terminal only)
ok()     { echo "  ${C_GREEN}✓${C_RESET} $*"; }
info()   { echo "  ${C_BLUE}ℹ${C_RESET} $*"; }
skip()   { echo "  ${C_YELLOW}⏭${C_RESET} $*"; }

# Append a plain-text entry to the active failure log (if any) and count it.
log_failure() {
  [ -n "$SCRIPT_LOG" ] || return 0
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$1" >> "$SCRIPT_LOG"
  SCRIPT_LOG_FAILURES=$((SCRIPT_LOG_FAILURES + 1))
}

# Warnings and errors print to the terminal AND get recorded in the failure log.
warn() { echo "  ${C_YELLOW}⚠${C_RESET} $*"; log_failure "WARN:  $*"; }
err()  { echo "  ${C_RED}✗${C_RESET} $*"; log_failure "ERROR: $*"; }

# Run a collection command, capturing stderr. On success prints a check mark and
# writes nothing to the log. On failure prints an error and records the command
# and its stderr in the failure log so it can be diagnosed later.
# Usage: run_cmd "<label>" "<output_file>" <command> [args...]
run_cmd() {
  local label=$1 outfile=$2
  shift 2
  local errfile rc
  errfile=$(mktemp)
  "$@" > "$outfile" 2>"$errfile"
  rc=$?
  if [ $rc -eq 0 ]; then
    ok "Collected $label"
    # Preserve informational messages like "No resources found in <ns>." which
    # kubectl/oc print to stderr, so an empty result isn't a confusing 0-byte file.
    if [ ! -s "$outfile" ] && [ -s "$errfile" ]; then
      cat "$errfile" > "$outfile"
    fi
  else
    err "Failed to collect $label (exit $rc)"
    if [ -n "$SCRIPT_LOG" ]; then
      {
        echo "    command : $*"
        if [ -s "$errfile" ]; then
          sed 's/^/    stderr  : /' "$errfile"
        else
          echo "    stderr  : (no error output)"
        fi
      } >> "$SCRIPT_LOG"
    fi
  fi
  rm -f "$errfile"
  return $rc
}

# Function to check if a command exists
check_command() {
  local cmd=$1
  if ! command -v "$cmd" &> /dev/null; then
    err "'$cmd' command not found. Please install $cmd and try again."
    exit 1
  fi
}

# Function to detect if this is an OpenShift cluster
detect_openshift() {
  task "Detecting cluster type..."

  local is_openshift=false

  # Whether the cluster is OpenShift is answered by the API groups the server
  # serves, not by which binary is installed locally. Note that api-resources
  # exits 0 and prints a header for a group that does not exist, so the output
  # is the signal, not the exit code.
  if command -v "oc" &> /dev/null; then
    # Check if any OpenShift-specific resources actually exist
    local oc_resources=$(oc api-resources --api-group=config.openshift.io 2>/dev/null | tail -n +2)
    if [[ -n "$oc_resources" ]]; then
      is_openshift=true
    elif oc api-versions 2>/dev/null | grep -q "config.openshift.io\|operator.openshift.io\|route.openshift.io"; then
      is_openshift=true
    fi
  fi

  # Also check with kubectl if oc didn't find OpenShift
  if [[ "$is_openshift" == "false" ]] && command -v "kubectl" &> /dev/null; then
    if kubectl api-versions 2>/dev/null | grep -q "config.openshift.io\|operator.openshift.io\|route.openshift.io"; then
      is_openshift=true
    fi
  fi

  # Now decide which CLI to use based on cluster type and available commands
  if [[ "$is_openshift" == "true" ]]; then
    if command -v "oc" &> /dev/null; then
      ok "OpenShift cluster detected"
      KUBECTL_CMD="oc"
      return 0
    elif command -v "kubectl" &> /dev/null; then
      ok "OpenShift cluster detected (using kubectl)"
      KUBECTL_CMD="kubectl"
      return 0
    fi
  else
    if command -v "kubectl" &> /dev/null; then
      ok "Standard Kubernetes cluster detected"
      KUBECTL_CMD="kubectl"
      return 0
    elif command -v "oc" &> /dev/null; then
      ok "Standard Kubernetes cluster detected (using oc)"
      KUBECTL_CMD="oc"
      return 0
    fi
  fi

  err "Neither 'kubectl' nor 'oc' command found. Please install one of them and try again."
  exit 1
}

# Function to execute kubectl/oc commands
k8s_cmd() {
  $KUBECTL_CMD "$@"
}

# Secret values can contain credentials. Keep them out of the shareable archive
# unless the operator explicitly opts in.
collect_secrets() {
  local namespace=$1 log_dir=$2 suffix=$3
  if [ "$INCLUDE_SENSITIVE_DATA" = true ]; then
    run_cmd "all Secrets (including values)" "$log_dir/secrets_${suffix}.yaml" \
      k8s_cmd -n "$namespace" get secrets -o yaml
  else
    run_cmd "Secret metadata (values withheld)" "$log_dir/secret-metadata_${suffix}.txt" \
      k8s_cmd -n "$namespace" get secrets \
      -o 'custom-columns=NAME:.metadata.name,TYPE:.type,CREATED:.metadata.creationTimestamp'
  fi
}

# True when a Helm values key name looks like it holds a credential value.
# References to Secret objects (existingSecret, extraEnvVarsSecret, …) and
# names of keys inside Secrets (passwordKey, adminPasswordKey, …) are kept —
# those are configuration, not credentials.
helm_key_is_sensitive() {
  local key
  key=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]"'"'"'')

  # Object / key-name references — never redact these.
  case "$key" in
    *secretname*|*existingsecret*|*secretreference*|*secretref*|*createsecret*|*useexistingsecret*|*pullsecret*|*secretkeys*|*envvarssecret*|*tlssecret*|*secretfile*|*secrettype*)
      return 1
      ;;
    *passwordkey*|*passwdkey*|*passwordref*|*passwordsecret*|*passwordname*|*passwordpath*)
      return 1
      ;;
    *tokenurl*|*tokenuri*|*tokenendpoint*|*tokenizer*|*tokenpath*|*tokenname*|*tokenkey*)
      return 1
      ;;
  esac

  # Credential-bearing keys.
  case "$key" in
    password|passwd|secret|credentials|credential)
      return 0
      ;;
    *password|*passwd)
      # e.g. adminPassword, smtpPassword, registryPassword — but not *passwordKey (excluded above)
      return 0
      ;;
    clientsecret|client_secret|client-secret|*clientsecret)
      return 0
      ;;
    *accesstoken|*refreshtoken|*idtoken|*bearertoken|authtoken|apitoken|token)
      return 0
      ;;
    *apikey|*api-key|*api_key|*accesskey|*access-key|*access_key|*secretkey|*secret-key|*secret_key|*privatekey|*private-key|*private_key|*authkey|*auth-key|*auth_key)
      return 0
      ;;
    *connectionstring|*connection-string|*connection_string)
      return 0
      ;;
    sharedsecret|appsecret|*secretvalue*|*secretdata*)
      return 0
      ;;
  esac
  return 1
}

# Replace credential-looking scalar values (and their |/> blocks) with
# <REDACTED>, leaving the rest of the Helm values tree intact for debugging.
redact_helm_values_yaml() {
  local infile=$1 outfile=$2
  local line indent key rest lower_indent block_indent in_block=0

  : > "$outfile"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_block" -eq 1 ]; then
      lower_indent=${line%%[![:space:]]*}
      if [ -n "${line#"${line%%[![:space:]]*}"}" ] && [ ${#lower_indent} -gt "$block_indent" ]; then
        continue
      fi
      in_block=0
    fi

    case "$line" in
      \#*|---*)
        printf '%s\n' "$line" >> "$outfile"
        continue
        ;;
    esac

    if [[ "$line" =~ ^([[:space:]]*)([A-Za-z0-9_.-]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
      indent="${BASH_REMATCH[1]}"
      key="${BASH_REMATCH[2]}"
      rest="${BASH_REMATCH[3]}"

      if helm_key_is_sensitive "$key"; then
        case "$rest" in
          '|'|'|-'|'|+'|'>'|'>-'|'>+')
            printf '%s%s: |\n%s  <REDACTED>\n' "$indent" "$key" "$indent" >> "$outfile"
            in_block=1
            block_indent=${#indent}
            continue
            ;;
          ''|'[]'|'{}'|'null'|'~'|'true'|'false'|'True'|'False'|'Null')
            printf '%s\n' "$line" >> "$outfile"
            continue
            ;;
        esac
        # Quoted/unquoted scalars that are not empty/bool/null/number get redacted.
        if [[ "$rest" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
          printf '%s\n' "$line" >> "$outfile"
          continue
        fi
        printf '%s%s: "<REDACTED>"\n' "$indent" "$key" >> "$outfile"
        continue
      fi
    fi

    printf '%s\n' "$line" >> "$outfile"
  done < "$infile"

  return 0
}

collect_helm_values() {
  local namespace=$1 release=$2 outfile=$3
  local raw tmp

  raw=$(mktemp)
  tmp=$(mktemp)
  if ! helm -n "$namespace" get values "$release" > "$raw" 2>"$tmp"; then
    err "Failed to collect Helm values for $release"
    if [ -n "$SCRIPT_LOG" ]; then
      {
        echo "    command : helm -n $namespace get values $release"
        if [ -s "$tmp" ]; then
          sed 's/^/    stderr  : /' "$tmp"
        else
          echo "    stderr  : (no error output)"
        fi
      } >> "$SCRIPT_LOG"
    fi
    rm -f "$raw" "$tmp"
    return 1
  fi

  if [ "$INCLUDE_SENSITIVE_DATA" = true ]; then
    mv "$raw" "$outfile"
    ok "Collected Helm values for $release (unredacted)"
  else
    redact_helm_values_yaml "$raw" "$outfile"
    ok "Collected Helm values for $release (sensitive keys redacted)"
    rm -f "$raw"
  fi
  rm -f "$tmp"
  return 0
}

usage() {
  cat <<EOF
Run:AI Cluster Log Collector v${VERSION}

Usage: $0 [--include-sensitive-data]

Options:
  --include-sensitive-data  Include full Kubernetes Secret data, and leave Helm
                            values unredacted. These may contain credentials.
                            Review the archive carefully before sharing.
  --help                    Show this help and exit.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --include-sensitive-data)
      INCLUDE_SENSITIVE_DATA=true
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

# Function to collect logs for a given namespace and output directory
collect_logs() {
  local NAMESPACE=$1
  local LOG_DIR=$2
  local LOGS_SUBDIR="$LOG_DIR/logs"
  mkdir -p "$LOGS_SUBDIR"
  
  task "Collecting pod information for namespace: $NAMESPACE"
  PODS=$(k8s_cmd get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}')
  
  if [ -z "$PODS" ]; then
    warn "No pods found in namespace: $NAMESPACE"
    LAST_POD_COUNT=0
    return
  fi
  
  LAST_POD_COUNT=$(echo $PODS | wc -w | tr -d ' ')
  ok "Found $LAST_POD_COUNT pods in namespace: $NAMESPACE"
  
  for POD in $PODS; do
    group "Pod: $POD"
    
    # Collect pod description
    DESCRIBE_FILE="$LOGS_SUBDIR/${POD}_describe.txt"
    run_cmd "pod description for $POD" "$DESCRIBE_FILE" k8s_cmd describe pod $POD -n $NAMESPACE
    
    # Get regular containers
    CONTAINERS=$(k8s_cmd get pod $POD -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}')
    detail "Regular containers found: $(echo $CONTAINERS | wc -w | tr -d ' ')"
    
    # Get init containers
    INIT_CONTAINERS=$(k8s_cmd get pod $POD -n $NAMESPACE -o jsonpath='{.spec.initContainers[*].name}')
    detail "Init containers found: $(echo $INIT_CONTAINERS | wc -w | tr -d ' ')"
    
    # Collect logs for regular containers
    for CONTAINER in $CONTAINERS; do
      LOG_FILE="$LOGS_SUBDIR/${POD}_${CONTAINER}.log"
      run_cmd "logs for container $CONTAINER (pod $POD)" "$LOG_FILE" k8s_cmd logs --timestamps $POD -c $CONTAINER -n $NAMESPACE
      collect_previous_log "$NAMESPACE" "$POD" "$CONTAINER" "$LOGS_SUBDIR/${POD}_${CONTAINER}_previous.log"
    done
    
    # Collect logs for init containers
    for CONTAINER in $INIT_CONTAINERS; do
      LOG_FILE="$LOGS_SUBDIR/${POD}_${CONTAINER}_init.log"
      run_cmd "init container logs for $CONTAINER (pod $POD)" "$LOG_FILE" k8s_cmd logs --timestamps $POD -c $CONTAINER -n $NAMESPACE
      collect_previous_log "$NAMESPACE" "$POD" "$CONTAINER" "$LOGS_SUBDIR/${POD}_${CONTAINER}_init_previous.log"
    done
  done
}

# Collect the previous container instance's logs (kubectl logs --previous).
# These only exist when a container has restarted, and are the key to diagnosing
# crash loops. Absence is normal, so we save the file only when it has content
# and never treat a missing previous log as a failure.
collect_previous_log() {
  local namespace=$1 pod=$2 container=$3 outfile=$4
  if k8s_cmd logs --timestamps --previous "$pod" -c "$container" -n "$namespace" > "$outfile" 2>/dev/null && [ -s "$outfile" ]; then
    ok "Previous (pre-restart) logs saved for container $container (pod $pod)"
  else
    rm -f "$outfile"
  fi
}

# Function to dump scheduler resources
dump_scheduler_resource() {
  local resource_type=$1
  local resource_singular=$2
  local output_dir=$3
  
  if ! run_cmd "${resource_type} list" "${output_dir}/${resource_type}_list.txt" k8s_cmd get ${resource_type}; then
    return
  fi
  
  # Extract individual manifests
  detail "Extracting individual ${resource_type} manifests..."
  k8s_cmd get ${resource_type} --no-headers -o custom-columns=":metadata.name" 2>/dev/null | while read resource; do
    if [ -n "$resource" ]; then
      k8s_cmd get ${resource_type} "$resource" -o yaml > "${output_dir}/${resource_singular}_${resource}.yaml" 2>/dev/null
      detail "- Extracted ${resource_singular}: $resource"
    fi
  done
}

# Function to collect scheduler information
collect_scheduler_info() {
  local LOG_DIR=$1
  local SCHEDULER_DIR="$LOG_DIR/scheduler"
  mkdir -p "$SCHEDULER_DIR"
  
  group "Collecting Scheduler Resources"
  dump_scheduler_resource "projects.run.ai" "project" "$SCHEDULER_DIR"
  dump_scheduler_resource "queues.scheduling.run.ai" "queue" "$SCHEDULER_DIR"
  dump_scheduler_resource "nodepools.run.ai" "nodepool" "$SCHEDULER_DIR"
  dump_scheduler_resource "departments.scheduling.run.ai" "department" "$SCHEDULER_DIR"
  dump_scheduler_resource "accessrules.run.ai" "accessrule" "$SCHEDULER_DIR"
  ok "Scheduler resources collection completed"
}

banner

if [ "$INCLUDE_SENSITIVE_DATA" = true ]; then
  warn "Sensitive-data collection enabled: full Secret data and unredacted Helm values will be archived."
  warn "Review the archive carefully before sharing it."
else
  info "Safe collection mode: Secret values withheld; Helm values kept with sensitive keys redacted."
fi

# Detect cluster type and set appropriate command
detect_openshift

# Check for required tools
section "Checking Prerequisites"
ok "Kubernetes CLI: $KUBECTL_CMD"
check_command "helm"
ok "All required tools are available"

# Namespaces to check
NAMESPACES=("runai-backend" "runai" "knative-serving" "knative-operator" "runai-reservation")

# Some installs name the Knative operator namespace 'knativeoperator' (no hyphen).
# If the canonical name is absent, fall back to whatever knative*operator
# namespace actually exists so it isn't silently skipped.
if ! k8s_cmd get namespace knative-operator >/dev/null 2>&1; then
  ALT_KNATIVE_OP=$(k8s_cmd get ns -o name 2>/dev/null | sed 's|namespace/||' | grep -iE '^knative-?operator$' | head -n1)
  if [ -n "$ALT_KNATIVE_OP" ] && [ "$ALT_KNATIVE_OP" != "knative-operator" ]; then
    info "knative-operator namespace not found; using detected namespace '$ALT_KNATIVE_OP'"
    NAMESPACES=("${NAMESPACES[@]/knative-operator/$ALT_KNATIVE_OP}")
  fi
fi

section "Extracting Cluster Information"
CLUSTER_URL=$(k8s_cmd -n runai get runaiconfig runai -o jsonpath='{.spec.__internal.global.clusterURL}' 2>/dev/null)
CP_URL=$(k8s_cmd -n runai get runaiconfig runai -o jsonpath='{.spec.__internal.global.controlPlane.url}' 2>/dev/null)

if [ -z "$CLUSTER_URL" ]; then
  warn "Could not extract Cluster URL"
  CLUSTER_URL="unknown"
fi

if [ -z "$CP_URL" ]; then
  warn "Could not extract Control Plane URL"
  CP_URL="unknown"
fi

CP_NAME_CLEAN=$(echo "$CP_URL" | sed 's/https:\/\///; s/\./-/g')

info "Cluster URL:                 $CLUSTER_URL"
info "Control Plane URL:           $CP_URL"
info "Control Plane Name (cleaned): $CP_NAME_CLEAN"

TIMESTAMP=$(date +%d-%m-%Y_%H-%M)

# Everything is collected into one directory that this run creates, and only
# that directory is archived and removed at the end. Namespace folders must not
# be written straight into the working directory: a path already named after a
# namespace (a 'runai' CLI binary, say) takes the place of the collection, and
# the cleanup at the end would delete it.
RUN_NAME="$CP_NAME_CLEAN-runai-log-collector-output-$TIMESTAMP"
RUN_SUFFIX=1
while [ -e "./$RUN_NAME" ] || [ -e "./$RUN_NAME.tar.gz" ]; do
  # The timestamp is minute-granular, so a second run within the same minute
  # needs a name of its own.
  RUN_NAME="$CP_NAME_CLEAN-runai-log-collector-output-${TIMESTAMP}_$RUN_SUFFIX"
  RUN_SUFFIX=$((RUN_SUFFIX + 1))
done
RUN_DIR="./$RUN_NAME"
LOG_ARCHIVE_NAME="$RUN_NAME.tar.gz"

# Plain mkdir: the loop above established the path is free, so a failure here is
# a real one (no write permission, read-only filesystem) and has to stop the run
# rather than let it produce an archive of nothing.
if ! mkdir "$RUN_DIR" 2>/dev/null; then
  err "Could not create the collection directory '$RUN_DIR'"
  detail "Check that you have write permission in $(pwd)"
  exit 1
fi

COLLECTED_LOG_DIRS=()
SUMMARY_ROWS=()
SKIPPED_NS=()

info "Collection directory:        $RUN_DIR"

for NAMESPACE in "${NAMESPACES[@]}"; do
  ns_header "$NAMESPACE"
  
  # Check namespace existence before any operations
  task "Checking if namespace '$NAMESPACE' exists..."
  k8s_cmd get namespace "$NAMESPACE" >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    skip "Namespace '$NAMESPACE' does not exist. Skipping."
    SKIPPED_NS+=("$NAMESPACE")
    continue
  fi

  ok "Namespace '$NAMESPACE' exists. Starting log collection..."
  
  LOG_DIR="$RUN_DIR/$NAMESPACE"
  mkdir -p "$LOG_DIR"
  SCRIPT_LOG="$LOG_DIR/script.log"
  SCRIPT_LOG_FAILURES=0
  COLLECTED_LOG_DIRS+=("$LOG_DIR")
  
  info "Log directory: $LOG_DIR"
  info "Failure log:   $SCRIPT_LOG"

  # Initialize the failure log. Only failed commands (with their stderr) and
  # warnings are recorded here, so the file stays short and actionable.
  {
    echo "=== Failure log for namespace '$NAMESPACE' ==="
    echo "Started:            $(date)"
    echo "Cluster URL:        $CLUSTER_URL"
    echo "Control Plane URL:  $CP_URL"
    echo ""
    echo "Only failed commands and warnings are listed below."
    echo "------------------------------------------------------------"
  } > "$SCRIPT_LOG"

  # Collect logs into logs subdirectory
  group "Collecting Pod Logs"
  collect_logs "$NAMESPACE" "$LOG_DIR"

  # Collect namespace events for every namespace. Events surface OOMKills, probe
  # failures, scheduling problems and image-pull errors — frequently the root
  # cause behind container restarts.
  group "Collecting Namespace Events"
  run_cmd "namespace events" "$LOG_DIR/events_${NAMESPACE}.txt" k8s_cmd -n "$NAMESPACE" get events --sort-by=.lastTimestamp

  # Collect extra info per namespace
  group "Collecting Additional Information"
  if [ "$NAMESPACE" == "runai" ]; then
    run_cmd "Helm charts list" "$LOG_DIR/helm_charts_list.txt" helm ls -A
    collect_helm_values "runai" "runai-cluster" "$LOG_DIR/helm-values_runai-cluster.yaml"
    run_cmd "ConfigMap runai-public" "$LOG_DIR/cm_runai-public.yaml" k8s_cmd -n runai get cm runai-public -o yaml
    run_cmd "all ConfigMaps" "$LOG_DIR/configmaps_runai.yaml" k8s_cmd -n runai get cm -o yaml
    collect_secrets "runai" "$LOG_DIR" "runai"

    if [ "$KUBECTL_CMD" == "oc" ]; then
      run_cmd "all Routes (OpenShift)" "$LOG_DIR/routes_runai.yaml" k8s_cmd -n runai get routes -o yaml
    else
      run_cmd "all Ingresses" "$LOG_DIR/ingress_runai.yaml" k8s_cmd -n runai get ingress -o yaml
    fi

    run_cmd "pod list for runai namespace" "$LOG_DIR/pod-list_runai.txt" k8s_cmd -n runai get pods -o wide
    run_cmd "node list" "$LOG_DIR/node-list.txt" k8s_cmd get nodes -o wide
    run_cmd "detailed node information" "$LOG_DIR/node-list-detailed.txt" k8s_cmd get nodes "-o=custom-columns=NAME:.metadata.name,CPUs:.status.capacity.cpu,RAM:.status.capacity.memory,GPU-cap:.status.capacity.nvidia\.com\/gpu,GPU-aloc:.status.allocatable.nvidia\.com\/gpu,GPU-type:.metadata.labels.nvidia\.com\/gpu\.product,OS:.status.nodeInfo.osImage,K8S:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion"
    run_cmd "RunAI config" "$LOG_DIR/runaiconfig.yaml" k8s_cmd -n runai get runaiconfig runai -o yaml
    run_cmd "engine config" "$LOG_DIR/engine-config.yaml" k8s_cmd -n runai get configs.engine.run.ai engine-config -o yaml

    # Collect scheduler info for runai namespace
    collect_scheduler_info "$LOG_DIR"

  elif [ "$NAMESPACE" == "runai-backend" ]; then
    run_cmd "pod list for runai-backend namespace" "$LOG_DIR/pod-list_runai-backend.txt" k8s_cmd -n runai-backend get pods -o wide
    collect_helm_values "runai-backend" "runai-backend" "$LOG_DIR/helm-values_runai-backend.yaml"
    run_cmd "all ConfigMaps" "$LOG_DIR/configmaps_runai-backend.yaml" k8s_cmd -n runai-backend get cm -o yaml
    collect_secrets "runai-backend" "$LOG_DIR" "runai-backend"

    if [ "$KUBECTL_CMD" == "oc" ]; then
      run_cmd "all Routes (OpenShift)" "$LOG_DIR/routes_runai-backend.yaml" k8s_cmd -n runai-backend get routes -o yaml
    else
      run_cmd "all Ingresses" "$LOG_DIR/ingress_runai-backend.yaml" k8s_cmd -n runai-backend get ingress -o yaml
    fi

    task "Collecting IDP settings from RunAI API..."
    # Check if curl and jq are available
    if command -v curl &> /dev/null && command -v jq &> /dev/null; then
      # Get admin credentials and control plane URL
      RUNAI_USERNAME=$(k8s_cmd get cm runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null)
      RUNAI_PASSWORD=$(k8s_cmd get secret runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
      RUNAI_CTRL_PLANE=$(k8s_cmd get cm runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.AUTH_SERVICE_URL}' 2>/dev/null)

      if [ -n "$RUNAI_USERNAME" ] && [ -n "$RUNAI_PASSWORD" ] && [ -n "$RUNAI_CTRL_PLANE" ]; then
        info "Retrieved RunAI credentials and control plane URL"

        # Get authentication token
        RUNAI_TOKEN=$(curl -s -X POST "$RUNAI_CTRL_PLANE/api/v1/token" \
          --header 'Accept: */*' \
          --header 'Content-Type: application/json' \
          --data-raw "{\"grantType\": \"password\", \"clientID\": \"cli\", \"username\": \"$RUNAI_USERNAME\", \"password\": \"$RUNAI_PASSWORD\"}" 2>/dev/null | jq -r .accessToken)

        if [ -n "$RUNAI_TOKEN" ] && [ "$RUNAI_TOKEN" != "null" ]; then
          ok "Successfully obtained API token"

          # Get IDP settings with HTTP status code
          HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" "$RUNAI_CTRL_PLANE/api/v1/idps" \
            -H 'Accept: application/json, text/plain, */*' \
            -H "Authorization: Bearer $RUNAI_TOKEN" 2>/dev/null)

          HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
          HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)

          if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
            # Check if response is valid JSON and not empty
            if echo "$HTTP_BODY" | jq empty 2>/dev/null; then
              # Check if it's an empty array or has content
              IDP_COUNT=$(echo "$HTTP_BODY" | jq 'length' 2>/dev/null)

              if [ "$IDP_COUNT" -eq 0 ]; then
                info "No IDP integration configured (empty response)"
                echo "$HTTP_BODY" > "$LOG_DIR/idp-settings.json"
                ok "Empty IDP settings saved to idp-settings.json"
              else
                echo "$HTTP_BODY" > "$LOG_DIR/idp-settings.json"
                ok "IDP settings saved to idp-settings.json (found $IDP_COUNT IDP configuration(s))"
              fi
            else
              warn "Received invalid JSON response from IDP API"
              echo "$HTTP_BODY" > "$LOG_DIR/idp-settings-error.txt"
              detail "Error response saved to idp-settings-error.txt"
            fi
          else
            warn "Failed to retrieve IDP settings (HTTP $HTTP_CODE)"
            echo "$HTTP_BODY" > "$LOG_DIR/idp-settings-error.txt"
            detail "Error response saved to idp-settings-error.txt"
          fi

          # Get Clusters information
          task "Collecting Clusters information from RunAI API..."
          HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" "$RUNAI_CTRL_PLANE/api/v1/clusters" \
            -H 'Accept: application/json, text/plain, */*' \
            -H "Authorization: Bearer $RUNAI_TOKEN" 2>/dev/null)

          HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
          HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)

          if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
            if echo "$HTTP_BODY" | jq empty 2>/dev/null; then
              echo "$HTTP_BODY" > "$LOG_DIR/clusters.json"
              CLUSTER_COUNT=$(echo "$HTTP_BODY" | jq 'length' 2>/dev/null)
              if [ -n "$CLUSTER_COUNT" ]; then
                ok "Clusters information saved to clusters.json (found $CLUSTER_COUNT cluster(s))"
              else
                ok "Clusters information saved to clusters.json"
              fi
            else
              warn "Received invalid JSON response from Clusters API"
              echo "$HTTP_BODY" > "$LOG_DIR/clusters-error.txt"
            fi
          else
            warn "Failed to retrieve Clusters information (HTTP $HTTP_CODE)"
            echo "$HTTP_BODY" > "$LOG_DIR/clusters-error.txt"
          fi

          # Get Tenants information
          task "Collecting Tenants information from RunAI API..."
          HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" "$RUNAI_CTRL_PLANE/api/v1/tenants" \
            -H 'Accept: application/json, text/plain, */*' \
            -H "Authorization: Bearer $RUNAI_TOKEN" 2>/dev/null)

          HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
          HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)

          if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
            if echo "$HTTP_BODY" | jq empty 2>/dev/null; then
              echo "$HTTP_BODY" > "$LOG_DIR/tenants.json"
              TENANT_COUNT=$(echo "$HTTP_BODY" | jq 'length' 2>/dev/null)
              if [ -n "$TENANT_COUNT" ]; then
                ok "Tenants information saved to tenants.json (found $TENANT_COUNT tenant(s))"
              else
                ok "Tenants information saved to tenants.json"
              fi
            else
              warn "Received invalid JSON response from Tenants API"
              echo "$HTTP_BODY" > "$LOG_DIR/tenants-error.txt"
            fi
          else
            warn "Failed to retrieve Tenants information (HTTP $HTTP_CODE)"
            echo "$HTTP_BODY" > "$LOG_DIR/tenants-error.txt"
          fi

          # Get K8s Settings information
          task "Collecting K8s Settings from RunAI API..."
          HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" "$RUNAI_CTRL_PLANE/v1/k8s/setting" \
            -H 'Accept: application/json, text/plain, */*' \
            -H "Authorization: Bearer $RUNAI_TOKEN" 2>/dev/null)

          HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
          HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)

          if [ "$HTTP_CODE" -eq 200 ] || [ "$HTTP_CODE" -eq 201 ]; then
            if echo "$HTTP_BODY" | jq empty 2>/dev/null; then
              echo "$HTTP_BODY" > "$LOG_DIR/k8s-settings.json"
              SETTING_COUNT=$(echo "$HTTP_BODY" | jq 'length' 2>/dev/null)
              if [ -n "$SETTING_COUNT" ]; then
                ok "K8s Settings saved to k8s-settings.json (found $SETTING_COUNT setting(s))"
              else
                ok "K8s Settings saved to k8s-settings.json"
              fi
            else
              warn "Received invalid JSON response from K8s Settings API"
              echo "$HTTP_BODY" > "$LOG_DIR/k8s-settings-error.txt"
            fi
          else
            warn "Failed to retrieve K8s Settings (HTTP $HTTP_CODE)"
            echo "$HTTP_BODY" > "$LOG_DIR/k8s-settings-error.txt"
          fi

        else
          warn "Failed to obtain API token"
        fi
      else
        warn "Could not retrieve RunAI credentials or control plane URL"
      fi
    else
      warn "curl or jq not available, skipping API data collection"
    fi

  elif [ "$NAMESPACE" == "knative-serving" ]; then
    run_cmd "pod list for knative-serving namespace" "$LOG_DIR/pod-list_knative-serving.txt" k8s_cmd -n knative-serving get pods -o wide
    run_cmd "all ConfigMaps" "$LOG_DIR/configmaps_knative-serving.yaml" k8s_cmd -n knative-serving get cm -o yaml
    collect_secrets "knative-serving" "$LOG_DIR" "knative-serving"

    task "Collecting KnativeServing object..."
    k8s_cmd -n knative-serving get knativeserving knative-serving -o yaml > "$LOG_DIR/knativeserving.yaml" 2>/dev/null
    if [ $? -eq 0 ]; then
      ok "KnativeServing object saved"
    else
      warn "Could not retrieve KnativeServing object (may not exist or have different name)"
      # Try to get any knativeserving objects
      k8s_cmd -n knative-serving get knativeserving -o yaml > "$LOG_DIR/knativeserving_all.yaml" 2>/dev/null
    fi

    run_cmd "Knative Services" "$LOG_DIR/knative-services.yaml" k8s_cmd -n knative-serving get services.serving.knative.dev -o yaml
    run_cmd "Knative Revisions" "$LOG_DIR/knative-revisions.yaml" k8s_cmd -n knative-serving get revisions.serving.knative.dev -o yaml
    run_cmd "Knative Routes" "$LOG_DIR/knative-routes.yaml" k8s_cmd -n knative-serving get routes.serving.knative.dev -o yaml
    run_cmd "Knative Configurations" "$LOG_DIR/knative-configurations.yaml" k8s_cmd -n knative-serving get configurations.serving.knative.dev -o yaml
    run_cmd "DomainMappings" "$LOG_DIR/knative-domainmappings.yaml" k8s_cmd -n knative-serving get domainmappings.serving.knative.dev -o yaml

    task "Collecting Knative Webhook Configurations..."
    # Get mutating webhook configurations with knative in the name
    MUTATING_WEBHOOKS=$(k8s_cmd get mutatingwebhookconfigurations -o name 2>/dev/null | grep -i knative)
    if [ -n "$MUTATING_WEBHOOKS" ]; then
      echo "$MUTATING_WEBHOOKS" | while read webhook; do
        k8s_cmd get "$webhook" -o yaml >> "$LOG_DIR/mutatingwebhooks_knative.yaml" 2>/dev/null
        echo "---" >> "$LOG_DIR/mutatingwebhooks_knative.yaml"
      done
      ok "Mutating Webhook Configurations saved"
    else
      warn "No Knative Mutating Webhook Configurations found"
    fi

    # Get validating webhook configurations with knative in the name
    VALIDATING_WEBHOOKS=$(k8s_cmd get validatingwebhookconfigurations -o name 2>/dev/null | grep -i knative)
    if [ -n "$VALIDATING_WEBHOOKS" ]; then
      echo "$VALIDATING_WEBHOOKS" | while read webhook; do
        k8s_cmd get "$webhook" -o yaml >> "$LOG_DIR/validatingwebhooks_knative.yaml" 2>/dev/null
        echo "---" >> "$LOG_DIR/validatingwebhooks_knative.yaml"
      done
      ok "Validating Webhook Configurations saved"
    else
      warn "No Knative Validating Webhook Configurations found"
    fi

  elif [ "$NAMESPACE" == "knative-operator" ] || [ "$NAMESPACE" == "knativeoperator" ]; then
    run_cmd "pod list for $NAMESPACE namespace" "$LOG_DIR/pod-list_${NAMESPACE}.txt" k8s_cmd -n "$NAMESPACE" get pods -o wide
    run_cmd "all ConfigMaps" "$LOG_DIR/configmaps_${NAMESPACE}.yaml" k8s_cmd -n "$NAMESPACE" get cm -o yaml
    collect_secrets "$NAMESPACE" "$LOG_DIR" "$NAMESPACE"

  elif [ "$NAMESPACE" == "runai-reservation" ]; then
    run_cmd "pod list for runai-reservation namespace" "$LOG_DIR/pod-list_runai-reservation.txt" k8s_cmd -n runai-reservation get pods -o wide
    run_cmd "all ConfigMaps" "$LOG_DIR/configmaps_runai-reservation.yaml" k8s_cmd -n runai-reservation get cm -o yaml
    collect_secrets "runai-reservation" "$LOG_DIR" "runai-reservation"
    run_cmd "all Services" "$LOG_DIR/services_runai-reservation.yaml" k8s_cmd -n runai-reservation get svc -o yaml
    run_cmd "all Deployments" "$LOG_DIR/deployments_runai-reservation.yaml" k8s_cmd -n runai-reservation get deployments -o yaml
    run_cmd "all StatefulSets" "$LOG_DIR/statefulsets_runai-reservation.yaml" k8s_cmd -n runai-reservation get statefulsets -o yaml
    run_cmd "all DaemonSets" "$LOG_DIR/daemonsets_runai-reservation.yaml" k8s_cmd -n runai-reservation get daemonsets -o yaml
    run_cmd "all PersistentVolumeClaims" "$LOG_DIR/pvcs_runai-reservation.yaml" k8s_cmd -n runai-reservation get pvc -o yaml
  fi

  # Finalize the failure log for this namespace.
  NS_FAILS=$SCRIPT_LOG_FAILURES
  if [ "$NS_FAILS" -eq 0 ]; then
    echo "" >> "$SCRIPT_LOG"
    echo "No failures or warnings recorded — all data collected successfully." >> "$SCRIPT_LOG"
  fi
  echo "Finished: $(date)" >> "$SCRIPT_LOG"
  SCRIPT_LOG=""  # stop routing warnings/errors to this file

  # Record stats for the top-level collection summary.
  POD_LIST="$LOG_DIR/pod-list_${NAMESPACE}.txt"
  NS_RESTARTS=0
  if [ -f "$POD_LIST" ]; then
    NS_RESTARTS=$(awk 'NR>1 {s += ($4 + 0)} END {print s + 0}' "$POD_LIST" 2>/dev/null)
  fi
  SUMMARY_ROWS+=("$(printf '%-22s %6s %10s %8s' "$NAMESPACE" "${LAST_POD_COUNT:-0}" "$NS_RESTARTS" "$NS_FAILS")")

  ok "Completed processing namespace: $NAMESPACE"
  if [ "$NS_FAILS" -eq 0 ]; then
    info "No failures recorded (see $LOG_DIR/script.log)"
  else
    warn "$NS_FAILS issue(s) recorded — see $LOG_DIR/script.log"
  fi
done

if [ ${#COLLECTED_LOG_DIRS[@]} -eq 0 ]; then
  section "No Data Collected"
  warn "No namespaces were found. No archive was created."
  rmdir "$RUN_DIR" 2>/dev/null
  exit 0
fi

section "Collection Summary"
SUMMARY_FILE="$RUN_DIR/collection-summary.txt"
{
  echo "Run:AI Cluster Log Collector — Collection Summary"
  echo "=================================================="
  echo "Tool version:       $VERSION"
  echo "Generated:          $(date)"
  echo "Cluster URL:        $CLUSTER_URL"
  echo "Control Plane URL:  $CP_URL"
  echo "Cluster CLI:        $KUBECTL_CMD"
  echo ""
  printf '%-22s %6s %10s %8s\n' "NAMESPACE" "PODS" "RESTARTS" "ISSUES"
  printf '%-22s %6s %10s %8s\n' "----------------------" "------" "----------" "--------"
  for row in "${SUMMARY_ROWS[@]}"; do
    echo "$row"
  done
  echo ""
  if [ ${#SKIPPED_NS[@]} -gt 0 ]; then
    echo "Skipped namespaces (not present): ${SKIPPED_NS[*]}"
  else
    echo "Skipped namespaces (not present): none"
  fi
  echo ""
  echo "Notes:"
  echo "  - RESTARTS is the sum of container restarts across all pods in the namespace."
  echo "  - ISSUES is the number of failed commands/warnings; details in <namespace>/script.log."
  echo "  - Previous (pre-restart) container logs, when a container had restarted,"
  echo "    are saved alongside current logs as *_previous.log."
} > "$SUMMARY_FILE"

# Echo the summary to the terminal as well.
cat "$SUMMARY_FILE"

section "Creating Combined Archive"
info "Archive name: $LOG_ARCHIVE_NAME"
info "Including ${#COLLECTED_LOG_DIRS[@]} namespace folder(s) + collection-summary.txt:"
for dir in "${COLLECTED_LOG_DIRS[@]}"; do
  detail "- $(basename "$dir")"
done

task "Calculating total size..."
du -chs "$RUN_DIR"

task "Creating tar archive..."
if ! tar czf "$LOG_ARCHIVE_NAME" "$RUN_NAME"; then
  err "Failed to create the archive"
  detail "The collected logs are preserved in $RUN_DIR"
  exit 1
fi
ok "Archive created"

task "Archive details:"
ls -lah "$LOG_ARCHIVE_NAME"

# Safe to remove outright: this run created the directory, and everything in it
# is in the archive.
task "Cleaning up temporary files..."
rm -rf "$RUN_DIR"
ok "Temporary files removed"

section "Done"
echo "${C_BOLD}${C_GREEN}🎉 All namespaces processed successfully!${C_RESET}"
echo "${C_BOLD}📦 Combined archive: ${C_GREEN}$LOG_ARCHIVE_NAME${C_RESET}"
