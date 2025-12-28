#!/bin/bash

# Global variable to store the kubectl command (kubectl or oc)
KUBECTL_CMD=""

# Function to check if a command exists
check_command() {
  local cmd=$1
  if ! command -v "$cmd" &> /dev/null; then
    echo "ERROR: '$cmd' command not found. Please install $cmd and try again."
    exit 1
  fi
}

# Function to detect if this is an OpenShift cluster
detect_openshift() {
  echo "Detecting cluster type..."
  
  # First check if oc command is available
  if command -v "oc" &> /dev/null; then
    # Try to detect OpenShift-specific resources
    if oc api-resources --api-group=config.openshift.io &> /dev/null; then
      echo "✓ OpenShift cluster detected"
      KUBECTL_CMD="oc"
      return 0
    fi
    
    # Alternative check: look for OpenShift-specific API groups
    if oc api-versions | grep -q "config.openshift.io\|operator.openshift.io\|route.openshift.io" 2>/dev/null; then
      echo "✓ OpenShift cluster detected"
      KUBECTL_CMD="oc"
      return 0
    fi
  fi
  
  # If oc is not available or OpenShift not detected, check if kubectl works
  if command -v "kubectl" &> /dev/null; then
    # Double-check by trying to detect OpenShift APIs with kubectl
    if kubectl api-versions | grep -q "config.openshift.io\|operator.openshift.io\|route.openshift.io" 2>/dev/null; then
      echo "✓ OpenShift cluster detected (using kubectl)"
      KUBECTL_CMD="kubectl"
      return 0
    fi
    
    echo "✓ Standard Kubernetes cluster detected"
    KUBECTL_CMD="kubectl"
    return 0
  fi
  
  echo "ERROR: Neither 'kubectl' nor 'oc' command found. Please install one of them and try again."
  exit 1
}

# Function to execute kubectl/oc commands
k8s_cmd() {
  $KUBECTL_CMD "$@"
}

# Function to collect logs for a given namespace and output directory
collect_logs() {
  local NAMESPACE=$1
  local LOG_DIR=$2
  local LOGS_SUBDIR="$LOG_DIR/logs"
  mkdir -p "$LOGS_SUBDIR"
  
  echo "  Collecting pod information for namespace: $NAMESPACE"
  PODS=$(k8s_cmd get pods -n $NAMESPACE -o jsonpath='{.items[*].metadata.name}')
  
  if [ -z "$PODS" ]; then
    echo "  No pods found in namespace: $NAMESPACE"
    return
  fi
  
  echo "  Found $(echo $PODS | wc -w) pods in namespace: $NAMESPACE"
  
  for POD in $PODS; do
    echo "  Processing pod: $POD"
    
    # Collect pod description
    DESCRIBE_FILE="$LOGS_SUBDIR/${POD}_describe.txt"
    echo "    Collecting pod description for: $POD"
    k8s_cmd describe pod $POD -n $NAMESPACE > "$DESCRIBE_FILE" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "      ✓ Pod description saved to: $DESCRIBE_FILE"
    else
      echo "      ⚠ Warning: Failed to collect pod description for: $POD"
    fi
    
    # Get regular containers
    CONTAINERS=$(k8s_cmd get pod $POD -n $NAMESPACE -o jsonpath='{.spec.containers[*].name}')
    echo "    Regular containers found: $(echo $CONTAINERS | wc -w)"
    
    # Get init containers
    INIT_CONTAINERS=$(k8s_cmd get pod $POD -n $NAMESPACE -o jsonpath='{.spec.initContainers[*].name}')
    echo "    Init containers found: $(echo $INIT_CONTAINERS | wc -w)"
    
    # Collect logs for regular containers
    for CONTAINER in $CONTAINERS; do
      LOG_FILE="$LOGS_SUBDIR/${POD}_${CONTAINER}.log"
      echo "    Collecting logs for Pod: $POD, Container: $CONTAINER"
      k8s_cmd logs --timestamps $POD -c $CONTAINER -n $NAMESPACE > "$LOG_FILE" 2>/dev/null
      if [ $? -eq 0 ]; then
        echo "      ✓ Logs saved to: $LOG_FILE"
      else
        echo "      ⚠ Warning: Failed to collect logs for container: $CONTAINER"
      fi
    done
    
    # Collect logs for init containers
    for CONTAINER in $INIT_CONTAINERS; do
      LOG_FILE="$LOGS_SUBDIR/${POD}_${CONTAINER}_init.log"
      echo "    Collecting logs for Pod: $POD, Init Container: $CONTAINER"
      k8s_cmd logs --timestamps $POD -c $CONTAINER -n $NAMESPACE > "$LOG_FILE" 2>/dev/null
      if [ $? -eq 0 ]; then
        echo "      ✓ Init container logs saved to: $LOG_FILE"
      else
        echo "      ⚠ Warning: Failed to collect logs for init container: $CONTAINER"
      fi
    done
  done
}

