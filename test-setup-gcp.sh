#!/bin/bash
set -e

# Test environment setup/teardown for upgrade-script-gcp.sh
#
# Creates VMs covering all scenarios the upgrade script must handle:
#
#  VM name suffix              Image               Label              Running?  Expected outcome
#  --------------------------  ------------------  -----------------  --------  ----------------------
#  ubuntu2004-target           Ubuntu 20.04 LTS    toupgrade=true     yes       UPGRADED
#  ubuntu2204-target           Ubuntu 22.04 LTS    toupgrade=true     yes       UPGRADED
#  ubuntu2404-target           Ubuntu 24.04 LTS    toupgrade=true     yes       UPGRADED
#  ubuntu2204-stopped          Ubuntu 22.04 LTS    toupgrade=true     NO        SKIPPED (not running)
#  debian-noncanonical         Debian 12           toupgrade=true     yes       SKIPPED (not Canonical)
#  rocky-noncanonical          Rocky Linux 9       toupgrade=true     yes       SKIPPED (not Canonical)
#  ubuntu2204-nolabel          Ubuntu 22.04 LTS    (none)             yes       NOT FOUND
#  ubuntu2204-already-upgraded Ubuntu 22.04 LTS    upgraded=true      yes       NOT FOUND

PROJECT_ID=""
ZONE="us-central1-a"
MACHINE_TYPE="e2-micro"
DEFAULT_BOOT_DISK_SIZE_GB=10
LABEL_KEY="toupgrade"
LABEL_VALUE="true"
PREFIX="ubpro-test"
CLEANUP="false"

# Parse named parameters
for arg in "$@"; do
  case $arg in
    project=*)
      PROJECT_ID="${arg#*=}"
      ;;
    zone=*)
      ZONE="${arg#*=}"
      ;;
    prefix=*)
      PREFIX="${arg#*=}"
      ;;
    label=*)
      LABEL_KEY="${arg#*=}"
      ;;
    value=*)
      LABEL_VALUE="${arg#*=}"
      ;;
    cleanup=*)
      CLEANUP="${arg#*=}"
      ;;
    *)
      echo "WARNING: Unknown parameter: $arg"
      ;;
  esac
done

# Verify required parameters
if [ -z "$PROJECT_ID" ]; then
  echo "ERROR: Project ID is required with the project= parameter"
  echo ""
  echo "Usage:"
  echo "  Create test VMs:   $0 project=ProjectID [zone=Zone] [prefix=NamePrefix] [label=LabelKey] [value=LabelValue]"
  echo "  Delete test VMs:   $0 project=ProjectID [zone=Zone] [prefix=NamePrefix] cleanup=true"
  echo ""
  echo "Example: $0 project=my-gcp-project zone=us-central1-a"
  exit 1
fi

# ─── CLEANUP MODE ────────────────────────────────────────────────────────────
if [[ "$CLEANUP" == "true" ]]; then
  echo "Searching for test VMs with prefix '$PREFIX' in project $PROJECT_ID..."

  VM_LIST=$(gcloud compute instances list \
    --project="$PROJECT_ID" \
    --filter="name~^$PREFIX" \
    --format="json(name,zone)" \
    --quiet)

  VM_COUNT=$(echo "$VM_LIST" | jq '. | length')

  if [ "$VM_COUNT" -eq 0 ]; then
    echo "No test VMs found with prefix '$PREFIX'. Nothing to clean up."
    exit 0
  fi

  echo "Found $VM_COUNT VM(s) to delete:"
  echo "$VM_LIST" | jq -r '.[] | "  - \(.name) (\(.zone | split("/") | last))"'
  echo ""
  read -rp "Proceed with deletion? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi

  while IFS= read -r row; do
    VM_NAME=$(echo "$row" | jq -r '.name')
    VM_ZONE=$(echo "$row" | jq -r '.zone' | awk -F'/' '{print $NF}')
    echo "Deleting $VM_NAME ($VM_ZONE)..."
    gcloud compute instances delete "$VM_NAME" \
      --zone="$VM_ZONE" \
      --project="$PROJECT_ID" \
      --quiet
  done < <(echo "$VM_LIST" | jq -c '.[]')

  echo ""
  echo "Cleanup complete. All test VMs deleted."
  exit 0
