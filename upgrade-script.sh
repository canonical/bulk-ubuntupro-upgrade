#!/bin/bash
set -uo pipefail

SLEEP_DURATION="${SLEEP_DURATION:-5}"

# Default values
RESOURCE_GROUP=""
SUBSCRIPTION=""
TAG_NAME="toupgrade"
TAG_VALUE="true"
UPGRADE_TAG_NAME="upgraded"
UPGRADE_TAG_VALUE="true"

az_cli() {
  if [ -n "$SUBSCRIPTION" ]; then
    az --subscription "$SUBSCRIPTION" "$@"
  else
    az "$@"
  fi
}

# Parse named parameters
for arg in "$@"; do
  case $arg in
    rg=*)
      RESOURCE_GROUP="${arg#*=}"
      ;;
    sub=*|subscription=*)
      SUBSCRIPTION="${arg#*=}"
      ;;
    tag=*)
      TAG_NAME="${arg#*=}"
      ;;
    value=*)
      TAG_VALUE="${arg#*=}"
      ;;
    tagafter=*)
      UPGRADE_TAG_NAME="${arg#*=}"
      ;;
    valueafter=*)
      UPGRADE_TAG_VALUE="${arg#*=}"
      ;;
    *)
      echo "WARNING: Unknown parameter: $arg"
      ;;
  esac
done

# Verify required parameters
if [ -z "$RESOURCE_GROUP" ]; then
  echo "ERROR: Resource group name is required with the rg= parameter"
  echo "Usage: $0 rg=ResourceGroupName [tag=TagName] [value=TagValue] [tagafter=UpgradeTagName] [valueafter=UpgradeTagValue]"
  echo ""
  echo "Example: $0 rg=myResourceGroup tag=toupgrade value=true tagafter=upgraded valueafter=true"
  exit 1
fi

echo "Looking for VMs with tag $TAG_NAME=$TAG_VALUE in resource group $RESOURCE_GROUP..."

if [ -n "$SUBSCRIPTION" ]; then
  echo "Using Azure subscription: $SUBSCRIPTION"
fi

# Get all VMs with the specified tag
if ! VM_LIST=$(az_cli vm list -g "$RESOURCE_GROUP" --query "[?tags.$TAG_NAME=='$TAG_VALUE'].name" -o json 2>/dev/null); then
  echo "ERROR: Unable to list VMs in resource group $RESOURCE_GROUP."
  echo "This usually means the Azure CLI is pointed at the wrong subscription."
  echo "Set the correct subscription first:"
  echo "  az account set --subscription \"<subscription-id-or-name>\""
  echo "Then rerun:"
  echo "  $0 rg=$RESOURCE_GROUP tag=$TAG_NAME value=$TAG_VALUE"
  echo "Current Azure context:"
  az_cli account show --output table 2>/dev/null || echo "  No active Azure subscription is available in this shell."
  exit 1
fi

# Count VMs found
VM_COUNT=$(echo "$VM_LIST" | jq '. | length')
echo "Found $VM_COUNT VMs with tag $TAG_NAME=$TAG_VALUE"

# Initialize counters
RUNNING_VMS=0
STOPPED_VMS=0
UPGRADED_VMS=0
SKIPPED_VMS=0
SKIPPED_NON_CANONICAL=0
DESIRED_LICENSE_TYPE="UBUNTU_PRO"

# Process each VM without using a pipe to avoid subshell issues
VM_NAMES=($(echo "$VM_LIST" | jq -r '.[]'))

