# Bulk Ubuntu Pro Upgrade Scripts

Scripts to automate bulk upgrading of Ubuntu VMs to Ubuntu Pro, available for both Azure and GCP.

---

## Azure — `upgrade-script.sh`

Finds VMs in a resource group with a specific tag, updates the license type to `UBUNTU_PRO`, installs the Ubuntu Pro client, and activates it with auto-attach.

### Features

- Finds VMs in a resource group with a specific tag (default: `toupgrade=true`)
- Verifies VM is running before attempting upgrade
- Verifies VM is using a Canonical image
- Updates the VM license type to `UBUNTU_PRO` (Azure BYOS/AHUB mechanism)
- Installs and activates Ubuntu Pro on the VM via `pro auto-attach`
- Removes the original tag and adds a new tag after successful upgrade (default: `upgraded=true`)
- Provides a detailed summary of processed and skipped VMs

### Usage

```bash
./upgrade-script.sh rg=ResourceGroupName [tag=TagName] [value=TagValue] [tagafter=UpgradeTagName] [valueafter=UpgradeTagValue]
```

### Parameters

- `rg`: (Required) The Azure resource group containing the VMs
- `tag`: (Optional) The tag name to identify VMs for upgrade (default: "toupgrade")
- `value`: (Optional) The tag value to identify VMs for upgrade (default: "true")
- `tagafter`: (Optional) The tag name to apply after successful upgrade (default: "upgraded")
- `valueafter`: (Optional) The tag value to apply after successful upgrade (default: "true")

### Example

```bash
./upgrade-script.sh rg=myResourceGroup tag=toupgrade value=true tagafter=upgraded valueafter=true
```

### Requirements

- Azure CLI (`az` command) must be installed and authenticated
- `jq` must be installed for JSON processing
- The user running the script must have permissions to:
  - List VMs in the resource group
  - Update VM properties (including license type and tags)
  - Run commands on VMs

### Limitations

- Only operates on running VMs (skips powered off VMs)
- Only processes Ubuntu VMs from Canonical (skips other images)
- Requires the target VM to have network connectivity

---

## GCP — `upgrade-script-gcp.sh`

Finds Compute Engine instances in a project with a specific label and upgrades eligible Ubuntu LTS VMs to Ubuntu Pro by replacing the boot disk license.

### Features

- Finds instances across all zones (or a specific zone) with a specific label (default: `toupgrade=true`)
- Verifies the instance is running before attempting upgrade
- Verifies the instance is using a Canonical Ubuntu image (`ubuntu-os-cloud` or `ubuntu-os-pro-cloud`)
- Maps the current Ubuntu LTS boot disk license to the matching Ubuntu Pro license
- Stops the VM, replaces the boot disk license, and starts the VM again
- Verifies the updated Pro license from disk and instance metadata
- Removes the original label and adds a new label after successful upgrade (default: `upgraded=true`)
- Retags VMs that are already on Ubuntu Pro
- Provides a detailed summary of processed and skipped instances

> **Note:** The GCP workflow is control-plane based. It does not require SSH access, guest-side `pro` commands, or package installation on the VM. The conversion is done by replacing the boot disk license with the matching Ubuntu Pro license.

### Usage

```bash
./upgrade-script-gcp.sh project=ProjectID [zone=Zone] [label=LabelKey] [value=LabelValue] [labelafter=UpgradeLabelKey] [valueafter=UpgradeLabelValue]
```

### Parameters

- `project`: (Required) The GCP project ID containing the instances
- `zone`: (Optional) Restrict to a specific zone (default: all zones)
- `label`: (Optional) The label key to identify instances for upgrade (default: "toupgrade")
- `value`: (Optional) The label value to identify instances for upgrade (default: "true")
- `labelafter`: (Optional) The label key to apply after successful upgrade (default: "upgraded")
- `valueafter`: (Optional) The label value to apply after successful upgrade (default: "true")

### Examples

```bash
# Basic usage across all zones
./upgrade-script-gcp.sh project=my-gcp-project

# Specific zone with custom labels
./upgrade-script-gcp.sh project=my-gcp-project zone=us-central1-a label=toupgrade value=true labelafter=upgraded valueafter=true
```

### Requirements

- Google Cloud CLI (`gcloud` command) must be installed and authenticated (`gcloud auth login`)
- `jq` must be installed for JSON processing
- The user running the script must have permissions to:
  - List and describe Compute Engine instances and disks
  - Stop and start Compute Engine instances
  - Update persistent disk licenses
  - Add and remove instance labels

### Limitations

- Only operates on running instances (skips stopped instances)
- Only processes Ubuntu instances from Canonical (skips other images)
- Only supports Ubuntu LTS releases that have an explicit license mapping in the script
- The VM is stopped and started during the upgrade