fi

# ─── CREATE MODE ─────────────────────────────────────────────────────────────
echo "Creating test VMs in project $PROJECT_ID (zone: $ZONE)..."
echo "Machine type: $MACHINE_TYPE | Name prefix: $PREFIX"
echo ""

# Resolve an available image family from a preferred list.
# Usage: resolve_image_family <image-project> <family1> <family2> ...
resolve_image_family() {
  local IMAGE_PROJECT="$1"
  shift

  local FAMILY
  for FAMILY in "$@"; do
    if gcloud compute images describe-from-family "$FAMILY" \
      --project="$IMAGE_PROJECT" \
      --format="value(name)" \
      --quiet >/dev/null 2>&1; then
      echo "$FAMILY"
      return 0
    fi
  done

  return 1
}

# Resolve image families with fallbacks so test setup remains stable over time.
UBUNTU2004_FAMILY=$(resolve_image_family "ubuntu-os-cloud" "ubuntu-2004-lts" "ubuntu-minimal-2004-lts" "ubuntu-2204-lts") || true
UBUNTU2204_FAMILY=$(resolve_image_family "ubuntu-os-cloud" "ubuntu-2204-lts" "ubuntu-minimal-2204-lts" "ubuntu-2404-lts") || true
UBUNTU2404_FAMILY=$(resolve_image_family "ubuntu-os-cloud" "ubuntu-2404-lts" "ubuntu-minimal-2404-lts" "ubuntu-2204-lts") || true
DEBIAN12_FAMILY=$(resolve_image_family "debian-cloud" "debian-12" "debian-12-bookworm" "debian-11") || true

ROCKY_PROJECT="rocky-linux-cloud"
ROCKY_FAMILY=$(resolve_image_family "$ROCKY_PROJECT" "rocky-linux-9" "rocky-linux-9-optimized-gcp") || true
if [ -z "$ROCKY_FAMILY" ]; then
  # Keep scenario non-Canonical if Rocky family is unavailable.
  ROCKY_PROJECT="debian-cloud"
  ROCKY_FAMILY="$DEBIAN12_FAMILY"
  echo "WARNING: Rocky Linux image family not found; using Debian fallback for non-Canonical scenario."
fi

if [ -z "$UBUNTU2004_FAMILY" ] || [ -z "$UBUNTU2204_FAMILY" ] || [ -z "$UBUNTU2404_FAMILY" ] || [ -z "$DEBIAN12_FAMILY" ]; then
  echo "ERROR: Could not resolve one or more required image families."
  echo "  Resolved values:"
  echo "    UBUNTU2004_FAMILY=${UBUNTU2004_FAMILY:-<none>}"
  echo "    UBUNTU2204_FAMILY=${UBUNTU2204_FAMILY:-<none>}"
  echo "    UBUNTU2404_FAMILY=${UBUNTU2404_FAMILY:-<none>}"
  echo "    DEBIAN12_FAMILY=${DEBIAN12_FAMILY:-<none>}"
  exit 1
fi

if [[ "$UBUNTU2004_FAMILY" != "ubuntu-2004-lts" ]]; then
  echo "WARNING: ubuntu-2004-lts not available; using '$UBUNTU2004_FAMILY' for the ubuntu2004 scenario."
fi

