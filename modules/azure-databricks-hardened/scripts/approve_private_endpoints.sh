#!/usr/bin/env bash
# Approve the private endpoint connections that Databricks NCC rules created on an
# Azure resource - and only those.
#
# Usage: approve_private_endpoints.sh <resource-id> <endpoint-name> [<endpoint-name> ...]
#   <endpoint-name> = endpoint_name of a databricks_mws_ncc_private_endpoint_rule.
#
# NCC private endpoints live in a Databricks-managed subscription, so their
# connection shows up on the target resource as Pending some time after the rule
# exists. The connection's privateEndpoint.id ends with /privateEndpoints/<endpoint_name>.
# Pending connections from any other endpoint are left untouched.
#
# Env: APPROVE_TIMEOUT_SECONDS (default 600)
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <resource-id> <endpoint-name> [<endpoint-name> ...]" >&2
  exit 2
fi

resource_id="$1"
shift
timeout="${APPROVE_TIMEOUT_SECONDS:-600}"
deadline=$(( $(date +%s) + timeout ))

# Prints "<connection-id> <status>" for the connection of one endpoint, or nothing.
connection_of() {
  az network private-endpoint-connection list --id "$resource_id" \
    --query "[?ends_with(properties.privateEndpoint.id, '/privateEndpoints/$1')].[id, properties.privateLinkServiceConnectionState.status] | [0]" \
    -o tsv 2>/dev/null || true
}

for endpoint in "$@"; do
  while :; do
    line="$(connection_of "$endpoint")"
    if [ -n "$line" ]; then
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo "Timed out waiting for the connection of $endpoint on $resource_id." >&2
      exit 1
    fi
    echo "Waiting for the private endpoint connection of $endpoint..."
    sleep 15
  done

  conn_id="${line%%[[:space:]]*}"
  status="${line##*[[:space:]]}"
  if [ "$status" = "Pending" ]; then
    echo "Approving $endpoint"
    az network private-endpoint-connection approve --id "$conn_id" \
      --description "Approved by Terraform (Databricks NCC)" -o none
  else
    echo "$endpoint: $status (no action)"
  fi
done
