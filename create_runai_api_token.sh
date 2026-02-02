#!/bin/bash
set -e

# Retrieve credentials
RUNAI_ADMIN_USERNAME=$(kubectl get configmap runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_USERNAME}' 2>/dev/null)
RUNAI_ADMIN_PASSWORD=$(kubectl get secret runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.ADMIN_PASSWORD}' 2>/dev/null | base64 -d)
RUNAI_CTRL_PLANE_URL=$(kubectl get configmap runai-backend-tenants-manager -n runai-backend -o jsonpath='{.data.TENANT_DOMAIN_TEMPLATE}' 2>/dev/null)

# Validate credentials were retrieved
[ -z "$RUNAI_ADMIN_USERNAME" ] && echo "Error: Failed to retrieve ADMIN_USERNAME" && exit 1
[ -z "$RUNAI_ADMIN_PASSWORD" ] && echo "Error: Failed to retrieve ADMIN_PASSWORD" && exit 1
[ -z "$RUNAI_CTRL_PLANE_URL" ] && echo "Error: Failed to retrieve TENANT_DOMAIN_TEMPLATE" && exit 1

echo "RUNAI_ADMIN_USERNAME: $RUNAI_ADMIN_USERNAME"
echo "RUNAI_ADMIN_PASSWORD: $RUNAI_ADMIN_PASSWORD"
echo "RUNAI_CTRL_PLANE_URL: $RUNAI_CTRL_PLANE_URL"

# Get API token
API_RESPONSE=$(curl -s -X POST "$RUNAI_CTRL_PLANE_URL/api/v1/token" \
  --header 'Accept: */*' \
  --header 'Content-Type: application/json' \
  --data-raw "{\"grantType\": \"password\", \"clientID\": \"cli\", \"username\": \"$RUNAI_ADMIN_USERNAME\", \"password\": \"$RUNAI_ADMIN_PASSWORD\"}")

# Parse response
RUNAI_TOKEN=$(echo "$API_RESPONSE" | jq -r '.accessToken // empty' 2>/dev/null)
ERROR_MESSAGE=$(echo "$API_RESPONSE" | jq -r '.message // empty' 2>/dev/null)
ERROR_CODE=$(echo "$API_RESPONSE" | jq -r '.code // empty' 2>/dev/null)

# Validate token
if [ -z "$RUNAI_TOKEN" ]; then
  echo "Error: Failed to retrieve API token"
  [ -n "$ERROR_CODE" ] && echo "Error Code: $ERROR_CODE"
  [ -n "$ERROR_MESSAGE" ] && echo "Error Message: $ERROR_MESSAGE"
  [ -z "$ERROR_MESSAGE" ] && echo "API Response: $API_RESPONSE"
  exit 1
fi

echo "RUNAI_TOKEN: $RUNAI_TOKEN"