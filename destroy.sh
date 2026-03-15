#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Read region and resource_name from terraform.tfvars
REGION=$(grep -E '^region\s*=' terraform.tfvars | sed 's/.*=\s*"\(.*\)"/\1/')
RESOURCE_NAME=$(grep -E '^resource_name\s*=' terraform.tfvars | sed 's/.*=\s*"\(.*\)"/\1/' || echo "cloudrig")

# Snapshot the games volume before destroying it
VOLUME_ID=$(terraform output -raw games_volume_id 2>/dev/null || echo "")

if [ -n "$VOLUME_ID" ]; then
  echo "Snapshotting games volume $VOLUME_ID..."

  # Delete old snapshots
  OLD_SNAPSHOTS=$(aws ec2 describe-snapshots --region "$REGION" \
    --filters "Name=tag:Name,Values=${RESOURCE_NAME}-games-snapshot" \
    --query 'Snapshots[].SnapshotId' --output text)
  for snap in $OLD_SNAPSHOTS; do
    echo "Deleting old snapshot $snap..."
    aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$snap"
  done

  # Create new snapshot
  SNAPSHOT_ID=$(aws ec2 create-snapshot --region "$REGION" \
    --volume-id "$VOLUME_ID" \
    --description "Games volume backup" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${RESOURCE_NAME}-games-snapshot},{Key=App,Value=cloudrig}]" \
    --query 'SnapshotId' --output text)

  echo "Waiting for snapshot $SNAPSHOT_ID to complete..."
  aws ec2 wait snapshot-completed --region "$REGION" --snapshot-ids "$SNAPSHOT_ID"
  echo "Snapshot $SNAPSHOT_ID complete."
fi

# Destroy instance, volume attachment, and volume.
# Everything else (security group, IAM, SSM) is free/cheap
# and keeping it makes the next apply faster with the same password.
terraform destroy \
  -target=aws_volume_attachment.games \
  -target=aws_ebs_volume.games \
  -target=aws_spot_instance_request.windows_instance \
  -target=aws_instance.windows_instance \
  "$@"
