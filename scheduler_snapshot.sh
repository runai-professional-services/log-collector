#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Scheduler Snapshot Collection Script
VERSION="1.1.0"
# Collect scheduler snapshots from all RunAI scheduler deployments in the runai namespace.
# For each deployment, calls the /get-snapshot endpoint and saves the response as <deployment>-snapshot.gzip.
#
# What the snapshot contains (see get-snapshot-api-summary for full detail):
#   - config: scheduler actions and plugin tiers
#   - schedulerParams: RunAI params (partition, fairness, schedule period, etc.)
#   - rawObjects: cluster state the scheduler uses (pods, nodes, queues, podGroups, bindRequests, priorityClasses, configMaps, PVCs, storageClasses, csiDrivers, etc.)

set -e
NAMESPACE="${RUNAI_NAMESPACE:-runai}"
PORT=8081

# Discover all RunAI scheduler deployments (names like runai-scheduler-default, runai-scheduler-<name>)
SCHEDULERS=($(kubectl get deployments -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^runai-scheduler-' || true))

if [ ${#SCHEDULERS[@]} -eq 0 ]; then
  echo "No RunAI scheduler deployments found in namespace: $NAMESPACE"
  exit 0
fi

echo "Found ${#SCHEDULERS[@]} scheduler deployment(s): ${SCHEDULERS[*]}"

for RUNAI_SCHEDULER_DEPLOYMENT_NAME in "${SCHEDULERS[@]}"; do
  echo "--- Collecting snapshot from: $RUNAI_SCHEDULER_DEPLOYMENT_NAME ---"
  kubectl port-forward -n "$NAMESPACE" "deployment/$RUNAI_SCHEDULER_DEPLOYMENT_NAME" "$PORT" &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null; echo 'Port-forward (PID '$PF_PID') killed on exit'" EXIT
  sleep 2
  if curl -sS "localhost:$PORT/get-snapshot" -o "${RUNAI_SCHEDULER_DEPLOYMENT_NAME}-snapshot.gzip"; then
    echo "Saved: ${RUNAI_SCHEDULER_DEPLOYMENT_NAME}-snapshot.gzip"
  else
    echo "Failed to get snapshot from $RUNAI_SCHEDULER_DEPLOYMENT_NAME" >&2
  fi
  kill $PF_PID 2>/dev/null || true
  trap - EXIT
done

echo "Done. Collected ${#SCHEDULERS[@]} snapshot(s)."
