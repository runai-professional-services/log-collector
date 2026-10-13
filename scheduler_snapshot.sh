#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2025-2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Scheduler Snapshot Collection Script
VERSION="1.2.1"
# Collect scheduler snapshots from all RunAI scheduler deployments in the runai namespace.
# For each deployment, calls /get-snapshot and validates the returned archive and JSON.
# Each invocation saves into its own private directory; the historical .gzip suffix is retained.
#
# What the snapshot contains (see get-snapshot-api-summary for full detail):
#   - config: scheduler actions and plugin tiers
#   - schedulerParams: RunAI params (partition, fairness, schedule period, etc.)
#   - rawObjects: cluster state the scheduler uses (pods, nodes, queues, podGroups, bindRequests, priorityClasses, configMaps, PVCs, storageClasses, csiDrivers, etc.)

set -eo pipefail
umask 077
NAMESPACE="${RUNAI_NAMESPACE:-runai}"
PORT=8081
START_TIMEOUT="${RUNAI_PORT_FORWARD_TIMEOUT_SECONDS:-30}"
SNAPSHOT_TIMEOUT="${RUNAI_SNAPSHOT_TIMEOUT_SECONDS:-120}"

for TIMEOUT in "$START_TIMEOUT" "$SNAPSHOT_TIMEOUT"; do
  if [[ ! "$TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]]; then
    echo "Timeouts must be integers between 1 and 99999 seconds." >&2
    exit 1
  fi
done

for COMMAND in kubectl curl unzip gzip jq; do
  if ! command -v "$COMMAND" >/dev/null 2>&1; then
    echo "Required command not found: $COMMAND" >&2
    exit 1
  fi
done

# Discover all RunAI scheduler deployments (names like runai-scheduler-default, runai-scheduler-<name>)
if ! DEPLOYMENTS=$(kubectl get deployments -n "$NAMESPACE" --request-timeout=30s --no-headers -o custom-columns=":metadata.name"); then
  echo "Failed to discover RunAI scheduler deployments in namespace: $NAMESPACE" >&2
  exit 1
fi

SCHEDULERS=()
while IFS= read -r DEPLOYMENT; do
  if [[ "$DEPLOYMENT" == runai-scheduler-* ]]; then
    # Kubernetes Deployment names are DNS subdomains. Do not use unexpected output as a path.
    if [[ ! "$DEPLOYMENT" =~ ^runai-scheduler-[a-z0-9][a-z0-9.-]*$ ]]; then
      echo "Invalid scheduler deployment name in discovery output." >&2
      exit 1
    fi
    SCHEDULERS+=("$DEPLOYMENT")
  fi
done <<< "$DEPLOYMENTS"

if [ ${#SCHEDULERS[@]} -eq 0 ]; then
  echo "No RunAI scheduler deployments found in namespace: $NAMESPACE" >&2
  exit 1
fi

echo "Found ${#SCHEDULERS[@]} scheduler deployment(s): ${SCHEDULERS[*]}"
OUTPUT_DIR=$(mktemp -d "./scheduler-snapshots-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
echo "Output directory: $OUTPUT_DIR"
PF_PID=""
PART_FILE=""
SUCCESS_COUNT=0

stop_port_forward() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    # Bound cleanup as well as startup; wait/reap only the child started by this script.
    for ((ATTEMPT = 0; ATTEMPT < 20; ATTEMPT++)); do
      kill -0 "$PF_PID" 2>/dev/null || break
      sleep 0.1
    done
    if ((ATTEMPT == 20)); then
      kill -KILL "$PF_PID" 2>/dev/null || true
    fi
    wait "$PF_PID" 2>/dev/null || true
    PF_PID=""
  fi
}

cleanup() {
  stop_port_forward
  if [[ -n "$PART_FILE" ]]; then
    rm -f -- "$PART_FILE"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

valid_snapshot_json() {
  # Exactly one JSON object, with the documented top-level fields. Do not require a
  # version-specific Kubernetes schema or print any snapshot content to the terminal.
  jq -se 'length == 1 and (.[0] | type == "object" and
    (.config | type == "object") and (.schedulerParams | type == "object") and
    (.rawObjects | type == "object"))' >/dev/null
}

valid_snapshot() {
  # KAI returns a ZIP with snapshot.json; also support gzip-compressed JSON.
  # .gzip is a historical filename, not evidence of the actual encoding.
  if unzip -tqq "$1" >/dev/null 2>&1; then
    # The analysis tool reads the first matching entry; concatenating duplicates
    # could hide an empty or invalid first entry behind a later valid document.
    if ! unzip -Z1 "$1" | awk '$0 == "snapshot.json" {count++} END {exit (count != 1)}'; then
      return 1
    fi
    unzip -p "$1" snapshot.json | valid_snapshot_json
  elif gzip -t "$1" >/dev/null 2>&1; then
    gzip -dc "$1" | valid_snapshot_json
  else
    return 1
  fi
}

for RUNAI_SCHEDULER_DEPLOYMENT_NAME in "${SCHEDULERS[@]}"; do
  echo "--- Collecting snapshot from: $RUNAI_SCHEDULER_DEPLOYMENT_NAME ---"
  PF_LOG="$OUTPUT_DIR/${RUNAI_SCHEDULER_DEPLOYMENT_NAME}-port-forward.log"
  PART_FILE="$OUTPUT_DIR/.${RUNAI_SCHEDULER_DEPLOYMENT_NAME}-snapshot.part"
  SNAPSHOT_FILE="$OUTPUT_DIR/${RUNAI_SCHEDULER_DEPLOYMENT_NAME}-snapshot.gzip"
  # Ask kubectl to choose a free local port, restricted to IPv4 loopback.
  kubectl port-forward -n "$NAMESPACE" --address 127.0.0.1 --pod-running-timeout="${START_TIMEOUT}s" \
    "deployment/$RUNAI_SCHEDULER_DEPLOYMENT_NAME" ":$PORT" >"$PF_LOG" 2>&1 &
  PF_PID=$!
  LOCAL_PORT=""
  DEADLINE=$((SECONDS + START_TIMEOUT))
  while ((SECONDS < DEADLINE)); do
    if ! kill -0 "$PF_PID" 2>/dev/null; then
      break
    fi
    LOCAL_PORT=$(awk '/^Forwarding from 127[.]0[.]0[.]1:[0-9]+ -> 8081$/ {split($3, address, ":"); print address[2]; exit}' "$PF_LOG")
    [[ -n "$LOCAL_PORT" ]] && break
    sleep 0.1
  done

  if [[ -z "$LOCAL_PORT" ]]; then
    echo "Port-forward failed or timed out for $RUNAI_SCHEDULER_DEPLOYMENT_NAME; see $PF_LOG" >&2
  elif HTTP_STATUS=$(curl --disable --silent --show-error --fail --noproxy '*' \
      --connect-timeout 5 --max-time "$SNAPSHOT_TIMEOUT" --write-out '%{http_code}' \
      --output "$PART_FILE" "http://127.0.0.1:$LOCAL_PORT/get-snapshot"); then
    stop_port_forward
    if [[ "$HTTP_STATUS" == 200 ]] && valid_snapshot "$PART_FILE" 2>/dev/null; then
      mv -- "$PART_FILE" "$SNAPSHOT_FILE"
      SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
      echo "Saved: $SNAPSHOT_FILE"
    else
      echo "Invalid snapshot or unexpected HTTP status ($HTTP_STATUS) from $RUNAI_SCHEDULER_DEPLOYMENT_NAME" >&2
    fi
  else
    echo "Failed to get snapshot from $RUNAI_SCHEDULER_DEPLOYMENT_NAME" >&2
  fi
  stop_port_forward
  rm -f -- "$PART_FILE"
  PART_FILE=""
done

echo "Done. Collected $SUCCESS_COUNT of ${#SCHEDULERS[@]} snapshot(s). Output directory: $OUTPUT_DIR (collector v$VERSION)"
if ((SUCCESS_COUNT != ${#SCHEDULERS[@]})); then
  exit 1
fi
