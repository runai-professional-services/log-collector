#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Scheduler Snapshot Collection Script
VERSION="1.2.1"
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
# Local end of the port-forward. Left empty, kubectl binds a free ephemeral port:
# the collecting host often already listens on 8081 itself (BCM nodes run cmdaemon
# there on every node). Set RUNAI_SNAPSHOT_LOCAL_PORT to pin it.
LOCAL_PORT="${RUNAI_SNAPSHOT_LOCAL_PORT:-}"

# Discover all RunAI scheduler deployments (names like runai-scheduler-default, runai-scheduler-<name>)
SCHEDULERS=($(kubectl get deployments -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep '^runai-scheduler-' || true))

if [ ${#SCHEDULERS[@]} -eq 0 ]; then
  echo "No RunAI scheduler deployments found in namespace: $NAMESPACE"
  exit 0
fi

echo "Found ${#SCHEDULERS[@]} scheduler deployment(s): ${SCHEDULERS[*]}"

SAVED=0
FAILED=0

for RUNAI_SCHEDULER_DEPLOYMENT_NAME in "${SCHEDULERS[@]}"; do
  echo "--- Collecting snapshot from: $RUNAI_SCHEDULER_DEPLOYMENT_NAME ---"
  SNAPSHOT_FILE="${RUNAI_SCHEDULER_DEPLOYMENT_NAME}-snapshot.gzip"
  PF_LOG=$(mktemp)
  kubectl port-forward -n "$NAMESPACE" "deployment/$RUNAI_SCHEDULER_DEPLOYMENT_NAME" "$LOCAL_PORT:$PORT" >"$PF_LOG" 2>&1 &
  PF_PID=$!
  trap "kill $PF_PID 2>/dev/null; rm -f '$PF_LOG'; echo 'Port-forward (PID '$PF_PID') killed on exit'" EXIT

  # An ephemeral local port is only known once kubectl reports what it bound, so read
  # it back rather than assuming $LOCAL_PORT. Doubles as the readiness check.
  BOUND_PORT=""
  WAITED=0
  while [ "$WAITED" -lt 20 ]; do
    BOUND_PORT=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9][0-9]*\) ->.*/\1/p' "$PF_LOG" | head -n 1)
    [ -n "$BOUND_PORT" ] && break
    kill -0 "$PF_PID" 2>/dev/null || break
    sleep 0.5
    WAITED=$((WAITED + 1))
  done

  if [ -z "$BOUND_PORT" ]; then
    echo "Failed to port-forward to $RUNAI_SCHEDULER_DEPLOYMENT_NAME" >&2
    cat "$PF_LOG" >&2
    FAILED=$((FAILED + 1))
  elif curl -sS "127.0.0.1:$BOUND_PORT/get-snapshot" -o "$SNAPSHOT_FILE"; then
    echo "Saved: $SNAPSHOT_FILE"
    SAVED=$((SAVED + 1))
  else
    # Discard whatever curl left behind. A snapshot truncated by a forward that
    # dropped mid-transfer is worse in a support bundle than a missing one.
    rm -f "$SNAPSHOT_FILE"
    echo "Failed to get snapshot from $RUNAI_SCHEDULER_DEPLOYMENT_NAME" >&2
    FAILED=$((FAILED + 1))
  fi
  # Reap the job as well as killing it, so bash does not report the signal it died of.
  { kill $PF_PID && wait $PF_PID; } 2>/dev/null || true
  rm -f "$PF_LOG"
  trap - EXIT
done

echo "Done. Collected $SAVED of ${#SCHEDULERS[@]} snapshot(s)."

if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED scheduler(s) could not be collected; the snapshots are missing from this run." >&2
  exit 1
fi
