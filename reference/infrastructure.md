# Infrastructure

## Important note

This infrastructure is normally deployed via the GitLab pipeline. Manual `tofu` commands are only intended for emergencies, debugging, or controlled maintenance.

## Environments

| Environment | Branch | Var-File | Backend-Config | GitLab State | Azure Resource Group | Atlantis (ITC) |
| --- | --- | --- | --- | --- | --- | --- |
| dev | `dev` | `dev.tfvars` | `dev.http.tfbackend` | `dev` | `rg-em-dkip-<segment>-<unit>-<app>-dev` | ITC claim repo |
| prod | `main` | `prod.tfvars` | `prod.http.tfbackend` | `prod` | `rg-em-dkip-<segment>-<unit>-<app>-prod` | ITC claim repo |

## GitLab State Backend

The OpenTofu state is stored in the GitLab project itself. Each infrastructure
layer has its own state. The root `infrastructure/dev.http.tfbackend` and
`infrastructure/prod.http.tfbackend` files are templates used by
`infrastructure/layers/sync_tfvars.py`; generated layer backend files are used
for deployments.

- State API base: `https://git.eon-cds.de/api/v4/projects/<PROJECT_ID>/terraform/state`
- Azure region: `germanywestcentral`

## Manual emergency commands

### Prerequisites

```bash
export TF_HTTP_USERNAME="<gitlab-username>"
export TF_HTTP_PASSWORD="<personal-access-token>"
```

Additionally an Azure login with sufficient rights is required.

### Dev

```bash
cd infrastructure/layers/services
tofu init -reconfigure -backend-config=dev.http.tfbackend

tofu plan -var-file=dev.tfvars
tofu apply -var-file=dev.tfvars
```

### Prod

```bash
cd infrastructure/layers/services
tofu init -reconfigure -backend-config=prod.http.tfbackend

tofu plan -var-file=prod.tfvars
tofu apply -var-file=prod.tfvars
```

## Operational notes

- The pipeline is the standard path for `plan` and `apply`.
- Run commands from the selected layer directory (`base`, `networking`, `data`, or `services`) and use that layer's generated `dev.tfvars`/`prod.tfvars` and backend file.
- The root environment backend files are sync-script templates only; do not use them as root-stack deployment inputs.
- Always run `python3 infrastructure/layers/sync_tfvars.py` (or `just sync`) whenever you modify the root `dev.tfvars`, `prod.tfvars`, or backend configs.