# Helper: create a VM and optionally stop it
# Args: name image-family image-project labels stop_after
create_vm() {
  local VM_NAME="$1"
  local IMAGE_FAMILY="$2"
  local IMAGE_PROJECT="$3"
  local LABELS="$4"      # comma-separated key=value pairs, or empty
  local STOP_AFTER="$5"  # "true" to stop after creation
  local REQUIRED_DISK_SIZE_GB
  local EFFECTIVE_DISK_SIZE_GB="$DEFAULT_BOOT_DISK_SIZE_GB"

  local label_flag=""
  if [ -n "$LABELS" ]; then
    label_flag="--labels=$LABELS"
  fi

  # Some images (for example Rocky Linux) require a larger minimum boot disk.
  REQUIRED_DISK_SIZE_GB=$(gcloud compute images describe-from-family "$IMAGE_FAMILY" \
    --project="$IMAGE_PROJECT" \
    --format="value(diskSizeGb)" \
    --quiet 2>/dev/null || echo "$DEFAULT_BOOT_DISK_SIZE_GB")

  if [[ "$REQUIRED_DISK_SIZE_GB" =~ ^[0-9]+$ ]] && [ "$REQUIRED_DISK_SIZE_GB" -gt "$EFFECTIVE_DISK_SIZE_GB" ]; then
    EFFECTIVE_DISK_SIZE_GB="$REQUIRED_DISK_SIZE_GB"
    echo "  Image requires at least ${REQUIRED_DISK_SIZE_GB}GB boot disk; using ${EFFECTIVE_DISK_SIZE_GB}GB."
  fi

  echo "  Creating $VM_NAME (image: $IMAGE_FAMILY from $IMAGE_PROJECT)..."
  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="${EFFECTIVE_DISK_SIZE_GB}GB" \
    --boot-disk-type=pd-standard \
    --no-address \
    $label_flag \
    --quiet > /dev/null

  if [[ "$STOP_AFTER" == "true" ]]; then
    echo "  Stopping $VM_NAME..."
    gcloud compute instances stop "$VM_NAME" \
      --zone="$ZONE" \
      --project="$PROJECT_ID" \
      --quiet
  fi
}

# ── Scenario 1: Ubuntu 20.04 — should be upgraded ──────────────────────────
create_vm \
  "${PREFIX}-ubuntu2004-target" \
  "$UBUNTU2004_FAMILY" \
  "ubuntu-os-cloud" \
  "${LABEL_KEY}=${LABEL_VALUE}" \
  "false"
echo "  [✓] ${PREFIX}-ubuntu2004-target — Ubuntu 20.04, running, ${LABEL_KEY}=${LABEL_VALUE}"

# ── Scenario 2: Ubuntu 22.04 — should be upgraded ──────────────────────────
create_vm \
  "${PREFIX}-ubuntu2204-target" \
  "$UBUNTU2204_FAMILY" \
  "ubuntu-os-cloud" \
  "${LABEL_KEY}=${LABEL_VALUE}" \
  "false"
echo "  [✓] ${PREFIX}-ubuntu2204-target — Ubuntu 22.04, running, ${LABEL_KEY}=${LABEL_VALUE}"

# ── Scenario 3: Ubuntu 24.04 — should be upgraded ──────────────────────────
create_vm \
  "${PREFIX}-ubuntu2404-target" \
  "$UBUNTU2404_FAMILY" \
  "ubuntu-os-cloud" \
  "${LABEL_KEY}=${LABEL_VALUE}" \
  "false"
echo "  [✓] ${PREFIX}-ubuntu2404-target — Ubuntu 24.04, running, ${LABEL_KEY}=${LABEL_VALUE}"

# ── Scenario 4: Ubuntu 22.04 stopped — should be skipped ───────────────────
create_vm \
  "${PREFIX}-ubuntu2204-stopped" \
  "$UBUNTU2204_FAMILY" \
  "ubuntu-os-cloud" \
  "${LABEL_KEY}=${LABEL_VALUE}" \
  "true"
echo "  [✓] ${PREFIX}-ubuntu2204-stopped — Ubuntu 22.04, STOPPED, ${LABEL_KEY}=${LABEL_VALUE}"

# ── Scenario 5: Debian 12 — should be skipped (not Canonical) ──────────────
create_vm \
  "${PREFIX}-debian-noncanonical" \
  "$DEBIAN12_FAMILY" \
  "debian-cloud" \
  "${LABEL_KEY}=${LABEL_VALUE}" \
  "false"
echo "  [✓] ${PREFIX}-debian-noncanonical — Debian 12, running, ${LABEL_KEY}=${LABEL_VALUE}"

# ── Scenario 6: Rocky Linux 9 — should be skipped (not Canonical) ──────────
create_vm \
  "${PREFIX}-rocky-noncanonical" \
  "$ROCKY_FAMILY" \
  "$ROCKY_PROJECT" \
  "${LABEL_KEY}=${LABEL_VALUE}" \
  "false"
