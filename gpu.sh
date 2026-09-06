#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# GPU Operator Log Collection Script
VERSION="1.2.1"

# Global variable to store the kubectl command (kubectl or oc)
KUBECTL_CMD=""

# Namespace the GPU Operator is installed in. Left empty so it can be detected
# from the cluster; the Helm chart defaults to "gpu-operator" but the OpenShift
# bundle uses "nvidia-gpu-operator" and the namespace is user-selectable in both.
GPU_NAMESPACE="${GPU_OPERATOR_NAMESPACE:-}"

# Function to detect if this is an OpenShift cluster and set appropriate CLI
detect_k8s_cli() {
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
      echo "✅ OpenShift cluster detected, using 'oc'"
      KUBECTL_CMD="oc"
      return 0
    elif command -v "kubectl" &> /dev/null; then
      echo "✅ OpenShift cluster detected, using 'kubectl'"
      KUBECTL_CMD="kubectl"
      return 0
    fi
  else
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

# Fully qualified names of the resources this cluster serves, one per line.
# Populated once before custom resources are collected.
API_RESOURCE_NAMES=""

# Collect a custom resource by its fully qualified name, recording whether the
# CRD is absent so an empty file cannot be mistaken for "the operator reported
# nothing". Extra arguments are passed to the get, e.g. --all-namespaces.
collect_cr() {
  local fqn=$1 outfile=$2 label=$3
  shift 3

  # Discovery can be unavailable or restricted; probe the server directly in
  # that case rather than reporting a CRD that does exist as missing.
  if [ -z "$fqn" ] || { [ -n "$API_RESOURCE_NAMES" ] && ! grep -qx "$fqn" <<< "$API_RESOURCE_NAMES"; }; then
    echo "$label CRD not present on this cluster" > "$outfile"
    echo "  - $label: CRD not installed"
    return 0
  fi

  if k8s_cmd get "$fqn" "$@" -o yaml > "$outfile" 2>&1; then
    echo "  - $label: collected ($fqn)"
  else
    echo "  - $label: collection failed, see $outfile"
  fi
}

# Function to locate the GPU Operator namespace
detect_gpu_namespace() {
  if [ -n "$GPU_NAMESPACE" ]; then
    # A caller-supplied name reaches kubectl directly, so hold it to the DNS-1123
    # label form Kubernetes namespaces actually use.
    if [[ ! "$GPU_NAMESPACE" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
      echo "❌ Error: Invalid namespace: '$GPU_NAMESPACE'"
      echo "Use lowercase letters, numbers and hyphens; start and end with a letter or number."
      exit 1
    fi
    if ! k8s_cmd get namespace "$GPU_NAMESPACE" &> /dev/null; then
      echo "❌ Error: namespace '$GPU_NAMESPACE' not found"
      exit 1
    fi
    echo "✅ Using GPU Operator namespace: $GPU_NAMESPACE (set explicitly)"
    return 0
  fi

  local candidates=""

  # The operator carries these labels in every install flavour (Helm, OLM,
  # OpenShift), so whichever namespace it lands in is the authoritative answer.
  # Deployments are matched alongside pods because an operator scaled to zero or
  # failing to schedule has no pod, and that is exactly when logs are wanted.
  local selector
  for selector in "app.kubernetes.io/component=gpu-operator" "app=gpu-operator"; do
    candidates=$(k8s_cmd get pods,deployments --all-namespaces -l "$selector" \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)
    [ -n "$candidates" ] && break
  done

  # Installs that rename the operand labels still keep the Deployment name.
  if [ -z "$candidates" ]; then
    candidates=$(k8s_cmd get deployments --all-namespaces \
      --field-selector metadata.name=gpu-operator \
      -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' 2>/dev/null | sort -u)
  fi

  # Last resort for credentials without cluster-wide list permission: probe the
  # namespace names the installers use.
  if [ -z "$candidates" ]; then
    local ns
    for ns in gpu-operator nvidia-gpu-operator gpu-operator-resources; do
      if k8s_cmd get namespace "$ns" &> /dev/null; then
        candidates="$ns"
        break
      fi
    done
  fi

  if [ -z "$candidates" ]; then
    echo "❌ Error: could not find the GPU Operator in this cluster"
    echo "If it is installed under a namespace this script cannot see, pass it explicitly:"
    echo "  $0 -n <namespace>"
    exit 1
  fi

  GPU_NAMESPACE=$(echo "$candidates" | head -n 1)

  if [ "$(echo "$candidates" | wc -l | tr -d ' ')" -gt 1 ]; then
    echo "⚠️  GPU Operator found in multiple namespaces: $(echo "$candidates" | tr '\n' ' ')"
    echo "   Collecting from '$GPU_NAMESPACE'; use -n <namespace> to choose another"
  else
    echo "✅ Detected GPU Operator namespace: $GPU_NAMESPACE"
  fi
}

usage() {
  cat <<EOF
GPU Operator Log Collector v${VERSION}

Usage: $0 [-n <namespace>]

Options:
  -n, --namespace <name>  Namespace the GPU Operator is installed in. Detected
                          from the cluster when omitted. Can also be set with
                          the GPU_OPERATOR_NAMESPACE environment variable.
  -h, --help              Show this help and exit.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -n|--namespace)
      if [ -z "$2" ]; then
        echo "Error: $1 requires a namespace" >&2
        exit 1
      fi
      GPU_NAMESPACE="$2"
      shift
      ;;
    -h|--help)
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

# Detect cluster type and set appropriate CLI command
detect_k8s_cli

# Test cluster connectivity
if ! k8s_cmd cluster-info &> /dev/null; then
    echo "❌ Error: $KUBECTL_CMD cannot connect to cluster"
    echo "Please check your kubeconfig and cluster connectivity"
    exit 1
fi
echo "✅ $KUBECTL_CMD can connect to cluster"

# Resolve the namespace before anything is collected
detect_gpu_namespace
echo ""

# Set up variables
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="gpu-operator-logs-$TIMESTAMP"
ARCHIVE_NAME="${LOG_DIR}.tar.gz"

echo "Creating log collection directory: $LOG_DIR"
mkdir -p $LOG_DIR
cd $LOG_DIR

echo "=== Collecting GPU Operator Logs ==="

# Collect basic cluster information
echo "Collecting cluster information..."
k8s_cmd cluster-info > cluster-info.txt 2>&1
k8s_cmd version > cluster-version.txt 2>&1
k8s_cmd get nodes -o wide > nodes.txt 2>&1

# Collect GPU Operator namespace resources
echo "Collecting GPU Operator resources from namespace: $GPU_NAMESPACE"
k8s_cmd get all -n "$GPU_NAMESPACE" -o wide > gpu-operator-resources.txt 2>&1
k8s_cmd get all -n "$GPU_NAMESPACE" -o yaml > gpu-operator-resources.yaml 2>&1
k8s_cmd describe all -n "$GPU_NAMESPACE" > gpu-operator-describe.txt 2>&1

# Collect logs from all GPU Operator pods
echo "Collecting pod logs..."
pod_count=0
for pod in $(k8s_cmd get pods -n "$GPU_NAMESPACE" --no-headers | awk '{print $1}'); do
    echo "  - Collecting logs for pod: $pod"
    
    # Current logs
    k8s_cmd logs -n "$GPU_NAMESPACE" $pod --all-containers=true --tail=2000 > "${pod}.log" 2>&1
    
    # Previous logs (if pod restarted)
    k8s_cmd logs -n "$GPU_NAMESPACE" $pod --previous --all-containers=true --tail=2000 > "${pod}-previous.log" 2>/dev/null || echo "No previous logs available" > "${pod}-previous.log"
    
    # Pod description
    k8s_cmd describe pod -n "$GPU_NAMESPACE" $pod > "${pod}-describe.txt" 2>&1
    
    ((pod_count++))
done

echo "Collected logs from $pod_count pods"

# Collect events
echo "Collecting events..."
k8s_cmd get events -n "$GPU_NAMESPACE" --sort-by='.lastTimestamp' > gpu-operator-events.txt 2>&1
k8s_cmd get events --all-namespaces --field-selector reason=Failed > cluster-failed-events.txt 2>&1
k8s_cmd get events --all-namespaces | grep -i gpu > gpu-related-events.txt 2>&1

# Collect GPU-specific node information
echo "Collecting GPU node information..."
k8s_cmd get nodes -l nvidia.com/gpu.present=true -o wide > gpu-nodes.txt 2>&1
k8s_cmd describe nodes -l nvidia.com/gpu.present=true > gpu-nodes-describe.txt 2>&1

# Collect custom resources
echo "Collecting custom resources..."
# kubectl resolves a bare plural to whichever API group sorts first, so on a
# cluster running Kyverno "clusterpolicies" returns Kyverno's ClusterPolicy
# objects instead of NVIDIA's. Address these CRs by fully qualified name.
API_RESOURCE_NAMES=$(k8s_cmd api-resources -o name 2>/dev/null)

collect_cr "clusterpolicies.nvidia.com" clusterpolicies.yaml "ClusterPolicy"
collect_cr "nvidiadrivers.nvidia.com" nvidiadrivers.yaml "NVIDIADriver"

# NodeFeature is namespaced, so it needs every namespace searched rather than
# whichever one the kubeconfig happens to point at. Its API group has changed
# between NFD releases, hence resolving it from discovery.
NODEFEATURES_FQN=$(grep -m1 '^nodefeatures\.' <<< "$API_RESOURCE_NAMES")
collect_cr "${NODEFEATURES_FQN:-nodefeatures.nfd.k8s-sigs.io}" nodefeatures.yaml "NodeFeature" --all-namespaces

# Collect GPU Operator configuration
echo "Collecting GPU Operator configuration..."
k8s_cmd get configmaps -n "$GPU_NAMESPACE" -o yaml > gpu-operator-configmaps.yaml 2>&1
k8s_cmd get secrets -n "$GPU_NAMESPACE" > gpu-operator-secrets.txt 2>&1
k8s_cmd get daemonsets -n "$GPU_NAMESPACE" -o yaml > gpu-operator-daemonsets.yaml 2>&1

# Collect GPU Operator Helm values
echo "Collecting GPU Operator Helm values..."
# The release name is arbitrary, so pick the release whose chart is the GPU
# Operator rather than the first release in the namespace.
GPU_OPERATOR_RELEASE_NAME=$(helm -n "$GPU_NAMESPACE" ls -o json 2>/dev/null \
    | jq -r 'first(.[] | select(.chart | startswith("gpu-operator")) | .name) // empty' 2>/dev/null)
if [ -n "$GPU_OPERATOR_RELEASE_NAME" ]; then
    helm -n "$GPU_NAMESPACE" get values $GPU_OPERATOR_RELEASE_NAME > gpu_operator_helm_values.yaml 2>&1
    echo "  - Collected Helm values for release: $GPU_OPERATOR_RELEASE_NAME"
else
    echo "  - No GPU Operator Helm release found in namespace $GPU_NAMESPACE (an OLM/OpenShift install has none)" > gpu_operator_helm_values.yaml
fi

# Create a summary file
echo "Creating summary..."
cat > collection-summary.txt << EOF
GPU Operator Log Collection Summary
==================================
Collection Date: $(date)
Collection Directory: $LOG_DIR
Archive Name: $ARCHIVE_NAME
GPU Operator Namespace: $GPU_NAMESPACE

Files Collected:
$(ls -la | tail -n +2)

Pod Count: $pod_count

Cluster Info:
$(k8s_cmd cluster-info 2>/dev/null | head -5)

GPU Nodes:
$(k8s_cmd get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')

GPU Operator Pods Status:
$(k8s_cmd get pods -n "$GPU_NAMESPACE" --no-headers 2>/dev/null)
EOF

# Go back to parent directory
cd ..

# Create compressed archive
echo "Creating archive: $ARCHIVE_NAME"
tar -czf "$ARCHIVE_NAME" "$LOG_DIR"

# Verify archive creation
if [ -f "$ARCHIVE_NAME" ]; then
    ARCHIVE_SIZE=$(du -h "$ARCHIVE_NAME" | cut -f1)
    echo "✓ Archive created successfully: $ARCHIVE_NAME ($ARCHIVE_SIZE)"
    echo "✓ Archive contents:"
    tar -tzf "$ARCHIVE_NAME" | head -20
    
    # Show total file count
    FILE_COUNT=$(tar -tzf "$ARCHIVE_NAME" | wc -l)
    echo "✓ Total files in archive: $FILE_COUNT"
    
    # Option to clean up directory
    read -p "Do you want to remove the uncompressed directory? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf "$LOG_DIR"
        echo "✓ Cleaned up directory: $LOG_DIR"
    fi
    
    echo ""
    echo "=== Collection Complete ==="
    echo "Archive location: $(pwd)/$ARCHIVE_NAME"
    echo "Archive size: $ARCHIVE_SIZE"
    echo ""
    echo "To extract the archive later:"
    echo "  tar -xzf $ARCHIVE_NAME"
    
else
    echo "✗ Failed to create archive"
    exit 1
fi