# Function to dump scheduler resources
dump_scheduler_resource() {
  local resource_type=$1
  local resource_singular=$2
  local output_dir=$3
  
  echo "  Dumping ${resource_type}..."
  k8s_cmd get ${resource_type} > "${output_dir}/${resource_type}_list.txt" 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "    ✓ ${resource_type} list saved"
  else
    echo "    ⚠ Warning: Failed to collect ${resource_type} list"
    return
  fi
  
  # Extract individual manifests
  echo "  Extracting individual ${resource_type} manifests..."
  k8s_cmd get ${resource_type} --no-headers -o custom-columns=":metadata.name" 2>/dev/null | while read resource; do
    if [ -n "$resource" ]; then
      k8s_cmd get ${resource_type} "$resource" -o yaml > "${output_dir}/${resource_singular}_${resource}.yaml" 2>/dev/null
      echo "    - Extracted ${resource_singular}: $resource"
    fi
  done
}

# Function to collect scheduler information
collect_scheduler_info() {
  local LOG_DIR=$1
  local SCHEDULER_DIR="$LOG_DIR/scheduler"
  mkdir -p "$SCHEDULER_DIR"
  
  echo "=== Collecting Scheduler Resources ==="
  dump_scheduler_resource "projects.run.ai" "project" "$SCHEDULER_DIR"
  dump_scheduler_resource "queues.scheduling.run.ai" "queue" "$SCHEDULER_DIR"
  dump_scheduler_resource "nodepools.run.ai" "nodepool" "$SCHEDULER_DIR"
  dump_scheduler_resource "departments.scheduling.run.ai" "department" "$SCHEDULER_DIR"
  echo "  ✓ Scheduler resources collection completed"
}

# Detect cluster type and set appropriate command
detect_openshift

# Check for required tools
echo "Checking for required tools..."
echo "✓ Kubernetes CLI: $KUBECTL_CMD"
check_command "helm"
echo "✓ All required tools are available"
echo ""

# Namespaces to check
NAMESPACES=("runai-backend" "runai" "knative-serving" "knative-operator" "runai-reservation")

echo "Extracting cluster information..."
CLUSTER_URL=$(k8s_cmd -n runai get runaiconfig runai -o jsonpath='{.spec.__internal.global.clusterURL}' 2>/dev/null)
CP_URL=$(k8s_cmd -n runai get runaiconfig runai -o jsonpath='{.spec.__internal.global.controlPlane.url}' 2>/dev/null)

if [ -z "$CLUSTER_URL" ]; then
  echo "⚠ Warning: Could not extract Cluster URL"
  CLUSTER_URL="unknown"
fi

if [ -z "$CP_URL" ]; then
  echo "⚠ Warning: Could not extract Control Plane URL"
  CP_URL="unknown"
fi

CP_NAME_CLEAN=$(echo "$CP_URL" | sed 's/https:\/\///; s/\./-/g')

echo "Cluster URL: $CLUSTER_URL"
echo "Control Plane URL: $CP_URL"
echo "Control Plane Name (cleaned): $CP_NAME_CLEAN"
echo "=========================================="