for VM_NAME in "${VM_NAMES[@]}"; do
  if ! az_cli vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "name" -o tsv >/dev/null 2>&1; then
    echo "Processing VM: $VM_NAME"
    echo "  VM is no longer visible in Azure (HTTP 404 / Not Found), skipping this VM"
    SKIPPED_VMS=$((SKIPPED_VMS+1))
    continue
  fi

  if ! POWER_STATE=$(az_cli vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "instanceView.statuses[?contains(code, 'PowerState')].displayStatus | [0]" -o tsv 2>/dev/null); then
    echo "Processing VM: $VM_NAME"
    echo "  Could not determine the power state for this VM; skipping this VM"
    SKIPPED_VMS=$((SKIPPED_VMS+1))
    continue
  fi

  echo "Processing VM: $VM_NAME (Power state: $POWER_STATE)"

  if ! PUBLISHER=$(az_cli vm get-instance-view -g "$RESOURCE_GROUP" -n "$VM_NAME" --query "storageProfile.imageReference.publisher" -o tsv 2>/dev/null); then
    echo "  Unable to determine the image publisher for $VM_NAME, skipping upgrade"
    SKIPPED_VMS=$((SKIPPED_VMS+1))
    continue
  fi

  echo "  Image publisher: ${PUBLISHER:-unknown}"

  # Skip if not a Canonical image (case insensitive)
  if [[ "$(echo "${PUBLISHER:-unknown}" | tr '[:upper:]' '[:lower:]')" != "canonical" ]]; then
    echo "  VM is not using an Ubuntu image published by Canonical, skipping upgrade"
    SKIPPED_NON_CANONICAL=$((SKIPPED_NON_CANONICAL+1))
    SKIPPED_VMS=$((SKIPPED_VMS+1))
    continue
  fi

  if [[ "$POWER_STATE" == "VM running" ]]; then
    echo "  VM is running, proceeding with upgrade operations..."
    RUNNING_VMS=$((RUNNING_VMS+1))

    echo "  Updating license type to UBUNTU_PRO..."
    if ! az_cli vm update -g "$RESOURCE_GROUP" -n "$VM_NAME" --license-type UBUNTU_PRO >/dev/null 2>&1; then
      echo "  WARNING: Failed to update license type for $VM_NAME. Skipping this VM."
      SKIPPED_VMS=$((SKIPPED_VMS+1))
      continue
    fi

    if ! az_cli vm wait --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --updated >/dev/null 2>&1; then
      echo "  WARNING: VM update wait did not complete for $VM_NAME. Continuing to check license state."
    fi

    attempt=1
    MAX_ATTEMPTS=3

    while [[ $attempt -le $MAX_ATTEMPTS ]]; do
      echo "Checking license type (Attempt $attempt/$MAX_ATTEMPTS)..."

      CURRENT_LICENSE=$(az_cli vm show \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --query "licenseType" \
        --output tsv 2>/dev/null || echo "")

      if [[ "$CURRENT_LICENSE" == "$DESIRED_LICENSE_TYPE" ]]; then
        echo "Success! License type is now: $CURRENT_LICENSE"
        sleep 3
        break
      fi

      echo "Current license: ${CURRENT_LICENSE:-None} (Waiting for $DESIRED_LICENSE_TYPE)"
      sleep "$SLEEP_DURATION"
      ((attempt++))
    done

    echo "  Installing and activating Ubuntu Pro..."
    if ! INSTALL_RESULT=$(az_cli vm run-command invoke -g "$RESOURCE_GROUP" -n "$VM_NAME" --command-id RunShellScript --scripts "sudo apt update && sudo apt install ubuntu-pro-client -y && sudo pro auto-attach" 2>&1); then
      echo "  ERROR: Ubuntu Pro installation or activation failed on $VM_NAME"
      echo "  Tag not added since installation failed"
      echo "  Installation output: $INSTALL_RESULT"
      continue
    fi

    echo "$INSTALL_RESULT"

    if [[ "$INSTALL_RESULT" != *"ProvisioningState/succeeded"* ]]; then
      echo "  WARNING: Azure did not report a successful RunCommand state for $VM_NAME, but the command was accepted."
      echo "  Proceeding to update the upgrade tag based on the command result."
    fi

    echo "  Adding tag $UPGRADE_TAG_NAME=$UPGRADE_TAG_VALUE and removing tag $TAG_NAME..."

    CURRENT_TAGS=$(az_cli vm show -g "$RESOURCE_GROUP" -n "$VM_NAME" --query tags -o json 2>/dev/null || echo '{}')
    UPDATED_TAGS=$(echo "$CURRENT_TAGS" | jq --arg tag "$TAG_NAME" 'del(.[$tag])')
    UPDATED_TAGS=$(echo "$UPDATED_TAGS" | jq --arg key "$UPGRADE_TAG_NAME" --arg value "$UPGRADE_TAG_VALUE" '. + {($key): $value}')

    if ! az_cli vm update -g "$RESOURCE_GROUP" -n "$VM_NAME" --set tags="$UPDATED_TAGS" >/dev/null 2>&1; then
      echo "  ERROR: Failed to update tags on $VM_NAME. The VM may still have been upgraded, but the tags were not changed."
      continue
    fi

    UPGRADED_VMS=$((UPGRADED_VMS+1))
    echo "  All operations completed successfully for $VM_NAME"
  else
    echo "  VM is not running (state: $POWER_STATE), skipping upgrade operations"
    STOPPED_VMS=$((STOPPED_VMS+1))
    SKIPPED_VMS=$((SKIPPED_VMS+1))
  fi
done

# Show summary
echo ""
echo "===== UPGRADE SUMMARY ====="
echo "Total VMs found with tag $TAG_NAME=$TAG_VALUE: $VM_COUNT"
echo "Running VMs: $RUNNING_VMS"
echo "Stopped VMs: $STOPPED_VMS"
echo "VMs upgraded to Ubuntu Pro: $UPGRADED_VMS"
echo "VMs skipped: $SKIPPED_VMS"
echo "  - Non-Canonical images: $SKIPPED_NON_CANONICAL"
echo "  - Stopped VMs: $STOPPED_VMS"
echo "=========================="

if [ $SKIPPED_VMS -gt 0 ]; then
  echo ""
  echo "NOTE: Some VMs were skipped for the following reasons:"

  if [ $SKIPPED_NON_CANONICAL -gt 0 ]; then
    echo "- $SKIPPED_NON_CANONICAL VMs were not running Ubuntu images from Canonical"
  fi

  if [ $STOPPED_VMS -gt 0 ]; then
    echo "- $STOPPED_VMS VMs were not running"
    echo "  To upgrade these VMs, start them and run this script again."
  fi
fi
