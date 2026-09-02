#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Workload Info Dump Script
VERSION="1.2.0"

# Removed 'set -e' to allow script to continue when individual commands fail

# Global variable to store the kubectl command (kubectl or oc)
KUBECTL_CMD=""

# Function to detect if this is an OpenShift cluster and set appropriate CLI
detect_k8s_cli() {
  local is_openshift=false

  # First, detect if this is an OpenShift cluster by checking for OpenShift-specific API groups
  # Try with oc first if available
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
    # OpenShift cluster detected - prefer oc if available
    if command -v "oc" &> /dev/null; then
      echo "✅ OpenShift cluster detected, using 'oc'"
      KUBECTL_CMD="oc"
      return 0
    elif command -v "kubectl" &> /dev/null; then
      echo "✅ OpenShift cluster detected, using 'kubectl'"
      KUBECTL_CMD="kubectl"
      return 0
    fi
  else
    # Standard Kubernetes cluster - prefer kubectl if available
    if command -v "kubectl" &> /dev/null; then
      echo "✅ Standard Kubernetes cluster detected, using 'kubectl'"
      KUBECTL_CMD="kubectl"
      return 0
    elif command -v "oc" &> /dev/null; then
      echo "✅ Standard Kubernetes cluster detected, using 'oc'"
      KUBECTL_CMD="oc"
      return 0
    fi
  fi

  echo "❌ Error: Neither 'kubectl' nor 'oc' command found."
  echo "Please install one of them and ensure it's accessible in PATH"
  exit 1
}

# Function to execute kubectl/oc commands
k8s_cmd() {
  $KUBECTL_CMD "$@"
}

usage() {
  echo "Workload Info Dump Script v${VERSION}"
  echo ""
  echo "Usage: $0 --project <PROJECT> --workload <WORKLOAD>"
  echo "       $0 --version"
  echo ""
  echo "Workload names are unique within a project, so the workload type and the"
  echo "CR architecture (native Run:AI workload CRDs vs. the 2.26+ WorkloadRunner)"
  echo "are detected automatically."
  echo ""
  echo "Examples:"
  echo "  $0 --project test --workload test-train"
  echo "  $0 --project ml-team --workload bert-inference"
  echo ""
  echo "Options:"
  echo "  --project <PROJECT>    Run:AI project name (required)"
  echo "  --workload <WORKLOAD>  Workload name (required)"
  echo "  --version              Show script version and exit"
  exit 1
}

# Parse arguments first to handle --version before kubectl/oc checks
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --project)
      PROJECT="$2"
      shift; shift
      ;;
    --workload)
      WORKLOAD="$2"
      shift; shift
      ;;
    --version)
      echo "Workload Info Dump Script v${VERSION}"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

# Validate required arguments
if [[ -z "$PROJECT" || -z "$WORKLOAD" ]]; then
  usage
fi

