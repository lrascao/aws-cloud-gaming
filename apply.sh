#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Read region and resource_name from terraform.tfvars
REGION=$(grep -E '^region\s*=' terraform.tfvars | sed 's/.*=\s*"\(.*\)"/\1/')
RESOURCE_NAME=$(grep -E '^resource_name\s*=' terraform.tfvars | sed 's/.*=\s*"\(.*\)"/\1/' || echo "cloudrig")

BUCKET="${RESOURCE_NAME}-terraform-state"
DYNAMODB_TABLE="${RESOURCE_NAME}-terraform-locks"

terraform init \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="region=${REGION}" \
  -backend-config="dynamodb_table=${DYNAMODB_TABLE}"

terraform apply "$@"
