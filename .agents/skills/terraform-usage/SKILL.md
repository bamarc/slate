---
name: terraform-usage
description: 'Guide for working with the multi-layer OpenTofu/Terraform infrastructure. Use this when asked to deploy, plan, init, modify variables, or change cloud infrastructure configuration.'
allowed-tools: [shell]
---

# OpenTofu/Terraform Usage Skill

This project uses **OpenTofu** (or Terraform) to manage multi-layer cloud infrastructure on Azure.

## Infrastructure Directory Structure

```
infrastructure/
├── layers/                  # Multi-layer infrastructure deployments
│   ├── dev.tfvars           # SINGLE SOURCE OF TRUTH (DEV variables)
│   ├── prod.tfvars          # SINGLE SOURCE OF TRUTH (PROD variables)
│   ├── sync_tfvars.py       # Executable Python script to sync and filter tfvars
│   ├── base/                # Storage, managed identities, RBAC
│   ├── networking/          # VNet, Subnets, DNS, App Service Plans
│   ├── data/                # PostgreSQL Flexible Server, databases
│   └── services/            # App Service Web App / Container App deployments
```

All layers consume versioned OpenTofu modules published to the central GitLab Module Registry (`git.eon-cds.de/repos/*`), rather than local module paths.

---

## ⚠️ TFVARS Synchronization Rules

**NEVER touch or edit `.tfvars` files directly inside individual layer directories (`base`, `networking`, etc.)!** 
Any direct edits to layer-specific `.tfvars` will be overwritten on the next commit/sync.

1. **Edit Global Variables**: Always edit `/infrastructure/layers/dev.tfvars` or `/infrastructure/layers/prod.tfvars` (which contain the unified settings for all layers).
2. **Synchronize & Filter**: Run the sync script to automatically filter and update only the declared variables for each layer:
   ```bash
   ./infrastructure/layers/sync_tfvars.py
   ```
3. **Commit**: Pre-commit hooks are configured to run this synchronization automatically on every `git commit`.

---

## Core Variables & Modes

### 1. Networking Modes (`networking_mode`)
Configured in the `networking` layer:
* **`Standalone`**: Provisions a dedicated Azure VNet, delegated subnets, and PostgreSQL private DNS zone.
* **`Atlantis`**: Consumes existing VNet, subnets, and private DNS configurations. In `Atlantis` mode, the `existing_vnet_id` and delegated subnets are required inputs.

### 2. App Deployment Options (`app_deployment_type`)
Configured in the `services` layer:
* **`webapp`**: Deploys the service using Azure App Service (Linux Web App).
* **`containerapp`**: Deploys the service using Azure Container Apps & Environment.

---

## Common Commands

Always run OpenTofu commands inside the specific layer directory you want to manage (e.g. `infrastructure/layers/services`). The generated `dev.tfvars`/`prod.tfvars` and `*.http.tfbackend` files in that directory are the deployment inputs. The root environment backend files are templates consumed by `sync_tfvars.py`, not root-stack deployment inputs.

```bash
# Initialize OpenTofu with GitLab remote state backend
tofu init \
  -backend-config="address=${GITLAB_API_URL}/projects/${GITLAB_PROJECT_ID}/terraform/state/${LAYER_NAME}-${ENV_NAME}" \
  -backend-config="username=${GITLAB_USERNAME}" \
  -backend-config="password=${GITLAB_TOKEN}"

# Generate execution plan
tofu plan -var-file=dev.tfvars

# Apply plan
tofu apply -var-file=dev.tfvars
```

---

## Best Practices
1. **Apply Order**: When deploying from scratch, layers must be deployed sequentially: `base` → `networking` → `data` → `services`.
2. **Keyless Access**: Use Azure RBAC role assignments (`Storage Blob Data Contributor` via system-assigned/user-assigned managed identity) instead of using primary storage account keys.
3. **Artifactory Registry**: Target the corporate Artifactory registry (`repo.eon-cds.de`) instead of Azure Container Registry (ACR) for deploying container images.