echo "  [✓] ${PREFIX}-rocky-noncanonical — Rocky Linux 9, running, ${LABEL_KEY}=${LABEL_VALUE}"

# ── Scenario 7: Ubuntu 22.04, no label — should not be found ───────────────
create_vm \
  "${PREFIX}-ubuntu2204-nolabel" \
  "$UBUNTU2204_FAMILY" \
  "ubuntu-os-cloud" \
  "" \
  "false"
echo "  [✓] ${PREFIX}-ubuntu2204-nolabel — Ubuntu 22.04, running, no label"

# ── Scenario 8: Ubuntu 22.04, already upgraded — should not be found ────────
create_vm \
  "${PREFIX}-ubuntu2204-done" \
  "$UBUNTU2204_FAMILY" \
  "ubuntu-os-cloud" \
  "upgraded=true" \
  "false"
echo "  [✓] ${PREFIX}-ubuntu2204-done — Ubuntu 22.04, running, upgraded=true"

# ─── SUMMARY ─────────────────────────────────────────────────────────────────
echo ""
echo "===== TEST ENVIRONMENT READY ====="
echo "Project: $PROJECT_ID | Zone: $ZONE"
echo ""
echo "VM Name                              Image            Label                  Running  Expected"
echo "-----------------------------------  ---------------  ---------------------  -------  ---------------------------"
printf "%-36s %-16s %-22s %-8s %s\n" "${PREFIX}-ubuntu2004-target"    "Ubuntu 20.04"   "${LABEL_KEY}=${LABEL_VALUE}"  "yes"    "UPGRADED"
printf "%-36s %-16s %-22s %-8s %s\n" "${PREFIX}-ubuntu2204-target"    "Ubuntu 22.04"   "${LABEL_KEY}=${LABEL_VALUE}"  "yes"    "UPGRADED"
printf "%-36s %-16s %-22s %-8s %s\n" "${PREFIX}-ubuntu2404-target"    "Ubuntu 24.04"   "${LABEL_KEY}=${LABEL_VALUE}"  "yes"    "UPGRADED"
printf "%-36s %-16s %-22s %-8s %s\n" "${PREFIX}-ubuntu2204-stopped"   "Ubuntu 22.04"   "${LABEL_KEY}=${LABEL_VALUE}"  "NO"     "SKIPPED (not running)"
printf "%-36s %-16s %-22s %-8s %s\n" "${PREFIX}-debian-noncanonical"  "Debian 12"      "${LABEL_KEY}=${LABEL_VALUE}"  "yes"    "SKIPPED (not Canonical)"
printf "%-36s %-16s %-22s %-8s %s\n" "${PREFIX}-rocky-noncanonical"   "Rocky Linux 9"  "${LABEL_KEY}=${LABEL_VALUE}"  "yes"    "SKIPPED (not Canonical)"
printf "%-36s %-16s %-22s %-8s %s\n" "${PREFIX}-ubuntu2204-nolabel"   "Ubuntu 22.04"   "(none)"                       "yes"    "NOT FOUND"
printf "%-36s %-16s %-22s %-8s %s\n" "${PREFIX}-ubuntu2204-done"      "Ubuntu 22.04"   "upgraded=true"                "yes"    "NOT FOUND"
echo ""
echo "Run the upgrade script against these VMs:"
echo "  ./upgrade-script-gcp.sh project=$PROJECT_ID zone=$ZONE label=$LABEL_KEY value=$LABEL_VALUE"
echo ""
echo "When done testing, clean up with:"
echo "  $0 project=$PROJECT_ID zone=$ZONE prefix=$PREFIX cleanup=true"
echo ""
echo "Image families used:"
echo "  ubuntu2004 scenario: $UBUNTU2004_FAMILY"
echo "  ubuntu2204 scenario: $UBUNTU2204_FAMILY"
echo "  ubuntu2404 scenario: $UBUNTU2404_FAMILY"
echo "  debian scenario: $DEBIAN12_FAMILY"
echo "  rocky scenario: $ROCKY_FAMILY (project: $ROCKY_PROJECT)"
echo "=================================="
