# RunAI Scheduler Info Dump

Dumps RunAI scheduler resources (projects, queues, nodepools, departments) and packages them in a timestamped archive.

## Usage

```bash
chmod +x start.sh
./start.sh
```

## Output

Creates `scheduler_info_dump_DD-MM-YYYY_HH-MM.tar.gz` containing:

- `projects_list.txt` - Raw `kubectl get projects` output
- `project_*.yaml` - Individual project manifests
- `queues_list.txt` - Raw `kubectl get queues` output  
- `queue_*.yaml` - Individual queue manifests
- `nodepools_list.txt` - Raw `kubectl get nodepools` output
- `nodepool_*.yaml` - Individual nodepool manifests
- `departments_list.txt` - Raw `kubectl get departments` output
- `department_*.yaml` - Individual department manifests

## Prerequisites

- `kubectl` installed and configured
- Access to Kubernetes cluster with RunAI resources 