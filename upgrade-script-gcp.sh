#!/bin/bash
set -e

# Default values
PROJECT_ID=""
ZONE=""
LABEL_KEY="toupgrade"
LABEL_VALUE="true"
UPGRADE_LABEL_KEY="upgraded"
UPGRADE_LABEL_VALUE="true"

# Parse named parameters
for arg in "$@"; do
  case $arg in
    project=*)
      PROJECT_ID="${arg#*=}"
      ;;
    zone=*)
      ZONE="${arg#*=}"
      ;;
    label=*)
      LABEL_KEY="${arg#*=}"
      ;;
    value=*)
      LABEL_VALUE="${arg#*=}"
      ;;
    labelafter=*)
      UPGRADE_LABEL_KEY="${arg#*=}"
      ;;
    valueafter=*)
      UPGRADE_LABEL_VALUE="${arg#*=}"
      ;;
    *)
      echo "WARNING: Unknown parameter: $arg"
      ;;
  esac
done

# Verify required parameters
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Project ID is required with the project= parameter"
  echo "Usage: $0 project=ProjectID [zone=Zone] [label=LabelKey] [value=LabelValue] [labelafter=UpgradeLabelKey] [valueafter=UpgradeLabelValue]"
  echo ""
  echo "Example: $0 project=my-gcp-project zone=us-central1-a label=toupgrade value=true labelafter=upgraded valueafter=true"
  exit 1
fi

if [ -n "$ZONE" ]; then
  echo "Looking for VMs with label $LABEL_KEY=$LABEL_VALUE in project $PROJECT_ID (zone: $ZONE)..."
  VM_LIST=$(gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter="labels.$LABEL_KEY=$LABEL_VALUE AND zone:($ZONE)" \
    --format="json(name,zone,status)" \
    --quiet)
else
  echo "Looking for VMs with label $LABEL_KEY=$LABEL_VALUE in project $PROJECT_ID (all zones)..."
  VM_LIST=$(gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter="labels.$LABEL_KEY=$LABEL_VALUE" \
    --format="json(name,zone,status)" \
    --quiet)
fi

# Count VMs found
VM_COUNT=$(echo "$VM_LIST" | jq '. | length')
echo "Found $VM_COUNT VMs with label $LABEL_KEY=$LABEL_VALUE"

# Initialize counters
RUNNING_VMS=0
STOPPED_VMS=0
UPGRADED_VMS=0
SKIPPED_VMS=0
SKIPPED_NON_CANONICAL=0
FAILED_VMS=0
ALREADY_PRO_VMS=0

map_to_pro_license_uri() {
  local PREV="$1"
  case "$PREV" in
    *"/projects/ubuntu-os-cloud/global/licenses/ubuntu-1604-lts")
      echo "https://www.googleapis.com/compute/v1/projects/ubuntu-os-pro-cloud/global/licenses/ubuntu-pro-1604-lts"
      ;;
    *"/projects/ubuntu-os-cloud/global/licenses/ubuntu-1804-lts")
      echo "https://www.googleapis.com/compute/v1/projects/ubuntu-os-pro-cloud/global/licenses/ubuntu-pro-1804-lts"
      ;;
    *"/projects/ubuntu-os-cloud/global/licenses/ubuntu-2004-lts")
      echo "https://www.googleapis.com/compute/v1/projects/ubuntu-os-pro-cloud/global/licenses/ubuntu-pro-2004-lts"
      ;;
    *"/projects/ubuntu-os-cloud/global/licenses/ubuntu-2204-lts")
      echo "https://www.googleapis.com/compute/v1/projects/ubuntu-os-pro-cloud/global/licenses/ubuntu-pro-2204-lts"
      ;;
    *"/projects/ubuntu-os-cloud/global/licenses/ubuntu-2404-lts")
      echo "https://www.googleapis.com/compute/v1/projects/ubuntu-os-pro-cloud/global/licenses/ubuntu-pro-2404-lts"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Process each VM
