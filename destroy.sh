#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Only destroy the spot instance and volume attachment.
# Everything else (security group, IAM, SSM, games volume) is free/cheap
# and keeping it makes the next apply faster with the same password.
terraform destroy \
  -target=aws_volume_attachment.games \
  -target=aws_spot_instance_request.windows_instance \
  "$@"