# Both values are used in local output paths as well as Kubernetes lookups.
# Kubernetes object names do not require path separators or shell metacharacters,
# so reject them rather than allowing archive paths to escape the working dir.
validate_name() {
  local label="$1" value="$2"
  if [[ ! "$value" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
    echo "❌ Error: Invalid ${label}: '$value'"
    echo "Use only letters, numbers, dots, underscores, and hyphens; start with a letter or number."
    exit 1
  fi
}

validate_name "project name" "$PROJECT"
validate_name "workload name" "$WORKLOAD"

# Detect cluster type and set appropriate CLI command (kubectl or oc)
detect_k8s_cli

# Test cluster connectivity
if ! k8s_cmd cluster-info &> /dev/null; then
    echo "❌ Error: $KUBECTL_CMD cannot connect to cluster"
    echo "Please check your kubeconfig and cluster connectivity"
    exit 1
fi
echo "✅ $KUBECTL_CMD can connect to cluster"

# Display script version
echo ""
echo "🔧 Workload Info Dump Script v${VERSION}"
echo "   Workload type and CR architecture are detected automatically"
echo "   Supports native workload CRDs, WorkloadRunner (2.26+) and External Workloads"
echo ""

# ============================================================================
# API resource discovery
# ============================================================================

# Table of namespaced API resources available on this cluster, one line per
# resource: "<fully-qualified-name>\t<group>\t<kind>". Built once because
# detection and child-resource collection both need to know which kinds the
# server actually serves: kubectl aborts an entire multi-kind `get` when a
# single type is unknown, so every candidate has to be filtered up front.
API_RESOURCES=""

load_api_resources() {
  # Columns are NAME [SHORTNAMES] APIVERSION NAMESPACED KIND — SHORTNAMES is
  # omitted when empty, so index from the end of the line.
  API_RESOURCES=$(k8s_cmd api-resources --namespaced=true --no-headers 2>/dev/null | awk 'NF>=4 {
    name=$1; apiversion=$(NF-2); kind=$NF;
    slash=index(apiversion, "/");
    group=(slash==0 ? "" : substr(apiversion, 1, slash-1));
    fqn=(group=="" ? name : name "." group);
    printf "%s\t%s\t%s\n", fqn, group, kind;
  }')

  if [[ -z "$API_RESOURCES" ]]; then
    echo "⚠️  Could not list API resources; falling back to per-resource probing"
  fi
}

# True when the cluster serves the given fully-qualified resource name.
resource_available() {
  local fqn="$1"
  if [[ -z "$API_RESOURCES" ]]; then
    # No resource list available: probe the server directly.
    k8s_cmd -n "$NAMESPACE" get "$fqn" -o name >/dev/null 2>&1
    return $?
  fi
  awk -F'\t' -v f="$fqn" '$1==f {found=1; exit} END {exit !found}' <<< "$API_RESOURCES"
}

# Map an object's apiVersion + kind back to the resource name kubectl needs.
# Group+kind is unambiguous where a bare plural is not: "ingresses" exists in
# both networking.k8s.io and networking.internal.knative.dev.
resource_for_object() {
  local apiversion="$1" kind="$2" group=""
  case "$apiversion" in
    */*) group="${apiversion%%/*}" ;;
  esac
  awk -F'\t' -v g="$group" -v k="$kind" '$2==g && $3==k {print $1; exit}' <<< "$API_RESOURCES"
}

lowercase() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# ============================================================================
# Namespace resolution
# ============================================================================

# The project CR carries its namespace in status; the runai/queue label is the
# fallback. Neither era guarantees the namespace is named "runai-<project>".
resolve_namespace() {
  NAMESPACE=$(k8s_cmd get projects.run.ai "$PROJECT" -o jsonpath='{.status.namespace}' 2>/dev/null)
  if [[ -z "$NAMESPACE" ]]; then
    NAMESPACE=$(k8s_cmd get ns -l runai/queue="$PROJECT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  fi
  if [[ -z "$NAMESPACE" ]]; then
    echo "❌ No namespace found for project: $PROJECT"
    echo "Please check that the project exists and is accessible"
    exit 1
  fi
}

# ============================================================================
# Workload detection
# ============================================================================

# Detection results.
ARCHITECTURE=""            # workloadrunner | native | external
ARCHITECTURE_LABEL=""
WORKLOAD_TYPE=""           # Workspace | Training | Distributed | Inference | ...
TYPE_SLUG=""               # filename-safe form of WORKLOAD_TYPE
ROOT_RESOURCE=""           # resource name for kubectl, e.g. workloadrunners.run.ai
ROOT_KIND=""
ROOT_NAME=""
ROOT_UID=""
WORKLOAD_ID=""
TEMPLATE_GVK=""            # what a WorkloadRunner actually runs
CONVERTED_FROM_NATIVE=""
EXTRA_SEED_UID=""          # second tree root (external workloads)
EXTRA_SEED_RESOURCE=""
EXTRA_SEED_KIND=""
EXTRA_SEED_NAME=""
WORKLOAD_LABEL_NAME=""     # name carried by the workloadName label on children
DETECTION_NOTES=""

# Legacy CRD kind -> logical workload type.
type_for_native_kind() {
  case "$1" in
    InteractiveWorkload)          echo "Workspace" ;;
    TrainingWorkload)             echo "Training" ;;
    DistributedWorkload)          echo "Distributed" ;;
    InferenceWorkload)            echo "Inference" ;;
    DistributedInferenceWorkload) echo "DistributedInference" ;;
    *)                            echo "$1" ;;
  esac
}

add_note() {
  DETECTION_NOTES="${DETECTION_NOTES}${1}"$'\n'
}

# Probe the 2.26+ WorkloadRunner first. Ordering matters for correctness, not
# just speed: all native CRDs remain registered on 2.26 and still receive
# workloads whose type is not enabled for any-workload submission (or that fell
# back after a 501), so a single cluster can hold both shapes at once.
detect_workloadrunner() {
  resource_available "workloadrunners.run.ai" || return 1
  k8s_cmd -n "$NAMESPACE" get workloadrunners.run.ai "$WORKLOAD" -o name >/dev/null 2>&1 || return 1

  ARCHITECTURE="workloadrunner"
  ARCHITECTURE_LABEL="WorkloadRunner / any-workload controller (2.26+)"
  ROOT_RESOURCE="workloadrunners.run.ai"
  ROOT_KIND="WorkloadRunner"
  ROOT_NAME="$WORKLOAD"

  # A bare WorkloadRunner cannot tell you the workload type: its own labels only
  # describe the wrapped GVK (run.ai/workload-kind=Job). The logical type lives
  # in the embedded template's labels.
  local fields
  fields=$(k8s_cmd -n "$NAMESPACE" get workloadrunners.run.ai "$WORKLOAD" -o jsonpath=\
'{.spec.template.metadata.labels.workloadKind}|{.spec.template.apiVersion}|{.spec.template.kind}|{.spec.template.metadata.labels.run\.ai/converted-from-native}|{.metadata.annotations.workloadId}|{.metadata.uid}' 2>/dev/null)

  local template_api template_kind
  IFS='|' read -r WORKLOAD_TYPE template_api template_kind CONVERTED_FROM_NATIVE WORKLOAD_ID ROOT_UID <<< "$fields"
  TEMPLATE_GVK="${template_api} ${template_kind}"

  if [[ -z "$WORKLOAD_TYPE" ]]; then
    # NIM, Dynamo and bring-your-own YAML are WorkloadRunners too, but were
    # never a native Run:AI type, so they carry no workloadKind label. The
    # mirrored ExternalWorkload holds a clean type when one exists.
    WORKLOAD_TYPE=$(k8s_cmd -n "$NAMESPACE" get externalworkloads.run.ai \
      -l run.ai/workload-runner-name="$WORKLOAD" -o jsonpath='{.items[0].spec.type}' 2>/dev/null)
  fi
  if [[ -z "$WORKLOAD_TYPE" ]]; then
    WORKLOAD_TYPE="Generic (${template_kind:-unknown})"
    add_note "No workloadKind label on the template: this WorkloadRunner was not converted from a native Run:AI type (NIM / Dynamo / user-supplied manifest)."
  fi

  if [[ "$CONVERTED_FROM_NATIVE" == "true" ]]; then
    add_note "Template is labelled run.ai/converted-from-native=true: submitted as a native ${WORKLOAD_TYPE} and converted to a WorkloadRunner by the control plane."
  fi
  return 0
}

# Native workload CRDs, probed one at a time on purpose: kubectl aborts an
# entire multi-kind `get` when any one type is unknown to the server.
detect_native() {
  local resource kind
  for resource in interactiveworkloads.run.ai trainingworkloads.run.ai \
                  distributedworkloads.run.ai inferenceworkloads.run.ai \
                  distributedinferenceworkloads.run.ai; do
    resource_available "$resource" || continue
    kind=$(k8s_cmd -n "$NAMESPACE" get "$resource" "$WORKLOAD" \
      -o jsonpath='{.kind}' 2>/dev/null)
    [[ -z "$kind" ]] && continue

    ARCHITECTURE="native"
    ARCHITECTURE_LABEL="Native Run:AI workload CRD"
    ROOT_RESOURCE="$resource"
    ROOT_KIND="$kind"
    ROOT_NAME="$WORKLOAD"
    WORKLOAD_TYPE=$(type_for_native_kind "$kind")
    CONVERTED_FROM_NATIVE="false"

    local fields
    fields=$(k8s_cmd -n "$NAMESPACE" get "$resource" "$WORKLOAD" \
      -o jsonpath='{.metadata.annotations.workloadId}|{.metadata.uid}' 2>/dev/null)
    IFS='|' read -r WORKLOAD_ID ROOT_UID <<< "$fields"

    if resource_available "workloadrunners.run.ai"; then
      add_note "Cluster serves workloadrunners.run.ai but this workload has a native CR: its type is not enabled for any-workload submission, or conversion fell back to the legacy CRD."
    fi
    return 0
  done
  return 1
}

# ExternalWorkload: a third-party resource (Deployment, StatefulSet, …) that is
# scheduled by Run:AI. The CR is named ew-<type>-<name>, so match on
# spec.originalWorkloadName rather than guessing the prefix.
detect_external() {
  resource_available "externalworkloads.run.ai" || return 1

  local table row
  table=$(k8s_cmd -n "$NAMESPACE" get externalworkloads.run.ai -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{.spec.originalWorkloadName}{"\t"}{.spec.type}{"\t"}{.spec.group}{"\t"}{.spec.originalWorkloadUID}{"\t"}{.metadata.uid}{"\n"}{end}' 2>/dev/null)
  [[ -z "$table" ]] && return 1

  row=$(awk -F'\t' -v w="$WORKLOAD" '$2==w || $1==w {print; exit}' <<< "$table")
  [[ -z "$row" ]] && return 1

  local ew_name owner_name owner_kind owner_group owner_uid
  IFS=$'\t' read -r ew_name owner_name owner_kind owner_group owner_uid ROOT_UID <<< "$row"

  ARCHITECTURE="external"
  ARCHITECTURE_LABEL="ExternalWorkload (third-party resource using the Run:AI scheduler)"
  ROOT_RESOURCE="externalworkloads.run.ai"
  ROOT_KIND="ExternalWorkload"
  ROOT_NAME="$ew_name"
  WORKLOAD_TYPE="External ${owner_kind:-workload}"

  # The ExternalWorkload only mirrors state; the resource that actually owns the
  # pods is the original object, so it seeds the tree walk as a second root.
  if [[ -n "$owner_kind" ]]; then
    EXTRA_SEED_KIND="$owner_kind"
    EXTRA_SEED_NAME="${owner_name:-$WORKLOAD}"
    EXTRA_SEED_UID="$owner_uid"
    EXTRA_SEED_RESOURCE=$(awk -F'\t' -v g="$owner_group" -v k="$owner_kind" \
      '$2==g && $3==k {print $1; exit}' <<< "$API_RESOURCES")
    add_note "Owner resource: ${EXTRA_SEED_KIND}/${EXTRA_SEED_NAME} (uid ${EXTRA_SEED_UID:-unknown})."
  fi
  return 0
}

detect_workload() {
  echo "🔍 Detecting workload '$WORKLOAD' in namespace $NAMESPACE..."

  if detect_workloadrunner; then
    :
  elif detect_native; then
    :
  elif detect_external; then
    :
  else
    echo "❌ No workload named '$WORKLOAD' found in namespace $NAMESPACE"
    echo "   Probed: workloadrunners.run.ai, the native workload CRDs and externalworkloads.run.ai"
    echo "   Please check the workload name, the project and your permissions"
    exit 1
  fi

  TYPE_SLUG=$(lowercase "$WORKLOAD_TYPE" | tr -cs 'a-z0-9' '_' | sed 's/^_//; s/_$//')
  [[ -z "$TYPE_SLUG" ]] && TYPE_SLUG="workload"

  # Children of an external workload are labelled with the original object's
  # name, not the ew-<type>-<name> CR name.
  WORKLOAD_LABEL_NAME="${EXTRA_SEED_NAME:-$WORKLOAD}"

  echo "  ✅ architecture : ${ARCHITECTURE_LABEL}"
  echo "  ✅ type         : ${WORKLOAD_TYPE}"
  echo "  ✅ top-level CR : ${ROOT_RESOURCE}/${ROOT_NAME}"
  [[ -n "$TEMPLATE_GVK" ]] && echo "  ✅ runs template: ${TEMPLATE_GVK}"
  echo "  ✅ workloadId   : ${WORKLOAD_ID:-<none>}"
  echo ""
}

# ============================================================================
# Child resource discovery
# ============================================================================

# Kinds that can appear in a workload's resource tree in any era. Filtered
# against the cluster's API resources before use.
CHILD_RESOURCE_CANDIDATES="pods
services
configmaps
secrets
persistentvolumeclaims
jobs.batch
deployments.apps
replicasets.apps
statefulsets.apps
daemonsets.apps
ingresses.networking.k8s.io
routes.route.openshift.io
httproutes.gateway.networking.k8s.io
runaijobs.run.ai
externalworkloads.run.ai
podgroups.scheduling.run.ai
pytorchjobs.kubeflow.org
tfjobs.kubeflow.org
mpijobs.kubeflow.org
xgboostjobs.kubeflow.org
jaxjobs.kubeflow.org
services.serving.knative.dev
configurations.serving.knative.dev
revisions.serving.knative.dev
routes.serving.knative.dev
podautoscalers.autoscaling.internal.knative.dev
serverlessservices.networking.internal.knative.dev
ingresses.networking.internal.knative.dev
leaderworkersets.leaderworkerset.x-k8s.io
nimservices.apps.nvidia.com
nimcaches.apps.nvidia.com
computedomains.resource.nvidia.com"

# Flat table of every candidate object in the namespace, one line per object:
# "<apiVersion>\t<kind>\t<name>\t<uid>\t<ownerUid>=<controller>,…"
OWNER_TABLE=""

load_owner_table() {
  local available="" resource joined
  while IFS= read -r resource; do
    [[ -z "$resource" ]] && continue
    resource_available "$resource" && available="${available}${resource}"$'\n'
  done <<< "$CHILD_RESOURCE_CANDIDATES"

  if [[ -z "$available" ]]; then
    return 1
  fi

  local jsonpath='{range .items[*]}{.apiVersion}{"\t"}{.kind}{"\t"}{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{range .metadata.ownerReferences[*]}{.uid}{"="}{.controller}{","}{end}{"\n"}{end}'

  joined=$(tr '\n' ',' <<< "$available" | sed 's/,$//')
  OWNER_TABLE=$(k8s_cmd -n "$NAMESPACE" get "$joined" -o jsonpath="$jsonpath" 2>/dev/null)

  # A single denied or flaky resource can fail the combined request; retry one
  # kind at a time so one gap does not cost the whole tree.
  if [[ -z "$OWNER_TABLE" ]]; then
    while IFS= read -r resource; do
      [[ -z "$resource" ]] && continue
      local part
      part=$(k8s_cmd -n "$NAMESPACE" get "$resource" -o jsonpath="$jsonpath" 2>/dev/null)
      [[ -n "$part" ]] && OWNER_TABLE="${OWNER_TABLE}${part}"$'\n'
    done <<< "$available"
  fi

  [[ -n "$OWNER_TABLE" ]]
}

CHILD_ENTRIES=""   # "<resource>\t<kind>\t<name>"
TREE_TEXT=""
SEEN_UIDS="|"

# Walk descendants by UID membership rather than assuming a single spine: in
# 2.26 the PVCs, personal-credential secrets and ComputeDomain hang off the
# WorkloadRunner while the networking resources hang off the Job. Non-controller
# owner references are followed deliberately — 2.26 networking uses
# SetOwnerReference, so filtering on controller==true drops all of it.
walk_children() {
  local parent_uid="$1" depth="$2"
  [[ -z "$parent_uid" ]] && return
  [[ $depth -gt 8 ]] && return

  local apiversion kind name uid owners marker resource indent
  while IFS=$'\t' read -r apiversion kind name uid owners; do
    [[ -z "$uid" || -z "$name" ]] && continue
    case ",${owners}" in
      *",${parent_uid}="*) ;;
      *) continue ;;
    esac
    case "$SEEN_UIDS" in
      *"|${uid}|"*) continue ;;
    esac
    SEEN_UIDS="${SEEN_UIDS}${uid}|"

    marker=""
    case ",${owners}" in
      *",${parent_uid}=true,"*) ;;
      *) marker="   [owner ref, not controller]" ;;
    esac

    resource=$(resource_for_object "$apiversion" "$kind")
    [[ -z "$resource" ]] && resource=$(lowercase "$kind")

    indent=$(printf "%*s" $((depth * 2)) "")
    TREE_TEXT="${TREE_TEXT}${indent}${kind}/${name}${marker}"$'\n'
    CHILD_ENTRIES="${CHILD_ENTRIES}${resource}"$'\t'"${kind}"$'\t'"${name}"$'\n'

    walk_children "$uid" $((depth + 1))
  done <<< "$OWNER_TABLE"
}

discover_child_resources() {
  echo "🔍 Discovering child resources by owner reference..."

  if ! load_owner_table; then
    echo "  ⚠️  Could not list namespace resources; child discovery skipped"
    return 1
  fi

  TREE_TEXT="${ROOT_KIND}/${ROOT_NAME}"$'\n'
  SEEN_UIDS="|${ROOT_UID}|"
  walk_children "$ROOT_UID" 1

  # External workloads: the original object is a sibling of the ExternalWorkload
  # rather than a child, so walk it as its own root.
  if [[ -n "$EXTRA_SEED_UID" ]]; then
    TREE_TEXT="${TREE_TEXT}${EXTRA_SEED_KIND}/${EXTRA_SEED_NAME}"$'\n'
    if [[ -n "$EXTRA_SEED_RESOURCE" ]]; then
      CHILD_ENTRIES="${CHILD_ENTRIES}${EXTRA_SEED_RESOURCE}"$'\t'"${EXTRA_SEED_KIND}"$'\t'"${EXTRA_SEED_NAME}"$'\n'
    fi
    SEEN_UIDS="${SEEN_UIDS}${EXTRA_SEED_UID}|"
    walk_children "$EXTRA_SEED_UID" 1
  fi

  local count=$(grep -c . <<< "$CHILD_ENTRIES")
  echo "  ✅ ${count} child resource(s) found"
  echo ""
}

# ============================================================================
# Collection helpers
# ============================================================================

OUTPUT_FILES=()

# Run a namespaced kubectl command, retrying once on failure. Collection issues
# hundreds of small requests, and a single transient API error would otherwise
# drop a resource from an archive that still looks complete.
attempt() {
  local dest="$1"
  shift
  k8s_cmd -n "$NAMESPACE" "$@" > "$dest" 2>/dev/null && return 0
  sleep 2
  k8s_cmd -n "$NAMESPACE" "$@" > "$dest" 2>/dev/null
}

# Run a namespaced kubectl command and keep its output only when non-empty.
save_output() {
  local dest="$1" label="$2"
  shift 2
  if attempt "$dest" "$@" && [[ -s "$dest" ]]; then
    echo "    ✅ ${label}"
    OUTPUT_FILES+=("$dest")
    return 0
  fi
  rm -f "$dest" 2>/dev/null
  echo "    ⚠️  ${label} — not available"
  return 1
}

# Container logs, where an empty result is a result: a container that is running
# and has never written a line is a real signal, and a missing file cannot be
# told apart from a failed collection. Judged on exit status, not on size.
save_logs() {
  local dest="$1" label="$2"
  shift 2
  if attempt "$dest" logs "$@"; then
    if [[ -s "$dest" ]]; then
      echo "    ✅ ${label}"
    else
      echo "    ✅ ${label} (empty)"
    fi
    OUTPUT_FILES+=("$dest")
    return 0
  fi
  rm -f "$dest" 2>/dev/null
  echo "    ⚠️  ${label} — not available"
  return 1
}

# Same, for list-style gets. `get -o yaml` still emits an empty List object when
# nothing matches, so an "items: []" file would otherwise be kept as a result.
save_list() {
  local dest="$1" label="$2"
  shift 2
  if attempt "$dest" "$@" -o yaml && [[ -s "$dest" ]] &&
     ! grep -q '^items: \[\]$' "$dest"; then
    echo "    ✅ ${label}"
    OUTPUT_FILES+=("$dest")
    return 0
  fi
  rm -f "$dest" 2>/dev/null
  echo "    ⚠️  ${label} — none found"
  return 1
}

collect_workload_resources() {
  local dir="${OUTPUT_DIR}/workload"
  mkdir -p "$dir"

  echo "  📄 Collecting workload CRs..."
  save_output "${dir}/$(lowercase "$ROOT_KIND")_${ROOT_NAME}.yaml" \
    "${ROOT_KIND}/${ROOT_NAME}" get "$ROOT_RESOURCE" "$ROOT_NAME" -o yaml

  local resource kind name dest group
  while IFS=$'\t' read -r resource kind name; do
    [[ -z "$name" ]] && continue

    # Pods are handled by the pod pipeline below (YAML, describe, logs).
    [[ "$kind" == "Pod" ]] && continue

    # Secrets: describe only. It lists the keys and their sizes without
    # exporting the values, which for personal-credential secrets means git and
    # registry tokens stay out of the archive.
    if [[ "$kind" == "Secret" ]]; then
      save_output "${dir}/secret_${name}_describe.txt" \
        "Secret/${name} (describe, values withheld)" describe secret "$name"
      continue
    fi

    dest="${dir}/$(lowercase "$kind")_${name}.yaml"
    if [[ -f "$dest" ]]; then
      # The same kind and name can exist in two API groups: a Knative Service
      # named foo owns a core Service foo. Qualify the later one by group.
      group="${resource#*.}"
      [[ "$group" == "$resource" ]] && group="core"
      dest="${dir}/$(lowercase "$kind")_${name}_${group}.yaml"
      [[ -f "$dest" ]] && continue
    fi
    save_output "$dest" "${kind}/${name} (${resource})" get "$resource" "$name" -o yaml
  done <<< "$CHILD_ENTRIES"

  # PodGroups are matched by label rather than ownership: they are created by
  # the scheduler and are not part of the workload's owner tree in every era.
  save_list "${dir}/podgroups.yaml" "PodGroups (workloadName=${WORKLOAD_LABEL_NAME})" \
    get podgroups.scheduling.run.ai -l workloadName="$WORKLOAD_LABEL_NAME"

  # Knative Service fallback for inference workloads, in case the ksvc is not
  # reachable through owner references. Inference only: DistributedInference
  # runs on a LeaderWorkerSet and has no Knative Service.
  if [[ "$WORKLOAD_TYPE" == "Inference" ]] && resource_available "services.serving.knative.dev" &&
     ! awk -F'\t' '$1=="services.serving.knative.dev" {found=1} END {exit !found}' <<< "$CHILD_ENTRIES"; then
    save_output "${dir}/ksvc_${WORKLOAD}.yaml" "KnativeService/${WORKLOAD}" \
      get services.serving.knative.dev "$WORKLOAD" -o yaml
  fi
}

# ============================================================================
# Pods
# ============================================================================

# Pod names discovered from the owner tree, unioned with a label lookup. The
# tree is authoritative and works for stopped workloads; the label selector
# catches pods whose intermediate owner is a kind this script does not list.
collect_pod_names() {
  local names="" selector="" resource kind name

  while IFS=$'\t' read -r resource kind name; do
    [[ "$kind" == "Pod" && -n "$name" ]] && names="${names}${name}"$'\n'
  done <<< "$CHILD_ENTRIES"

  # run.ai/workload-id is the cleanest identity anchor: same key and same
  # meaning in both eras. workloadName is the fallback.
  if [[ -n "$WORKLOAD_ID" ]]; then
    selector="run.ai/workload-id=${WORKLOAD_ID}"
  elif [[ -n "$EXTRA_SEED_UID" ]]; then
    selector="run.ai/top-owner-uid=${EXTRA_SEED_UID}"
  else
    selector="workloadName=${WORKLOAD_LABEL_NAME}"
  fi

  local labelled
  labelled=$(k8s_cmd -n "$NAMESPACE" get pods -l "$selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  names="${names}${labelled}"$'\n'

  grep . <<< "$names" | sort -u
}

# Namespace-wide pod -> container mapping, fetched once.
POD_CONTAINERS=""

load_pod_containers() {
  POD_CONTAINERS=$(k8s_cmd -n "$NAMESPACE" get pods -o jsonpath=\
'{range .items[*]}{.metadata.name}{"\t"}{range .spec.initContainers[*]}{.name}{" "}{end}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null)
}

containers_of_pod() {
  awk -F'\t' -v p="$1" '$1==p {print $2; exit}' <<< "$POD_CONTAINERS"
}

collect_pods() {
  local pod_names="$1"
  local dir="${OUTPUT_DIR}/pods"

  if [[ -z "$pod_names" ]]; then
    echo "  ⚠️  No pods found for this workload (stopped, suspended or pending)"
    return 1
  fi

  mkdir -p "$dir"

  load_pod_containers

  local pod containers container total_pods=0 total_containers=0 total_nvidia=0
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    ((total_pods++))
    echo "    🐳 Pod: $pod"

    save_output "${dir}/${pod}.yaml" "${pod} YAML" get pod "$pod" -o yaml
    save_output "${dir}/${pod}_describe.txt" "${pod} describe" describe pod "$pod"

    containers=$(containers_of_pod "$pod")
    for container in $containers; do
      [[ -z "$container" ]] && continue
      ((total_containers++))

      save_logs "${dir}/${pod}_${container}.log" "${pod}/${container} logs" \
        "$pod" -c "$container"

      # Previous-instance logs only exist after a restart; keep the file only
      # when there is something in it.
      local prev="${dir}/${pod}_${container}_previous.log"
      if k8s_cmd -n "$NAMESPACE" logs "$pod" -c "$container" --previous > "$prev" 2>/dev/null && [[ -s "$prev" ]]; then
        echo "    ✅ ${pod}/${container} previous logs"
        OUTPUT_FILES+=("$prev")
      else
        rm -f "$prev" 2>/dev/null
      fi

      local nvidia="${dir}/${pod}_${container}_nvidia-smi.txt"
      if k8s_cmd -n "$NAMESPACE" exec "$pod" -c "$container" -- nvidia-smi > "$nvidia" 2>/dev/null && [[ -s "$nvidia" ]]; then
        echo "    ✅ ${pod}/${container} nvidia-smi"
        OUTPUT_FILES+=("$nvidia")
        ((total_nvidia++))
      else
        rm -f "$nvidia" 2>/dev/null
      fi
    done
  done <<< "$pod_names"

  echo "  ✅ ${total_pods} pod(s), ${total_containers} container(s), ${total_nvidia} nvidia-smi output(s)"
}

# ============================================================================
# Namespace context
# ============================================================================

collect_namespace_context() {
  local dir="${OUTPUT_DIR}/namespace"
  mkdir -p "$dir"

  save_output "${dir}/pod-list.txt" "pod list" get pods -o wide
  save_output "${dir}/events.txt" "events" get events --sort-by=.lastTimestamp
  save_list "${dir}/configmaps.yaml" "ConfigMaps" get configmap
  save_list "${dir}/pvcs.yaml" "PVCs" get pvc
  save_list "${dir}/services.yaml" "Services" get svc

  if resource_available "ingresses.networking.k8s.io"; then
    save_list "${dir}/ingresses.yaml" "Ingresses" get ingresses.networking.k8s.io
  fi
  if resource_available "routes.route.openshift.io"; then
    save_list "${dir}/routes.yaml" "Routes" get routes.route.openshift.io
  fi
}

# ============================================================================
# Detection report
# ============================================================================

write_detection_report() {
  local report="${OUTPUT_DIR}/detection.txt"

  {
    echo "Run:AI Workload Detection Report"
    echo "================================"
    echo ""
    echo "generated       : $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "script version  : ${VERSION}"
    echo "cli             : ${KUBECTL_CMD}"
    echo ""
    echo "project         : ${PROJECT}"
    echo "namespace       : ${NAMESPACE}"
    echo "workload        : ${WORKLOAD}"
    echo ""
    echo "architecture    : ${ARCHITECTURE} (${ARCHITECTURE_LABEL})"
    echo "workload type   : ${WORKLOAD_TYPE}"
    echo "top-level CR    : ${ROOT_RESOURCE}/${ROOT_NAME}"
    echo "root kind       : ${ROOT_KIND}"
    [[ -n "$TEMPLATE_GVK" ]] && echo "runs template   : ${TEMPLATE_GVK}"
    [[ -n "$CONVERTED_FROM_NATIVE" ]] && echo "converted       : ${CONVERTED_FROM_NATIVE}"
    echo "workloadId      : ${WORKLOAD_ID:-<none>}"
    echo "uid             : ${ROOT_UID:-<none>}"
    echo ""

    if [[ -n "$DETECTION_NOTES" ]]; then
      echo "notes"
      echo "-----"
      grep . <<< "$DETECTION_NOTES" | sed 's/^/  - /'
      echo ""
    fi

    echo "resource tree (by owner reference)"
    echo "---------------------------------"
    if [[ -n "$TREE_TEXT" ]]; then
      grep . <<< "$TREE_TEXT" | sed 's/^/  /'
    else
      echo "  <not collected>"
    fi
  } > "$report"

  OUTPUT_FILES+=("$report")
}

# ============================================================================
# Main
# ============================================================================

resolve_namespace
load_api_resources
detect_workload

TIMESTAMP=$(date +"%Y_%m_%d-%H_%M")
VERSION_SAFE=$(echo "$VERSION" | tr '.' '_')
OUTPUT_DIR="${PROJECT}_${TYPE_SLUG}_${WORKLOAD}_v${VERSION_SAFE}_${TIMESTAMP}"
ARCHIVE="${OUTPUT_DIR}.tar.gz"

rm -rf "$OUTPUT_DIR" 2>/dev/null
mkdir -p "$OUTPUT_DIR"

discover_child_resources

echo "📁 Starting collection process..."
echo ""

collect_workload_resources
echo ""

echo "  🐳 Collecting pods..."
collect_pods "$(collect_pod_names)"
echo ""

echo "  🌐 Collecting namespace context..."
collect_namespace_context
echo ""

write_detection_report

echo "📊 Collection Summary:"
echo "  Workload type : ${WORKLOAD_TYPE}"
echo "  Architecture  : ${ARCHITECTURE_LABEL}"
echo "  Total files   : ${#OUTPUT_FILES[@]}"

if [[ ${#OUTPUT_FILES[@]} -le 1 ]]; then
  echo "  ⚠️  Nothing but the detection report was collected."
  echo "  The workload was found but its resources are not accessible — check your permissions."
fi

echo "  Files collected:"
for file in "${OUTPUT_FILES[@]}"; do
  echo "    - ${file#${OUTPUT_DIR}/}"
done

echo ""
echo "📦 Creating archive..."
if tar -czf "$ARCHIVE" "$OUTPUT_DIR" 2>/dev/null; then
  echo "  ✅ Archive created: $ARCHIVE"
  rm -rf "$OUTPUT_DIR"
  echo "✅ Cleanup completed. Only archive remains: $ARCHIVE"
else
  echo "  ❌ Failed to create archive. Collected files preserved in: $OUTPUT_DIR"
  exit 1
fi