while IFS= read -r row; do
  VM_NAME=$(echo "$row" | jq -r '.name')
  # Zone is returned as a full URL, extract the last path component
  VM_ZONE=$(echo "$row" | jq -r '.zone' | awk -F'/' '{print $NF}')
  VM_STATUS=$(echo "$row" | jq -r '.status')

  echo "Processing VM: $VM_NAME (Zone: $VM_ZONE, Status: $VM_STATUS)"

  # Collect boot disk metadata (name + source image + current licenses)
  INSTANCE_INFO=$(gcloud compute instances describe "$VM_NAME" \
    --zone="$VM_ZONE" \
    --project="$PROJECT_ID" \
    --format="json(disks)" \
    --quiet)
  BOOT_DISK_SOURCE=$(echo "$INSTANCE_INFO" | jq -r '.disks[] | select(.boot == true) | .source' | head -n 1)
  if [ -z "$BOOT_DISK_SOURCE" ] || [ "$BOOT_DISK_SOURCE" = "null" ]; then
    echo "  ERROR: Could not determine boot disk for $VM_NAME"
    FAILED_VMS=$((FAILED_VMS+1))
    continue
  fi
  BOOT_DISK_NAME=$(echo "$BOOT_DISK_SOURCE" | awk -F'/' '{print $NF}')

  DISK_INFO=$(gcloud compute disks describe "$BOOT_DISK_NAME" \
    --zone="$VM_ZONE" \
    --project="$PROJECT_ID" \
    --format="json(sourceImage,licenses)" \
    --quiet 2>/dev/null || echo '{}')
  SOURCE_IMAGE=$(echo "$DISK_INFO" | jq -r '.sourceImage // "unknown"' 2>/dev/null || echo "unknown")
  HAS_LTS_LICENSE=$(echo "$DISK_INFO" | jq -r '[.licenses[]? | select(test("projects/ubuntu-os-cloud/global/licenses/ubuntu-(1604|1804|2004|2204|2404)-lts$"))] | length > 0' 2>/dev/null || echo "false")
  HAS_PRO_LICENSE=$(echo "$DISK_INFO" | jq -r '[.licenses[]? | select(test("projects/ubuntu-os-pro-cloud/global/licenses/ubuntu-pro-(1604|1804|2004|2204|2404)-lts$"))] | length > 0' 2>/dev/null || echo "false")

  echo "  Source image: $SOURCE_IMAGE"

  # Canonical Ubuntu images/licenses live in ubuntu-os-cloud or ubuntu-os-pro-cloud.
  # Use source image and license signals because one may be missing in some customer setups.
  if [[ "$SOURCE_IMAGE" != *"ubuntu-os-cloud"* ]] && [[ "$SOURCE_IMAGE" != *"ubuntu-os-pro-cloud"* ]] && [[ "$HAS_LTS_LICENSE" != "true" ]] && [[ "$HAS_PRO_LICENSE" != "true" ]]; then
    echo "  VM is not using an Ubuntu image from Canonical, skipping upgrade"
    SKIPPED_NON_CANONICAL=$((SKIPPED_NON_CANONICAL+1))
    SKIPPED_VMS=$((SKIPPED_VMS+1))
    continue
  fi

  # If already on Pro license, retag and continue.
  CURRENT_PRO_LICENSE=$(echo "$DISK_INFO" | jq -r '.licenses[]? | select(test("projects/ubuntu-os-pro-cloud/global/licenses/ubuntu-pro-(1604|1804|2004|2204|2404)-lts$"))' | head -n 1)
  if [ -n "$CURRENT_PRO_LICENSE" ]; then
    echo "  VM boot disk already has a Pro license, updating labels"
    gcloud compute instances remove-labels "$VM_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --labels="$LABEL_KEY" \
      --quiet || true
    gcloud compute instances add-labels "$VM_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --labels="$UPGRADE_LABEL_KEY=$UPGRADE_LABEL_VALUE" \
      --quiet
    ALREADY_PRO_VMS=$((ALREADY_PRO_VMS+1))
    UPGRADED_VMS=$((UPGRADED_VMS+1))
    continue
  fi

  # Find current Ubuntu LTS license and compute matching Pro license.
  PREVIOUS_LICENSE_URI=$(echo "$DISK_INFO" | jq -r '.licenses[]? | select(test("projects/ubuntu-os-cloud/global/licenses/ubuntu-(1604|1804|2004|2204|2404)-lts$"))' | head -n 1)
  if [ -z "$PREVIOUS_LICENSE_URI" ]; then
    echo "  ERROR: Could not determine current Ubuntu LTS license for $VM_NAME"
    echo "  Cannot safely compute replacement Pro license, skipping"
    FAILED_VMS=$((FAILED_VMS+1))
    continue
  fi

  NEW_LICENSE_URI=$(map_to_pro_license_uri "$PREVIOUS_LICENSE_URI")
  if [ -z "$NEW_LICENSE_URI" ]; then
    echo "  ERROR: Unsupported LTS license mapping for $VM_NAME"
    echo "  Previous license: $PREVIOUS_LICENSE_URI"
    FAILED_VMS=$((FAILED_VMS+1))
    continue
  fi

  # Per Canonical/GCP guidance, disk license replacement requires VM stopped.
  # This script only acts on running VMs (keeps previous behavior for stopped VMs).
  if [[ "$VM_STATUS" == "RUNNING" ]]; then
    echo "  VM is running, proceeding with LTS -> Pro license replacement..."
    RUNNING_VMS=$((RUNNING_VMS+1))

    echo "  Stopping VM before disk license change..."
    gcloud compute instances stop "$VM_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --quiet

    echo "  Replacing disk license:"
    echo "    from: $PREVIOUS_LICENSE_URI"
    echo "    to:   $NEW_LICENSE_URI"
    LICENSE_UPDATE_EXIT=0
    LICENSE_UPDATE_RESULT=$(gcloud compute disks update "$BOOT_DISK_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --replace-license="$PREVIOUS_LICENSE_URI,$NEW_LICENSE_URI" \
      --quiet 2>&1) || LICENSE_UPDATE_EXIT=$?
    echo "$LICENSE_UPDATE_RESULT"

    if [ "$LICENSE_UPDATE_EXIT" -ne 0 ]; then
      echo "  ERROR: Disk license replacement failed for $VM_NAME"
      FAILED_VMS=$((FAILED_VMS+1))
      echo "  Attempting to start VM back up to avoid leaving it stopped..."
      gcloud compute instances start "$VM_NAME" \
        --zone="$VM_ZONE" \
        --project="$PROJECT_ID" \
        --quiet || true
      continue
    fi

    echo "  Starting VM after disk license change..."
    gcloud compute instances start "$VM_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --quiet

    # Verify Pro license is now present on the boot disk.
    UPDATED_DISK_INFO=$(gcloud compute disks describe "$BOOT_DISK_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --format="json(licenses)" \
      --quiet)
    HAS_NEW_LICENSE=$(echo "$UPDATED_DISK_INFO" | jq -r --arg lic "$NEW_LICENSE_URI" '[(.licenses[]? == $lic)] | any')

    if [[ "$HAS_NEW_LICENSE" != "true" ]]; then
      echo "  ERROR: License replacement could not be verified on disk for $VM_NAME"
      FAILED_VMS=$((FAILED_VMS+1))
      continue
    fi

    # Verify license from VM/instance view (no guest SSH required).
    INSTANCE_POST_INFO=$(gcloud compute instances describe "$VM_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --format="json(disks)" \
      --quiet)
    INSTANCE_BOOT_PRO_LICENSE=$(echo "$INSTANCE_POST_INFO" | jq -r --arg lic "$NEW_LICENSE_URI" '[.disks[] | select(.boot == true) | .licenses[]? | select(. == $lic)] | length > 0')
    if [[ "$INSTANCE_BOOT_PRO_LICENSE" != "true" ]]; then
      echo "  WARNING: Instance-level boot disk license check did not show expected Pro license"
      echo "  Expected: $NEW_LICENSE_URI"
      echo "  Continuing because disk-level verification succeeded."
    else
      echo "  Instance-level license check succeeded."
    fi

    # Remove the original label and add the upgraded label
    echo "  Removing label $LABEL_KEY and adding label $UPGRADE_LABEL_KEY=$UPGRADE_LABEL_VALUE..."
    gcloud compute instances remove-labels "$VM_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --labels="$LABEL_KEY" \
      --quiet
    gcloud compute instances add-labels "$VM_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --labels="$UPGRADE_LABEL_KEY=$UPGRADE_LABEL_VALUE" \
      --quiet

    UPGRADED_VMS=$((UPGRADED_VMS+1))
    echo "  All operations completed successfully for $VM_NAME"
  else
    echo "  VM is not running (state: $VM_STATUS), skipping upgrade operations"
    STOPPED_VMS=$((STOPPED_VMS+1))
    SKIPPED_VMS=$((SKIPPED_VMS+1))
  fi
done < <(echo "$VM_LIST" | jq -c '.[]')

# Show summary
echo ""
echo "===== UPGRADE SUMMARY ====="
echo "Total VMs found with label $LABEL_KEY=$LABEL_VALUE: $VM_COUNT"
echo "Running VMs: $RUNNING_VMS"
echo "Stopped VMs: $STOPPED_VMS"
echo "VMs upgraded to Ubuntu Pro: $UPGRADED_VMS"
echo "VMs already on Pro (retagged): $ALREADY_PRO_VMS"
echo "VMs failed during upgrade: $FAILED_VMS"
echo "VMs skipped: $SKIPPED_VMS"
echo "  - Non-Canonical images: $SKIPPED_NON_CANONICAL"
echo "  - Stopped VMs: $STOPPED_VMS"
echo "=========================="

if [ "$SKIPPED_VMS" -gt 0 ]; then
  echo ""
  echo "NOTE: Some VMs were skipped for the following reasons:"

  if [ "$SKIPPED_NON_CANONICAL" -gt 0 ]; then
    echo "- $SKIPPED_NON_CANONICAL VMs were not running Ubuntu images from Canonical"
  fi

  if [ "$STOPPED_VMS" -gt 0 ]; then
    echo "- $STOPPED_VMS VMs were not running"
    echo "  To upgrade these VMs, start them and run this script again."
  fi
fi