for NAMESPACE in "${NAMESPACES[@]}"; do
  echo ""
  echo "Processing namespace: $NAMESPACE"
  echo "----------------------------------------"
  
  # Check namespace existence before any operations
  echo "Checking if namespace '$NAMESPACE' exists..."
  k8s_cmd get namespace "$NAMESPACE" >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "❌ Namespace '$NAMESPACE' does not exist. Skipping."
    continue
  fi

  echo "✓ Namespace '$NAMESPACE' exists. Starting log collection..."
  
  TIMESTAMP=$(date +%d-%m-%Y_%H-%M)
  LOG_NAME="$CP_NAME_CLEAN-$NAMESPACE-logs-$TIMESTAMP"
  LOG_DIR="./$LOG_NAME"
  mkdir $LOG_DIR
  SCRIPT_LOG="$LOG_DIR/script.log"
  LOG_ARCHIVE_NAME="$LOG_NAME.tar.gz"
  
  echo "Log directory: $LOG_DIR"
  echo "Log archive name: $LOG_ARCHIVE_NAME"
  echo "Script log: $SCRIPT_LOG"
  echo ""

  # Start logging all output for this namespace to script.log
  {
    echo "=== Log Collection Started at $(date) ==="
    echo "Namespace: $NAMESPACE"
    echo "Cluster URL: $CLUSTER_URL"
    echo "Control Plane URL: $CP_URL"
    echo ""
    
    # Collect logs into logs subdirectory
    echo "=== Collecting Pod Logs ==="
    collect_logs $NAMESPACE $LOG_DIR
    echo ""

    # Collect extra info per namespace
    echo "=== Collecting Additional Information ==="
    if [ "$NAMESPACE" == "runai" ]; then
      echo "Collecting Helm charts list..."
      helm ls -A > "$LOG_DIR/helm_charts_list.txt" 2>/dev/null
      echo "  ✓ Helm charts list saved"
      
      echo "Collecting Helm values for runai-cluster..."
      helm -n runai get values runai-cluster > "$LOG_DIR/helm-values_runai-cluster.yaml" 2>/dev/null
      echo "  ✓ Helm values saved"
      
      echo "Collecting ConfigMap runai-public..."
      k8s_cmd -n runai get cm runai-public -o yaml > "$LOG_DIR/cm_runai-public.yaml" 2>/dev/null
      echo "  ✓ ConfigMap runai-public saved"
      
      echo "Collecting all ConfigMaps..."
      k8s_cmd -n runai get cm -o yaml > "$LOG_DIR/configmaps_runai.yaml" 2>/dev/null
      echo "  ✓ All ConfigMaps saved"
      
      echo "Collecting all Secrets..."
      k8s_cmd -n runai get secrets -o yaml > "$LOG_DIR/secrets_runai.yaml" 2>/dev/null
      echo "  ✓ All Secrets saved"
      
      echo "Collecting pod list for runai namespace..."
      k8s_cmd -n runai get pods -o wide > "$LOG_DIR/pod-list_runai.txt" 2>/dev/null
      echo "  ✓ Pod list saved"
      
      echo "Collecting node list..."
      k8s_cmd get nodes -o wide > "$LOG_DIR/node-list.txt" 2>/dev/null
      echo "  ✓ Node list saved"
      
      echo "Collecting detailed node information..."
      k8s_cmd get nodes "-o=custom-columns=NAME:.metadata.name,CPUs:.status.capacity.cpu,RAM:.status.capacity.memory,GPU-cap:.status.capacity.nvidia\.com\/gpu,GPU-aloc:.status.allocatable.nvidia\.com\/gpu,GPU-type:.metadata.labels.nvidia\.com\/gpu\.product,OS:.status.nodeInfo.osImage,K8S:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion" > "$LOG_DIR/node-list-detailed.txt" 2>/dev/null
      echo "  ✓ Detailed node information saved"
      
      echo "Collecting RunAI config..."
      k8s_cmd -n runai get runaiconfig runai -o yaml > "$LOG_DIR/runaiconfig.yaml" 2>/dev/null
      echo "  ✓ RunAI config saved"
      
      echo "Collecting engine config..."
      k8s_cmd -n runai get configs.engine.run.ai engine-config -o yaml > "$LOG_DIR/engine-config.yaml" 2>/dev/null
      echo "  ✓ Engine config saved"
      
      # Collect scheduler info for runai namespace
      echo ""
      collect_scheduler_info $LOG_DIR
      
    elif [ "$NAMESPACE" == "runai-backend" ]; then
      echo "Collecting pod list for runai-backend namespace..."
      k8s_cmd -n runai-backend get pods -o wide > "$LOG_DIR/pod-list_runai-backend.txt" 2>/dev/null
      echo "  ✓ Pod list saved"
      
      echo "Collecting Helm values for runai-backend..."
      helm -n runai-backend get values runai-backend > "$LOG_DIR/helm-values_runai-backend.yaml" 2>/dev/null
      echo "  ✓ Helm values saved"
      
      echo "Collecting all ConfigMaps..."
      k8s_cmd -n runai-backend get cm -o yaml > "$LOG_DIR/configmaps_runai-backend.yaml" 2>/dev/null
      echo "  ✓ All ConfigMaps saved"
      
      echo "Collecting all Secrets..."
      k8s_cmd -n runai-backend get secrets -o yaml > "$LOG_DIR/secrets_runai-backend.yaml" 2>/dev/null
      echo "  ✓ All Secrets saved"
      
    elif [ "$NAMESPACE" == "knative-serving" ]; then
      echo "Collecting pod list for knative-serving namespace..."
      k8s_cmd -n knative-serving get pods -o wide > "$LOG_DIR/pod-list_knative-serving.txt" 2>/dev/null
      echo "  ✓ Pod list saved"
      
      echo "Collecting all ConfigMaps..."
      k8s_cmd -n knative-serving get cm -o yaml > "$LOG_DIR/configmaps_knative-serving.yaml" 2>/dev/null
      echo "  ✓ ConfigMaps saved"
      
      echo "Collecting all Secrets..."
      k8s_cmd -n knative-serving get secrets -o yaml > "$LOG_DIR/secrets_knative-serving.yaml" 2>/dev/null
      echo "  ✓ Secrets saved"
      
      echo "Collecting KnativeServing object..."
      k8s_cmd -n knative-serving get knativeserving knative-serving -o yaml > "$LOG_DIR/knativeserving.yaml" 2>/dev/null
      if [ $? -eq 0 ]; then
        echo "  ✓ KnativeServing object saved"
      else
        echo "  ⚠ Warning: Could not retrieve KnativeServing object (may not exist or have different name)"
        # Try to get any knativeserving objects
        k8s_cmd -n knative-serving get knativeserving -o yaml > "$LOG_DIR/knativeserving_all.yaml" 2>/dev/null
      fi
      
      echo "Collecting Knative Services..."
      k8s_cmd -n knative-serving get services.serving.knative.dev -o yaml > "$LOG_DIR/knative-services.yaml" 2>/dev/null
      echo "  ✓ Knative Services saved"
      
      echo "Collecting Knative Revisions..."
      k8s_cmd -n knative-serving get revisions.serving.knative.dev -o yaml > "$LOG_DIR/knative-revisions.yaml" 2>/dev/null
      echo "  ✓ Knative Revisions saved"
      
      echo "Collecting Knative Routes..."
      k8s_cmd -n knative-serving get routes.serving.knative.dev -o yaml > "$LOG_DIR/knative-routes.yaml" 2>/dev/null
      echo "  ✓ Knative Routes saved"
      
      echo "Collecting Knative Configurations..."
      k8s_cmd -n knative-serving get configurations.serving.knative.dev -o yaml > "$LOG_DIR/knative-configurations.yaml" 2>/dev/null
      echo "  ✓ Knative Configurations saved"
      
      echo "Collecting DomainMappings..."
      k8s_cmd -n knative-serving get domainmappings.serving.knative.dev -o yaml > "$LOG_DIR/knative-domainmappings.yaml" 2>/dev/null
      echo "  ✓ DomainMappings saved"
      
      echo "Collecting namespace events..."
      k8s_cmd -n knative-serving get events --sort-by='.lastTimestamp' > "$LOG_DIR/events_knative-serving.txt" 2>/dev/null
      echo "  ✓ Events saved"
      
      echo "Collecting Knative Webhook Configurations..."
      # Get mutating webhook configurations with knative in the name
      MUTATING_WEBHOOKS=$(k8s_cmd get mutatingwebhookconfigurations -o name 2>/dev/null | grep -i knative)
      if [ -n "$MUTATING_WEBHOOKS" ]; then
        echo "$MUTATING_WEBHOOKS" | while read webhook; do
          k8s_cmd get "$webhook" -o yaml >> "$LOG_DIR/mutatingwebhooks_knative.yaml" 2>/dev/null
          echo "---" >> "$LOG_DIR/mutatingwebhooks_knative.yaml"
        done
        echo "  ✓ Mutating Webhook Configurations saved"
      else
        echo "  ⚠ No Knative Mutating Webhook Configurations found"
      fi
      
      # Get validating webhook configurations with knative in the name
      VALIDATING_WEBHOOKS=$(k8s_cmd get validatingwebhookconfigurations -o name 2>/dev/null | grep -i knative)
      if [ -n "$VALIDATING_WEBHOOKS" ]; then
        echo "$VALIDATING_WEBHOOKS" | while read webhook; do
          k8s_cmd get "$webhook" -o yaml >> "$LOG_DIR/validatingwebhooks_knative.yaml" 2>/dev/null
          echo "---" >> "$LOG_DIR/validatingwebhooks_knative.yaml"
        done
        echo "  ✓ Validating Webhook Configurations saved"
      else
        echo "  ⚠ No Knative Validating Webhook Configurations found"
      fi
      
    elif [ "$NAMESPACE" == "knative-operator" ]; then
      echo "Collecting pod list for knative-operator namespace..."
      k8s_cmd -n knative-operator get pods -o wide > "$LOG_DIR/pod-list_knative-operator.txt" 2>/dev/null
      echo "  ✓ Pod list saved"
      
      echo "Collecting all ConfigMaps..."
      k8s_cmd -n knative-operator get cm -o yaml > "$LOG_DIR/configmaps_knative-operator.yaml" 2>/dev/null
      echo "  ✓ ConfigMaps saved"
      
      echo "Collecting all Secrets..."
      k8s_cmd -n knative-operator get secrets -o yaml > "$LOG_DIR/secrets_knative-operator.yaml" 2>/dev/null
      echo "  ✓ Secrets saved"
      
      echo "Collecting namespace events..."
      k8s_cmd -n knative-operator get events --sort-by='.lastTimestamp' > "$LOG_DIR/events_knative-operator.txt" 2>/dev/null
      echo "  ✓ Events saved"
      
    elif [ "$NAMESPACE" == "runai-reservation" ]; then
      echo "Collecting pod list for runai-reservation namespace..."
      k8s_cmd -n runai-reservation get pods -o wide > "$LOG_DIR/pod-list_runai-reservation.txt" 2>/dev/null
      echo "  ✓ Pod list saved"
      
      echo "Collecting all ConfigMaps..."
      k8s_cmd -n runai-reservation get cm -o yaml > "$LOG_DIR/configmaps_runai-reservation.yaml" 2>/dev/null
      echo "  ✓ ConfigMaps saved"
      
      echo "Collecting all Secrets..."
      k8s_cmd -n runai-reservation get secrets -o yaml > "$LOG_DIR/secrets_runai-reservation.yaml" 2>/dev/null
      echo "  ✓ Secrets saved"
      
      echo "Collecting all Services..."
      k8s_cmd -n runai-reservation get svc -o yaml > "$LOG_DIR/services_runai-reservation.yaml" 2>/dev/null
      echo "  ✓ Services saved"
      
      echo "Collecting all Deployments..."
      k8s_cmd -n runai-reservation get deployments -o yaml > "$LOG_DIR/deployments_runai-reservation.yaml" 2>/dev/null
      echo "  ✓ Deployments saved"
      
      echo "Collecting all StatefulSets..."
      k8s_cmd -n runai-reservation get statefulsets -o yaml > "$LOG_DIR/statefulsets_runai-reservation.yaml" 2>/dev/null
      echo "  ✓ StatefulSets saved"
      
      echo "Collecting all DaemonSets..."
      k8s_cmd -n runai-reservation get daemonsets -o yaml > "$LOG_DIR/daemonsets_runai-reservation.yaml" 2>/dev/null
      echo "  ✓ DaemonSets saved"
      
      echo "Collecting all PersistentVolumeClaims..."
      k8s_cmd -n runai-reservation get pvc -o yaml > "$LOG_DIR/pvcs_runai-reservation.yaml" 2>/dev/null
      echo "  ✓ PersistentVolumeClaims saved"
      
      echo "Collecting namespace events..."
      k8s_cmd -n runai-reservation get events --sort-by='.lastTimestamp' > "$LOG_DIR/events_runai-reservation.txt" 2>/dev/null
      echo "  ✓ Events saved"
    fi

    echo ""
    echo "=== Creating Archive ==="
    echo "Calculating directory size..."
    du -hs $LOG_DIR
    
    echo "Creating tar archive..."
    tar cvzf $LOG_ARCHIVE_NAME $LOG_DIR
    echo "  ✓ Archive created"
    
    echo "Archive details:"
    ls -lah $LOG_ARCHIVE_NAME
    
    echo "Cleaning up temporary directory..."
    rm -rf $LOG_DIR
    echo "  ✓ Temporary directory removed"
    
    echo "=== Log Collection Completed at $(date) ==="
    echo "Logs and info archived to $LOG_ARCHIVE_NAME"
    
  } 2>&1 | tee "$SCRIPT_LOG"
  
  echo ""
  echo "✓ Completed processing namespace: $NAMESPACE"
  echo "Archive created: $LOG_ARCHIVE_NAME"
  echo "=========================================="
done

echo ""
echo "🎉 All namespaces processed successfully!"

