#!/bin/bash

# Workload Info Dump Script
VERSION="1.0.0"

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
  echo "Usage: $0 --project <PROJECT> --workload <WORKLOAD> --type <TYPE>"
  echo "       $0 --version"
  echo ""
  echo "Examples:"
  echo "  $0 --project test --type tw --workload test-train"
  echo "  $0 --project test --type iw --workload test-interactive"
  echo "  $0 --project test --type infw --workload test-inference"
  echo "  $0 --project test --type dinfw --workload test-distributed-inference"
  echo "  $0 --project test --type dw --workload test-distributed-training"
  echo "  $0 --project test --type ew --workload test-external"
  echo ""
  echo "Options:"
  echo "  --version    Show script version and exit"
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
    --type)
      TYPE="$2"
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
if [[ -z "$PROJECT" || -z "$WORKLOAD" || -z "$TYPE" ]]; then
  usage
fi

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
echo "   Enhanced for resilient resource collection with unified pod processing"
echo "   Now supports External Workloads (non-RunAI workloads using RunAI scheduler)"
echo ""

# Function to map type aliases to canonical k8s resource names
get_canonical_type() {
  case "$1" in
    dinfw|distributedinferenceworkloads)
      echo "distributedinferenceworkloads" ;;
    dw|distributedworkloads)
      echo "distributedworkloads" ;;
    ew|externalworkloads)
      echo "externalworkloads" ;;
    infw|inferenceworkloads)
      echo "inferenceworkloads" ;;
    iw|interactiveworkloads)
      echo "interactiveworkloads" ;;
    tw|trainingworkloads)
      echo "trainingworkloads" ;;
    *)
      echo "" ;;
  esac
}

# Function to get workload YAML
get_workload_yaml() {
  local workload="$1"
  local canonical_type="$2"
  local type_safe="$3"
  
  local workload_yaml="${workload}_${type_safe}_workload.yaml"
  echo "  📄 Getting $canonical_type YAML..." >&2
  if k8s_cmd -n "$NAMESPACE" get "$canonical_type" "$workload" -o yaml > "$workload_yaml" 2>/dev/null; then
    echo "    ✅ Workload YAML retrieved" >&2
    echo "$workload_yaml"
  else
    echo "    ❌ Failed to retrieve Workload YAML (resource may not exist or be accessible)" >&2
    return 1
  fi
}

# Function to get RunAIJob YAML
get_runaijob_yaml() {
  local workload="$1"
  local type_safe="$2"
  
  local runaijob_yaml="${workload}_${type_safe}_runaijob.yaml"
  echo "  📄 Getting RunAIJob YAML..." >&2
  if k8s_cmd -n "$NAMESPACE" get rj "$workload" -o yaml > "$runaijob_yaml" 2>/dev/null; then
    # Check if file is empty or contains no valid content
    if [[ ! -s "$runaijob_yaml" ]]; then
      echo "    ❌ RunAIJob resource returned empty content" >&2
      rm -f "$runaijob_yaml" 2>/dev/null
      return 1
    fi
    echo "    ✅ RunAIJob YAML retrieved" >&2
    echo "$runaijob_yaml"
  else
    echo "    ❌ Failed to retrieve RunAIJob YAML (resource may not exist or be accessible)" >&2
    # Clean up empty file if it was created
    rm -f "$runaijob_yaml" 2>/dev/null
    return 1
  fi
}

