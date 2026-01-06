#!/bin/bash

# GPU Operator Log Collection Script
VERSION="1.1.0"

# Global variable to store the kubectl command (kubectl or oc)
KUBECTL_CMD=""

# Function to detect if this is an OpenShift cluster and set appropriate CLI
detect_k8s_cli() {
  # First check if oc command is available
  if command -v "oc" &> /dev/null; then
    # Try to detect OpenShift-specific resources
    if oc api-resources --api-group=config.openshift.io &> /dev/null; then
      echo "✅ OpenShift cluster detected, using 'oc'"
      KUBECTL_CMD="oc"
      return 0
    fi
    
    # Alternative check: look for OpenShift-specific API groups
    if oc api-versions | grep -q "config.openshift.io\|operator.openshift.io\|route.openshift.io" 2>/dev/null; then
      echo "✅ OpenShift cluster detected, using 'oc'"
      KUBECTL_CMD="oc"
      return 0
    fi
  fi
  
  # If oc is not available or OpenShift not detected, check if kubectl works
  if command -v "kubectl" &> /dev/null; then
    # Double-check by trying to detect OpenShift APIs with kubectl
    if kubectl api-versions | grep -q "config.openshift.io\|operator.openshift.io\|route.openshift.io" 2>/dev/null; then
      echo "✅ OpenShift cluster detected (using kubectl)"
      KUBECTL_CMD="kubectl"
      return 0
    fi
    
    echo "✅ Standard Kubernetes cluster detected, using 'kubectl'"
    KUBECTL_CMD="kubectl"
    return 0
  fi
  
  echo "❌ Error: Neither 'kubectl' nor 'oc' command found."
  echo "Please install one of them and ensure it's accessible in PATH"
  exit 1
}

# Function to execute kubectl/oc commands
k8s_cmd() {
  $KUBECTL_CMD "$@"
}

# Detect cluster type and set appropriate CLI command
detect_k8s_cli

# Test cluster connectivity
if ! k8s_cmd cluster-info &> /dev/null; then
    echo "❌ Error: $KUBECTL_CMD cannot connect to cluster"
    echo "Please check your kubeconfig and cluster connectivity"
    exit 1
fi
echo "✅ $KUBECTL_CMD can connect to cluster"
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
echo "Collecting GPU Operator resources..."
k8s_cmd get all -n gpu-operator -o wide > gpu-operator-resources.txt 2>&1
k8s_cmd get all -n gpu-operator -o yaml > gpu-operator-resources.yaml 2>&1
k8s_cmd describe all -n gpu-operator > gpu-operator-describe.txt 2>&1

# Collect logs from all GPU Operator pods
echo "Collecting pod logs..."
pod_count=0
for pod in $(k8s_cmd get pods -n gpu-operator --no-headers | awk '{print $1}'); do
    echo "  - Collecting logs for pod: $pod"
    
    # Current logs
    k8s_cmd logs -n gpu-operator $pod --all-containers=true --tail=2000 > "${pod}.log" 2>&1
    
    # Previous logs (if pod restarted)
    k8s_cmd logs -n gpu-operator $pod --previous --all-containers=true --tail=2000 > "${pod}-previous.log" 2>/dev/null || echo "No previous logs available" > "${pod}-previous.log"
    
    # Pod description
    k8s_cmd describe pod -n gpu-operator $pod > "${pod}-describe.txt" 2>&1
    
    ((pod_count++))
done

echo "Collected logs from $pod_count pods"

# Collect events
echo "Collecting events..."
k8s_cmd get events -n gpu-operator --sort-by='.lastTimestamp' > gpu-operator-events.txt 2>&1
k8s_cmd get events --all-namespaces --field-selector reason=Failed > cluster-failed-events.txt 2>&1
k8s_cmd get events --all-namespaces | grep -i gpu > gpu-related-events.txt 2>&1

# Collect GPU-specific node information
echo "Collecting GPU node information..."
k8s_cmd get nodes -l nvidia.com/gpu.present=true -o wide > gpu-nodes.txt 2>&1
k8s_cmd describe nodes -l nvidia.com/gpu.present=true > gpu-nodes-describe.txt 2>&1

# Collect custom resources
echo "Collecting custom resources..."
k8s_cmd get clusterpolicies -o yaml > clusterpolicies.yaml 2>/dev/null || echo "No ClusterPolicies found" > clusterpolicies.yaml
k8s_cmd get nodefeatures -o yaml > nodefeatures.yaml 2>/dev/null || echo "No NodeFeatures found" > nodefeatures.yaml

# Collect GPU Operator configuration
echo "Collecting GPU Operator configuration..."
k8s_cmd get configmaps -n gpu-operator -o yaml > gpu-operator-configmaps.yaml 2>&1
k8s_cmd get secrets -n gpu-operator > gpu-operator-secrets.txt 2>&1
k8s_cmd get daemonsets -n gpu-operator -o yaml > gpu-operator-daemonsets.yaml 2>&1

# Collect GPU Operator Helm values
echo "Collecting GPU Operator Helm values..."
GPU_OPERATOR_RELEASE_NAME=$(helm -n gpu-operator ls -o json | jq -r '.[].name' 2>/dev/null)
if [ -n "$GPU_OPERATOR_RELEASE_NAME" ]; then
    helm -n gpu-operator get values $GPU_OPERATOR_RELEASE_NAME > gpu_operator_helm_values.yaml 2>&1
    echo "  - Collected Helm values for release: $GPU_OPERATOR_RELEASE_NAME"
else
    echo "  - No Helm release found in gpu-operator namespace" > gpu_operator_helm_values.yaml
fi

# Create a summary file
echo "Creating summary..."
cat > collection-summary.txt << EOF
GPU Operator Log Collection Summary
==================================
Collection Date: $(date)
Collection Directory: $LOG_DIR
Archive Name: $ARCHIVE_NAME

Files Collected:
$(ls -la | tail -n +2)

Pod Count: $pod_count

Cluster Info:
$(k8s_cmd cluster-info 2>/dev/null | head -5)

GPU Nodes:
$(k8s_cmd get nodes -l nvidia.com/gpu.present=true --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')

GPU Operator Pods Status:
$(k8s_cmd get pods -n gpu-operator --no-headers 2>/dev/null)
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

