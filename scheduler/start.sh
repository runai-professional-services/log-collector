#!/bin/bash

# Scheduler Info Dump Script
# Dumps RunAI scheduler information and packages it in a timestamped archive

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if kubectl is installed
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl is not installed or not in PATH"
        exit 1
    fi
    print_success "kubectl found"
}

# Check kubectl connectivity
check_kubectl_connection() {
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    print_success "Connected to Kubernetes cluster"
}

# Create timestamp for archive name
get_timestamp() {
    date +"%d-%m-%Y_%H-%M"
}

# Function to dump a resource type
dump_resource() {
    local resource_type=$1
    local resource_singular=$2
    
    print_status "Dumping ${resource_type}..."
    kubectl get ${resource_type} > ${resource_type}_list.txt
    print_success "${resource_type} list saved to ${resource_type}_list.txt"
    
    # Extract individual manifests
    print_status "Extracting individual ${resource_type} manifests..."
    kubectl get ${resource_type} --no-headers -o custom-columns=":metadata.name" | while read resource; do
        if [ -n "$resource" ]; then
            kubectl get ${resource_type} "$resource" -o yaml > "${resource_singular}_${resource}.yaml"
            print_status "  - Extracted ${resource_singular}: $resource"
        fi
    done
}

# Main function
main() {
    print_status "Starting RunAI Scheduler Info Dump"
    print_status "=================================="
    
    # Verify prerequisites
    check_kubectl
    check_kubectl_connection
    
    # Create timestamp and archive name
    TIMESTAMP=$(get_timestamp)
    ARCHIVE_NAME="scheduler_info_dump_${TIMESTAMP}"
    
    print_status "Creating dump directory: ${ARCHIVE_NAME}"
    mkdir -p "${ARCHIVE_NAME}"
    cd "${ARCHIVE_NAME}"
    
    # Dump all resource types
    dump_resource "projects.run.ai" "project"
    dump_resource "queues.scheduling.run.ai" "queue"
    dump_resource "nodepools.run.ai" "nodepool"
    dump_resource "departments.scheduling.run.ai" "department"
    
    # Go back to parent directory
    cd ..
    
    # Create tar.gz archive
    print_status "Creating archive: ${ARCHIVE_NAME}.tar.gz"
    tar -czf "${ARCHIVE_NAME}.tar.gz" "${ARCHIVE_NAME}"
    
    # Clean up temporary directory
    rm -rf "${ARCHIVE_NAME}"
    
    print_success "Scheduler info dump completed successfully!"
    print_success "Archive created: ${ARCHIVE_NAME}.tar.gz"
    print_status "Archive contains:"
    print_status "  - projects_list.txt (projects list)"
    print_status "  - project_*.yaml (individual projects)"
    print_status "  - queues_list.txt (queues list)"
    print_status "  - queue_*.yaml (individual queues)"
    print_status "  - nodepools_list.txt (nodepools list)"
    print_status "  - nodepool_*.yaml (individual nodepools)"
    print_status "  - departments_list.txt (departments list)"
    print_status "  - department_*.yaml (individual departments)"
}

# Run main function
main "$@" 