# Function to get pods and containers information (centralized discovery)
get_pods_and_containers_info() {
  local workload="$1"
  local label_selector="${2:-workloadName=$workload}"  # Allow custom label selector
  
  # Get all pods for this workload in one call
  local pods_json=$(k8s_cmd -n "$NAMESPACE" get pod -l "$label_selector" -o json 2>/dev/null)
  
  if [[ -z "$pods_json" ]] || [[ "$pods_json" == "null" ]]; then
    echo "    ❌ No pods found for workload: $workload (selector: $label_selector)" >&2
    return 1
  fi
  
  # Extract pod names and containers info using jq for efficiency
  if command -v jq &> /dev/null; then
    # Use jq if available for better JSON parsing
    echo "$pods_json" | jq -r '.items[] | "\(.metadata.name)|\([(.spec.initContainers//[])[]?.name, .spec.containers[].name] | join(" "))"'
  else
    # Fallback to k8s_cmd jsonpath if jq is not available
    local pod_names=$(echo "$pods_json" | k8s_cmd get -f - -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    
    for pod in $pod_names; do
      local containers=$(k8s_cmd -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null)
      echo "${pod}|${containers}"
    done
  fi
}

# Unified function to process all pod operations efficiently (OPTIMIZED)
process_pods_unified() {
  local workload="$1"
  local type_safe="$2"
  local pods_info="$3"  # Pre-fetched pod information
  
  echo "  📄 Processing all pod operations..." >&2
  
  if [[ -z "$pods_info" ]]; then
    echo "    ❌ No pod information provided" >&2
    return 1
  fi
  
  local output_files=()
  local total_pods=0
  local total_containers=0
  local total_nvidia_files=0
  
  # Parse pre-fetched pod information and process each pod completely
  while IFS='|' read -r pod containers; do
    [[ -z "$pod" ]] && continue
    ((total_pods++))
    
    echo "    🐳 Processing pod: $pod" >&2
    
    # 1. Get Pod YAML
    local pod_yaml="${workload}_${type_safe}_pod_${pod}.yaml"
    if k8s_cmd -n "$NAMESPACE" get pod "$pod" -o yaml > "$pod_yaml" 2>/dev/null; then
      echo "      ✅ Pod YAML retrieved: $pod" >&2
      output_files+=("$pod_yaml")
    else
      echo "      ❌ Failed to retrieve YAML for pod: $pod" >&2
    fi
    
    # 2. Get Pod Description
    local pod_describe_file="${workload}_${type_safe}_pod_${pod}_describe.txt"
    if k8s_cmd -n "$NAMESPACE" describe pod "$pod" > "$pod_describe_file" 2>/dev/null; then
      echo "      ✅ Pod description retrieved: $pod" >&2
      output_files+=("$pod_describe_file")
    else
      echo "      ❌ Failed to retrieve description for pod: $pod" >&2
    fi
    
    # 3. Process all containers for this pod (logs + nvidia-smi)
    for container in $containers; do
      [[ -z "$container" ]] && continue
      ((total_containers++))
      
      # Get container logs
      local log_file="${workload}_${type_safe}_pod_${pod}_logs_${container}.log"
      if k8s_cmd -n "$NAMESPACE" logs "$pod" -c "$container" > "$log_file" 2>/dev/null; then
        echo "      ✅ Logs retrieved: $container (pod: $pod)" >&2
        output_files+=("$log_file")
      else
        echo "      ⚠️  Failed to retrieve logs: $container (pod: $pod)" >&2
      fi
      
      # Get nvidia-smi output
      local nvidia_file="${workload}_${type_safe}_pod_${pod}_nvidia_smi_${container}.txt"
      if k8s_cmd -n "$NAMESPACE" exec "$pod" -c "$container" -- nvidia-smi > "$nvidia_file" 2>/dev/null; then
        echo "      ✅ nvidia-smi retrieved: $container (pod: $pod)" >&2
        output_files+=("$nvidia_file")
        ((total_nvidia_files++))
      else
        # Clean up empty file if command failed
        rm -f "$nvidia_file" 2>/dev/null
      fi
    done
    
  done <<< "$pods_info"
  
  # Summary output
  if [[ ${#output_files[@]} -gt 0 ]]; then
    echo "    ✅ Pod processing completed:" >&2
    echo "      - ${total_pods} pods processed" >&2
    echo "      - ${total_containers} containers processed" >&2
    echo "      - ${total_nvidia_files} nvidia-smi outputs retrieved" >&2
    echo "      - ${#output_files[@]} total files generated" >&2
    printf '%s\n' "${output_files[@]}"
  else
    echo "    ❌ No pod information was successfully retrieved" >&2
    return 1
  fi
}

# Function to get podgroup YAML
get_podgroup_yaml() {
  local workload="$1"
  local type_safe="$2"
  
  local podgroup_yaml="${workload}_${type_safe}_podgroup.yaml"
  echo "  📄 Getting PodGroup YAML..." >&2
  if k8s_cmd -n "$NAMESPACE" get pg -l workloadName=$workload -o yaml > "$podgroup_yaml" 2>/dev/null; then
    echo "    ✅ PodGroup YAML retrieved" >&2
    echo "$podgroup_yaml"
  else
    echo "    ❌ Failed to retrieve PodGroup YAML (resource may not exist or be accessible)" >&2
    return 1
  fi
}

# Function to get KSVC YAML (for inference workloads)
get_ksvc_yaml() {
  local workload="$1"
  local type_safe="$2"
  
  local ksvc_spec="${workload}_${type_safe}_ksvc.yaml"
  echo "  📄 Getting KSVC YAML..." >&2
  if k8s_cmd -n "$NAMESPACE" get ksvc "$workload" -o yaml > "$ksvc_spec" 2>/dev/null; then
    echo "    ✅ KSVC YAML retrieved" >&2
    echo "$ksvc_spec"
  else
    echo "    ❌ Failed to retrieve KSVC YAML (resource may not exist or be accessible)" >&2
    return 1
  fi
}

# Function to get pod list for all pods in namespace
get_all_pods_list() {
  local workload="$1"
  local type_safe="$2"
  
  local pod_list_file="${workload}_${type_safe}_all_pods_list.txt"
  echo "  📄 Getting pod list for all pods in namespace..." >&2
  if k8s_cmd -n "$NAMESPACE" get pods -o wide > "$pod_list_file" 2>/dev/null; then
    echo "    ✅ Pod list retrieved" >&2
    echo "$pod_list_file"
  else
    echo "    ❌ Failed to retrieve pod list (no pods found or not accessible)" >&2
    return 1
  fi
}

# Function to get all ConfigMaps in namespace
get_all_configmaps() {
  local workload="$1"
  local type_safe="$2"
  
  local configmap_file="${workload}_${type_safe}_all_configmaps.yaml"
  echo "  📄 Getting all ConfigMaps in namespace..." >&2
  if k8s_cmd -n "$NAMESPACE" get configmap -o yaml > "$configmap_file" 2>/dev/null; then
    echo "    ✅ ConfigMaps retrieved" >&2
    echo "$configmap_file"
  else
    echo "    ❌ Failed to retrieve ConfigMaps (no configmaps found or not accessible)" >&2
    return 1
  fi
}

# Function to get all PVCs in namespace
get_all_pvcs() {
  local workload="$1"
  local type_safe="$2"
  
  local pvc_file="${workload}_${type_safe}_all_pvcs.yaml"
  echo "  📄 Getting all PVCs in namespace..." >&2
  if k8s_cmd -n "$NAMESPACE" get pvc -o yaml > "$pvc_file" 2>/dev/null; then
    echo "    ✅ PVCs retrieved" >&2
    echo "$pvc_file"
  else
    echo "    ❌ Failed to retrieve PVCs (no PVCs found or not accessible)" >&2
    return 1
  fi
}

# Function to get all Services in namespace
get_all_services() {
  local workload="$1"
  local type_safe="$2"
  
  local service_file="${workload}_${type_safe}_all_services.yaml"
  echo "  📄 Getting all Services in namespace..." >&2
  if k8s_cmd -n "$NAMESPACE" get svc -o yaml > "$service_file" 2>/dev/null; then
    echo "    ✅ Services retrieved" >&2
    echo "$service_file"
  else
    echo "    ❌ Failed to retrieve Services (no services found or not accessible)" >&2
    return 1
  fi
}

# Function to get all Ingresses in namespace
get_all_ingresses() {
  local workload="$1"
  local type_safe="$2"
  
  local ingress_file="${workload}_${type_safe}_all_ingresses.yaml"
  echo "  📄 Getting all Ingresses in namespace..." >&2
  if k8s_cmd -n "$NAMESPACE" get ingress -o yaml > "$ingress_file" 2>/dev/null; then
    echo "    ✅ Ingresses retrieved" >&2
    echo "$ingress_file"
  else
    echo "    ❌ Failed to retrieve Ingresses (no ingresses found or not accessible)" >&2
    return 1
  fi
}

# Function to get all Routes in namespace (OpenShift)
get_all_routes() {
  local workload="$1"
  local type_safe="$2"
  
  local route_file="${workload}_${type_safe}_all_routes.yaml"
  echo "  📄 Getting all Routes in namespace..." >&2
  if k8s_cmd -n "$NAMESPACE" get route -o yaml > "$route_file" 2>/dev/null; then
    echo "    ✅ Routes retrieved" >&2
    echo "$route_file"
  else
    echo "    ❌ Failed to retrieve Routes (no routes found or not accessible)" >&2
    return 1
  fi
}

# ============================================================================
# External Workload Functions
# ============================================================================

# Function to find the ExternalWorkload CR name for a given workload
# External workloads are named with pattern: ew-<type>-<originalWorkloadName>
find_external_workload_name() {
  local workload="$1"
  
  echo "  🔍 Searching for ExternalWorkload matching '$workload'..." >&2
  
  # First, try to find by the originalWorkloadName in spec
  local ew_name=$(k8s_cmd -n "$NAMESPACE" get externalworkload -o json 2>/dev/null | \
    grep -B 50 "\"originalWorkloadName\": \"$workload\"" | \
    grep "\"name\":" | head -1 | sed 's/.*"name": "\([^"]*\)".*/\1/')
  
  if [[ -n "$ew_name" ]]; then
    echo "    ✅ Found ExternalWorkload: $ew_name" >&2
    echo "$ew_name"
    return 0
  fi
  
  # Fallback: try common naming patterns
  for pattern in "ew-deployment-${workload}" "ew-statefulset-${workload}" "ew-daemonset-${workload}" "ew-${workload}"; do
    if k8s_cmd -n "$NAMESPACE" get externalworkload "$pattern" &>/dev/null; then
      echo "    ✅ Found ExternalWorkload: $pattern" >&2
      echo "$pattern"
      return 0
    fi
  done
  
  echo "    ❌ No ExternalWorkload found for: $workload" >&2
  return 1
}

# Function to extract owner resource info from ExternalWorkload
get_external_workload_owner_info() {
  local ew_name="$1"
  
  echo "  🔍 Extracting owner resource info from ExternalWorkload..." >&2
  
  # Get the ExternalWorkload YAML to extract owner info
  local ew_yaml=$(k8s_cmd -n "$NAMESPACE" get externalworkload "$ew_name" -o yaml 2>/dev/null)
  
  if [[ -z "$ew_yaml" ]]; then
    echo "    ❌ Failed to retrieve ExternalWorkload YAML" >&2
    return 1
  fi
  
  # Extract owner reference information using grep/sed
  local owner_kind=$(echo "$ew_yaml" | grep -A 10 "ownerReferences:" | grep "kind:" | head -1 | sed 's/.*kind: \(.*\)/\1/' | tr -d '[:space:]')
  local owner_name=$(echo "$ew_yaml" | grep -A 10 "ownerReferences:" | grep "name:" | head -1 | sed 's/.*name: \(.*\)/\1/' | tr -d '[:space:]')
  local owner_uid=$(echo "$ew_yaml" | grep -A 10 "ownerReferences:" | grep "uid:" | head -1 | sed 's/.*uid: \(.*\)/\1/' | tr -d '[:space:]')
  
  # Fallback: try spec.type and spec.originalWorkloadName if ownerReferences not found
  if [[ -z "$owner_kind" ]] || [[ -z "$owner_name" ]]; then
    owner_kind=$(echo "$ew_yaml" | grep "^  type:" | head -1 | sed 's/.*type: \(.*\)/\1/' | tr -d '[:space:]')
    owner_name=$(echo "$ew_yaml" | grep "^  originalWorkloadName:" | head -1 | sed 's/.*originalWorkloadName: \(.*\)/\1/' | tr -d '[:space:]')
    owner_uid=$(echo "$ew_yaml" | grep "^  originalWorkloadUID:" | head -1 | sed 's/.*originalWorkloadUID: \(.*\)/\1/' | tr -d '[:space:]')
  fi
  
  if [[ -z "$owner_kind" ]] || [[ -z "$owner_name" ]]; then
    echo "    ❌ Failed to extract owner resource info" >&2
    return 1
  fi
  
  echo "    ✅ Owner: $owner_kind/$owner_name (UID: $owner_uid)" >&2
  
  # Return format: kind|name|uid
  echo "${owner_kind}|${owner_name}|${owner_uid}"
}

# Function to get owner resource YAML for external workload
get_external_workload_owner_yaml() {
  local workload="$1"
  local type_safe="$2"
  local owner_kind="$3"
  local owner_name="$4"
  
  # Convert kind to lowercase for kubectl command
  local resource_type=$(echo "$owner_kind" | tr '[:upper:]' '[:lower:]')
  
  local owner_yaml="${workload}_${type_safe}_owner_${resource_type}_${owner_name}.yaml"
  echo "  📄 Getting owner resource YAML ($owner_kind/$owner_name)..." >&2
  
  if k8s_cmd -n "$NAMESPACE" get "$resource_type" "$owner_name" -o yaml > "$owner_yaml" 2>/dev/null; then
    echo "    ✅ Owner resource YAML retrieved" >&2
    echo "$owner_yaml"
  else
    echo "    ❌ Failed to retrieve owner resource YAML" >&2
    return 1
  fi
}

# Arguments have already been parsed and validated above

# Lookup namespace from project
NAMESPACE=$(k8s_cmd get ns -l runai/queue="$PROJECT" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$NAMESPACE" ]]; then
  echo "❌ No namespace found for project: $PROJECT"
  echo "Please check that the project exists and is accessible"
  exit 1
fi

echo "Collecting info dump for workload '$WORKLOAD' ($TYPE) in project $PROJECT"
echo ""

# Validate type
CANONICAL_TYPE=$(get_canonical_type "$TYPE")
if [[ -z "$CANONICAL_TYPE" ]]; then
  echo "Invalid type: $TYPE"
  usage
fi

# Output file names
TYPE_SAFE=$(echo "$TYPE" | tr '/' '_')
OUTPUT_FILES=()

# Add timestamp and version for archive
TIMESTAMP=$(date +"%Y_%m_%d-%H_%M")
VERSION_SAFE=$(echo "$VERSION" | tr '.' '_')
ARCHIVE="${PROJECT}_${TYPE_SAFE}_${WORKLOAD}_v${VERSION_SAFE}_${TIMESTAMP}.tar.gz"

# Execute all collection functions
echo "📁 Starting collection process..."
echo ""

# Initialize variables for external workload handling
IS_EXTERNAL_WORKLOAD=false
EW_OWNER_UID=""
EW_WORKLOAD_NAME=""

# Check if this is an external workload and handle accordingly
if [[ "$CANONICAL_TYPE" == "externalworkloads" ]]; then
  echo "  🔧 Detected External Workload type" >&2
  IS_EXTERNAL_WORKLOAD=true
  
  # Find the actual ExternalWorkload CR name (might have prefix)
  if EW_WORKLOAD_NAME=$(find_external_workload_name "$WORKLOAD"); then
    echo "    ✅ ExternalWorkload identified: $EW_WORKLOAD_NAME" >&2
    
    # Get ExternalWorkload YAML with the correct name
    if workload_yaml=$(get_workload_yaml "$EW_WORKLOAD_NAME" "$CANONICAL_TYPE" "$TYPE_SAFE"); then
      OUTPUT_FILES+=("$workload_yaml")
    fi
    
    # Get owner resource information
    if owner_info=$(get_external_workload_owner_info "$EW_WORKLOAD_NAME"); then
      IFS='|' read -r owner_kind owner_name owner_uid <<< "$owner_info"
      EW_OWNER_UID="$owner_uid"
      
      # Get the owner resource YAML
      if owner_yaml=$(get_external_workload_owner_yaml "$WORKLOAD" "$TYPE_SAFE" "$owner_kind" "$owner_name"); then
        OUTPUT_FILES+=("$owner_yaml")
      fi
    fi
  fi
else
  # For non-external workloads, use the workload name as-is
  if workload_yaml=$(get_workload_yaml "$WORKLOAD" "$CANONICAL_TYPE" "$TYPE_SAFE"); then
    OUTPUT_FILES+=("$workload_yaml")
  fi
fi

# Get runaijob YAML (skip for external workloads as they don't have RunAIJob)
if [[ "$IS_EXTERNAL_WORKLOAD" == "false" ]]; then
  if runaijob_yaml=$(get_runaijob_yaml "$WORKLOAD" "$TYPE_SAFE"); then
    OUTPUT_FILES+=("$runaijob_yaml")
  fi
fi

# Centralized pod and container discovery (OPTIMIZATION: single k8s_cmd call)
echo "  🔍 Discovering pods and containers..." >&2

# Determine the appropriate label selector for pod discovery
if [[ "$IS_EXTERNAL_WORKLOAD" == "true" && -n "$EW_OWNER_UID" ]]; then
  # For external workloads, use the owner UID to find pods
  echo "    🔍 Using run.ai/top-owner-uid label for external workload pod discovery..." >&2
  PODS_INFO=$(get_pods_and_containers_info "$WORKLOAD" "run.ai/top-owner-uid=$EW_OWNER_UID")
else
  # For regular workloads, use the workloadName label
  PODS_INFO=$(get_pods_and_containers_info "$WORKLOAD")
fi

if [[ $? -eq 0 && -n "$PODS_INFO" ]]; then
  echo "    ✅ Pod and container information discovered" >&2
  
  # Process all pod operations in unified manner (MAJOR OPTIMIZATION)
  if pod_output=$(process_pods_unified "$WORKLOAD" "$TYPE_SAFE" "$PODS_INFO"); then
    # Add each file to the output files array
    while IFS= read -r output_file; do
      if [[ -n "$output_file" ]]; then
        OUTPUT_FILES+=("$output_file")
      fi
    done <<< "$pod_output"
  fi
else
  echo "    ⚠️  No pods found for workload or discovery failed. Skipping pod-related operations." >&2
fi

# Get podgroup YAML
if podgroup_yaml=$(get_podgroup_yaml "$WORKLOAD" "$TYPE_SAFE"); then
  OUTPUT_FILES+=("$podgroup_yaml")
fi

# Get ksvc for inference workloads
if [[ "$CANONICAL_TYPE" == "inferenceworkloads" ]]; then
  if ksvc_spec=$(get_ksvc_yaml "$WORKLOAD" "$TYPE_SAFE"); then
    OUTPUT_FILES+=("$ksvc_spec")
  fi
fi

# Get pod list for all pods in namespace
if pod_list_output=$(get_all_pods_list "$WORKLOAD" "$TYPE_SAFE"); then
  OUTPUT_FILES+=("$pod_list_output")
fi

# Get all ConfigMaps in namespace
if configmap_output=$(get_all_configmaps "$WORKLOAD" "$TYPE_SAFE"); then
  OUTPUT_FILES+=("$configmap_output")
fi

# Get all PVCs in namespace
if pvc_output=$(get_all_pvcs "$WORKLOAD" "$TYPE_SAFE"); then
  OUTPUT_FILES+=("$pvc_output")
fi

# Get all Services in namespace
if service_output=$(get_all_services "$WORKLOAD" "$TYPE_SAFE"); then
  OUTPUT_FILES+=("$service_output")
fi

# Get all Ingresses in namespace
if ingress_output=$(get_all_ingresses "$WORKLOAD" "$TYPE_SAFE"); then
  OUTPUT_FILES+=("$ingress_output")
fi

# Get all Routes in namespace (OpenShift)
if route_output=$(get_all_routes "$WORKLOAD" "$TYPE_SAFE"); then
  OUTPUT_FILES+=("$route_output")
fi

echo ""
echo "📊 Collection Summary:"
echo "  Total files collected: ${#OUTPUT_FILES[@]}"
if [[ ${#OUTPUT_FILES[@]} -eq 0 ]]; then
  echo "  ⚠️  No files were successfully collected."
  echo "  This may indicate that the workload doesn't exist or resources are not accessible."
  echo "  Please check the workload name, type, and your permissions."
  exit 1
fi

echo "  Files collected:"
for file in "${OUTPUT_FILES[@]}"; do
  echo "    - $file"
done

# Archive the files
echo ""
echo "📦 Creating archive..."
if tar -czf "$ARCHIVE" "${OUTPUT_FILES[@]}" 2>/dev/null; then
  echo "  ✅ Archive created: $ARCHIVE"
  
  # Clean up individual files
  echo ""
  echo "🧹 Cleaning up individual files..."
  for file in "${OUTPUT_FILES[@]}"; do
    if [[ -f "$file" ]]; then
      rm "$file"
    fi
  done
  echo "✅ Cleanup completed. Only archive remains: $ARCHIVE"
else
  echo "  ❌ Failed to create archive. Individual files preserved."
  echo "  You can manually archive the following files:"
  for file in "${OUTPUT_FILES[@]}"; do
    echo "    - $file"
  done
  exit 1
fi

