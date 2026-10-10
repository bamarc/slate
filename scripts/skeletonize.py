#!/usr/bin/env python3
"""
scripts/skeletonize.py — Deterministic Skeletonizer for SPARK Fullstack Template

Generates the Backstage-ready template skeleton from the working application codebase.
Replaces concrete baseline identifiers (e.g. fullstack-template, template-db, tfvars)
with Backstage Scaffolder placeholders (${{ values.* }} and Nunjucks/Jinja tags).

Usage:
    uv run python scripts/skeletonize.py --dry-run
    uv run python scripts/skeletonize.py --output-dir /path/to/output
    uv run python scripts/skeletonize.py --to-branch main
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


# Files and directories completely excluded from the skeleton
EXCLUDE_DIRS = {
    ".git",
    ".venv",
    "node_modules",
    "dist",
    "build",
    "__pycache__",
    ".pytest_cache",
    ".vitest_cache",
    ".coverage",
    "htmlcov",
    ".mypy_cache",
    ".ruff_cache",
    ".eslintcache",
    ".vite",
    ".antigravity",
    ".cursorrules",
    ".kilo",
    ".idea",
    ".husky",
    "plans",
}

EXCLUDE_FILES = {
    ".DS_Store",
    ".env",  # Exclude dev secrets/credentials; keep .env.example
}

# Text extensions eligible for content replacements
TEXT_EXTENSIONS = {
    ".py",
    ".toml",
    ".json",
    ".yaml",
    ".yml",
    ".md",
    ".sh",
    ".ini",
    ".ts",
    ".tsx",
    ".html",
    ".css",
    ".js",
    ".conf",
    ".txt",
    ".tfvars",
    ".tf",
    ".tfbackend",
    ".lock",
}

CATALOG_INFO_TEMPLATE = """apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: ${{ values.projectName }}
  title: ${{ values.projectTitle }}
  description: ${{ values.projectDescription }}
  tags:
    - python
    - fastapi
    - react
    - typescript
    - opentofu
    - gitlab-ci
    - spark
  annotations:
    backstage.io/techdocs-ref: dir:.
spec:
  type: service
  lifecycle: experimental
  owner: ${{ values.owner }}
  system: ${{ values.system }}
  providesApis:
    - ${{ values.projectName }}-api
---
apiVersion: backstage.io/v1alpha1
kind: API
metadata:
  name: ${{ values.projectName }}-api
  title: ${{ values.projectTitle }} API
  description: Contract-first OpenAPI specification for ${{ values.projectName }}
  tags:
    - openapi
    - rest
    - spark
  annotations:
    backstage.io/techdocs-ref: dir:.
spec:
  type: openapi
  lifecycle: experimental
  owner: ${{ values.owner }}
  system: ${{ values.system }}
  definition: |
    openapi: "3.1.0"
    info:
      title: "${{ values.projectTitle }} API"
      version: "0.1.0"
      description: "Contract-first API specification for ${{ values.projectName }}"
    paths:
      /api/v1/health:
        get:
          operationId: healthCheck
          summary: Health check endpoint
          responses:
            "200":
              description: Service is healthy
      /api/v1/items:
        get:
          operationId: listItems
          summary: List items (paginated)
        post:
          operationId: createItem
          summary: Create a new item
      /api/v1/items/{item_id}:
        get:
          operationId: getItem
          summary: Get an item by ID
"""


def should_ignore(path: Path, root: Path) -> bool:
    """Return True if path should be excluded from skeleton."""
    rel = path.relative_to(root)
    for part in rel.parts:
        if part in EXCLUDE_DIRS:
            return True
    if path.name in EXCLUDE_FILES:
        return True
    if path.name.endswith(".pyc"):
        return True
    return False


def apply_file_transformations(rel_path: str, content: str) -> tuple[str, bool]:
    """Applies file-specific and global replacements for Backstage templating."""
    modified = False

    # 1. Special Handling: catalog-info.yaml (keep static for Backstage template discovery via Location)
    # 1. Special Handling: catalog-info.yaml (keep static for Backstage template discovery via Location)
    if rel_path == "catalog-info.yaml":
        return content, False

    # 2. Special Handling: .gitlab-ci.yml
    if rel_path == ".gitlab-ci.yml":
        ci_replacements = [
            ("image_name: 'fullstack-template'", "image_name: '${{ values.projectName }}'"),
            ("jfrog_registry: 'repo.eon-cds.de/dkipac1gridtemplate-docker'", "jfrog_registry: '${{ values.jfrogRegistry }}'"),
            ("containerapp_name_dev: 'ca-fullstack-template-dev-api'", "containerapp_name_dev: 'ca-${{ values.projectName }}-dev-api'"),
            ("container_name_dev: 'fullstack-template-dev-api'", "container_name_dev: '${{ values.projectName }}-dev-api'"),
            ("resource_group_dev: 'rg-em-dkip-ac1-grid-Z-B-fullstack-template-dev'", "resource_group_dev: '${{ values.resourceGroupDev }}'"),
            ("containerapp_name_stage: 'ca-fullstack-template-stage-api'", "containerapp_name_stage: 'ca-${{ values.projectName }}-stage-api'"),
            ("container_name_stage: 'fullstack-template-stage-api'", "container_name_stage: '${{ values.projectName }}-stage-api'"),
            ("resource_group_stage: 'rg-em-dkip-ac1-grid-Z-B-fullstack-template-stage'", "resource_group_stage: '${{ values.resourceGroupStage }}'"),
            ("containerapp_name_prod: 'ca-fullstack-template-prod-api'", "containerapp_name_prod: 'ca-${{ values.projectName }}-prod-api'"),
            ("container_name_prod: 'fullstack-template-prod-api'", "container_name_prod: '${{ values.projectName }}-prod-api'"),
            ("resource_group_prod: 'rg-em-dkip-ac1-grid-Z-B-fullstack-template-prod'", "resource_group_prod: '${{ values.resourceGroupProd }}'"),
        ]
        for src, dst in ci_replacements:
            if src in content:
                content = content.replace(src, dst)
                modified = True

    # 3. Special Handling: compose.yaml
    if rel_path == "compose.yaml":
        compose_replacements = [
            ("${COMPOSE_PROJECT_NAME:-fullstack-template}", "${COMPOSE_PROJECT_NAME:-${{ values.projectName }}}"),
            ("name: fullstack-template", "name: ${{ values.projectName }}"),
            ("container_name: template-db", "container_name: ${{ values.projectName }}-db"),
            ("container_name: template-backend", "container_name: ${{ values.projectName }}-backend"),
            ("container_name: template-jaeger", "container_name: ${{ values.projectName }}-jaeger"),
            ("container_name: template-otel-collector", "container_name: ${{ values.projectName }}-otel-collector"),
            ("container_name: template-frontend", "container_name: ${{ values.projectName }}-frontend"),
            ("container_name: template-test-db", "container_name: ${{ values.projectName }}-test-db"),
            (
                "OTEL_SERVICE_NAME: ${OTEL_SERVICE_NAME:-fullstack-template}",
                "OTEL_SERVICE_NAME: ${OTEL_SERVICE_NAME:-${{ values.projectName }}}",
            ),
            ("POSTGRES_DB: fullstack_template_test", "POSTGRES_DB: ${{ values.projectName | replace('-', '_') }}_test"),
            ("POSTGRES_DB: template_test", "POSTGRES_DB: ${{ values.projectName | replace('-', '_') }}_test"),
            ("name: template-network", "name: ${{ values.projectName }}-network"),
            ("name: template_pgdata", "name: ${{ values.projectName | replace('-', '_') }}_pgdata"),
            ("name: template_pgdata_test", "name: ${{ values.projectName | replace('-', '_') }}_pgdata_test"),
            ("fullstack_template_pgdata_test", "${{ values.projectName | replace('-', '_') }}_pgdata_test"),
            ("fullstack_template_pgdata", "${{ values.projectName | replace('-', '_') }}_pgdata"),
            ("fullstack_template_test", "${{ values.projectName | replace('-', '_') }}_test"),
        ]
        for src, dst in compose_replacements:
            if src in content:
                content = content.replace(src, dst)
                modified = True

    # 4. Special Handling: README.md
    if rel_path == "README.md":
        old_intro = (
            "# ${{ values.projectName }}\n\n"
            "An enterprise-grade, contract-first, and containerized starter kit aligning state-of-the-art "
            "software engineering practices across **FastAPI**, **React SPA (Vite)**, and secure "
            "**Azure/Artifactory** cloud native environments."
        )
        new_intro = (
            "# ${{ values.projectTitle }} (`${{ values.projectName }}`)\n\n"
            "> ${{ values.projectDescription }}\n\n"
            "- **Jira Onboarding Ticket**: `${{ values.jiraTicket }}`\n"
            "- **LeanIX Application ID (APL)**: `${{ values.aplId }}`\n"
            "- **Application Class**: `${{ values.applicationClass | upper }}`\n"
            "- **Domain**: `${{ values.domain }}`\n"
            "- **Contact Person**: `${{ values.contactPerson }}`"
        )
        if old_intro in content:
            content = content.replace(old_intro, new_intro)
            modified = True
        elif "# ${{ values.projectName }}" in content:
            content = content.replace("# ${{ values.projectName }}", "# ${{ values.projectTitle }} (`${{ values.projectName }}`)")
            modified = True

        if "ultimate-template:local" in content:
            content = content.replace("ultimate-template:local", "${{ values.projectName }}:local")
            modified = True

    # 5. Special Handling: .env.example
    if rel_path == ".env.example":
        env_replacements = [
            ("COMPOSE_PROJECT_NAME=fullstack-template", "COMPOSE_PROJECT_NAME=${{ values.projectName }}"),
            ("POSTGRES_DB=fullstack_template", "POSTGRES_DB=${{ values.projectName | replace('-', '_') }}"),
            (
                "DATABASE_URL=postgresql+asyncpg://postgres:change-me@db:5432/fullstack_template",
                "DATABASE_URL=postgresql+asyncpg://postgres:change-me@db:5432/${{ values.projectName | replace('-', '_') }}",
            ),
            ("OTEL_SERVICE_NAME=fullstack-template", "OTEL_SERVICE_NAME=${{ values.projectName }}"),
        ]
        for src, dst in env_replacements:
            if src in content:
                content = content.replace(src, dst)
                modified = True

    # 6. Special Handling: tfvars
    if rel_path.endswith(".tfvars"):
        is_prod = "prod" in rel_path
        scope_suffix = "Prod" if is_prod else "Dev"
        env_name = "prod" if is_prod else "dev"

        tfvars_replacements = [
            (
                'subscription_id     = ""',
                f'subscription_id     = "${{{{ values.subscriptionId{scope_suffix} }}}}"',
            ),
            (
                'location            = "Germany West Central"',
                f'location            = "${{{{ values.location{scope_suffix} }}}}"',
            ),
            (
                'project_name        = "fullstack-template"',
                'project_name        = "${{ values.projectName }}"',
            ),
            (
                f'resource_group_name = "rg-em-dkip-ac2-shared-d-fullstack-template-{env_name}"',
                f'resource_group_name = "${{{{ values.resourceGroup{scope_suffix} }}}}"',
            ),
            (
                'resource_group_name = "rg-em-dkip-ac2-shared-p-fullstack-template-prod"',
                'resource_group_name = "${{ values.resourceGroupProd }}"',
            ),
            ('  "Project"             = "fullstack-template"', '  "Project"             = "${{ values.projectName }}"'),
            ('  "application-id"      = ""', '  "application-id"      = "${{ values.aplId }}"'),
            ('  "application-manager" = ""', '  "application-manager" = "${{ values.contactPerson }}"'),
            (
                '  "environment-id"      = ""',
                f'  "environment-id"      = "${{{{ values.itcId{scope_suffix} or values.jiraTicket }}}}"',
            ),
            ('product_name        = "webapp"', 'product_name        = "${{ values.projectName }}"'),
            ('fachbereich         = "d"', 'fachbereich         = "${{ values.domain }}"'),
            (
                'gitlab_project_path = "repos/ai-automation-envia/ops/webapp-template-python-react"',
                'gitlab_project_path = "${{ values.repoPath }}"',
            ),
            (
                'atlantis_subscription_id         = ""',
                f'atlantis_subscription_id         = "${{{{ values.networkSubscriptionId{scope_suffix} }}}}"',
            ),
            (
                'atlantis_vnet_rg                 = ""',
                f'atlantis_vnet_rg                 = "${{{{ values.atlantisVnetRg{scope_suffix} }}}}"',
            ),
            (
                'atlantis_vnet_name               = ""',
                f'atlantis_vnet_name               = "${{{{ values.atlantisVnetName{scope_suffix} }}}}"',
            ),
            (
                'atlantis_db_subnet_name          = ""',
                f'atlantis_db_subnet_name          = "${{{{ values.atlantisDbSubnetName{scope_suffix} }}}}"',
            ),
            (
                'atlantis_app_subnet_name         = ""',
                f'atlantis_app_subnet_name         = "${{{{ values.atlantisAppSubnetName{scope_suffix} }}}}"',
            ),
            ('database_sku_name        = "B_Standard_B1ms"', 'database_sku_name        = "${{ values.databaseSku }}"'),
            ('database_suffix          = ""', 'database_suffix          = "${{ values.databaseSuffix }}"'),
            (
                f'project_short       = "em-dkip-webapp-{env_name}"',
                f'project_short       = "em-dkip-${{{{ values.projectName }}}}-{env_name}"',
            ),
            ('app_image           = "fullstack-template"', 'app_image           = "${{ values.projectName }}"'),
            ('jfrog_registry      = "repo.eon-cds.de"', 'jfrog_registry      = "${{ values.jfrogRegistry }}"'),
            (
                'repository = "fullstack-template-docker"',
                'repository = "${{ values.jfrogRepositoryKey }}"',
            ),
        ]
        for src, dst in tfvars_replacements:
            if src in content:
                content = content.replace(src, dst)
                modified = True

    # 7. Special Handling: variables.tf
    if rel_path == "infrastructure/variables.tf":
        src = '  default     = "fullstack-template"'
        dst = '  default     = "${{ values.projectName }}"'
        if src in content:
            content = content.replace(src, dst)
            modified = True

    # 8. Special Handling: backend/config.yaml
    if rel_path == "backend/config.yaml":
        yaml_replacements = [
            ('app_name: "Fullstack Template API"', 'app_name: "${{ values.projectTitle }} API"'),
            ('otel_service_name: "${{ values.projectName }}"', 'otel_service_name: "${{ values.projectName }}"'),
        ]
        for src, dst in yaml_replacements:
            if src in content:
                content = content.replace(src, dst)
                modified = True

    # 9. Special Handling: api/openapi.yaml
    if rel_path == "api/openapi.yaml":
        api_replacements = [
            ('title: "Fullstack Template API"', 'title: "${{ values.projectTitle }} API"'),
            (
                'description: "Contract-first API specification for the fullstack template project"',
                'description: "Contract-first API specification for ${{ values.projectName }}"',
            ),
        ]
        for src, dst in api_replacements:
            if src in content:
                content = content.replace(src, dst)
                modified = True

    # 10. Standard Global Replacement Pairs (Order matters: specific before general)
    global_replacements = [
        # Remote State HTTP Backend
        ('${{ values.gitlabProjectId }}', '${{ values.gitlabProjectId }}'),

        # Database and configuration
        (
            'sqlalchemy.url = postgresql://postgres:postgres@localhost:5432/${{ values.projectName | replace('-', '_') }}',
            'sqlalchemy.url = postgresql://postgres:postgres@localhost:5432/${{ values.projectName | replace(\'-\', \'_\') }}',
        ),
        (
            'database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/${{ values.projectName | replace('-', '_') }}"',
            'database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/${{ values.projectName | replace(\'-\', \'_\') }}"',
        ),
        (
            'mongodb_db_name: str = "${{ values.projectName | replace('-', '_') }}"',
            'mongodb_db_name: str = "${{ values.projectName | replace(\'-\', \'_\') }}"',
        ),
        (
            '"database_url": "postgresql+asyncpg://postgres:postgres@localhost:5432/${{ values.projectName | replace('-', '_') }}_test"',
            '"database_url": "postgresql+asyncpg://postgres:postgres@localhost:5432/${{ values.projectName | replace(\'-\', \'_\') }}_test"',
        ),
        (
            'export TEST_DATABASE_URL="${TEST_DATABASE_URL:-postgresql+asyncpg://postgres:postgres@localhost:${TEST_POSTGRES_PORT:-5434}/${{ values.projectName | replace('-', '_') }}_test}"',
            'export TEST_DATABASE_URL="${TEST_DATABASE_URL:-postgresql+asyncpg://postgres:postgres@localhost:${TEST_POSTGRES_PORT:-5434}/${{ values.projectName | replace(\'-\', \'_\') }}_test}"',
        ),

        # Frontend package.json & title
        ('"name": "${{ values.projectName }}-frontend"', '"name": "${{ values.projectName }}-frontend"'),
        ('<title>${{ values.projectTitle }}</title>', '<title>${{ values.projectTitle }}</title>'),
        
        # Backend pyproject.toml & config
        ('name = "${{ values.projectName }}-backend"', 'name = "${{ values.projectName }}-backend"'),
        ('description = "${{ values.projectDescription }}"', 'description = "${{ values.projectDescription }}"'),
        ('"${{ values.projectName }}-backend[migrations]"', '"${{ values.projectName }}-backend[migrations]"'),
        ('app_name: str = "${{ values.projectTitle }} API"', 'app_name: str = "${{ values.projectTitle }} API"'),
        ('otel_service_name: str = "${{ values.projectName }}"', 'otel_service_name: str = "${{ values.projectName }}"'),
        ('otel_service_name: "${{ values.projectName }}"', 'otel_service_name: "${{ values.projectName }}"'),

        # Justfile psql target
        ('"${POSTGRES_DB:-postgres}"', '"${POSTGRES_DB:-postgres}"'),

        # MkDocs
        ('site_name: ${{ values.projectTitle }} Documentation', 'site_name: ${{ values.projectTitle }} Documentation'),
        ('site_description: Documentation and development guides for ${{ values.projectTitle }}', 'site_description: Documentation and development guides for ${{ values.projectTitle }}'),
        ('site_name: ${{ values.projectName }} Documentation', 'site_name: ${{ values.projectName }} Documentation'),
        ('site_description: Documentation and development guides for ${{ values.projectName }}', 'site_description: Documentation and development guides for ${{ values.projectName }}'),

        # Markdown headers
        ('# ${{ values.projectName }}', '# ${{ values.projectName }}'),
        ('# ${{ values.projectName }}', '# ${{ values.projectName }}'),
        ('# ${{ values.projectName }}', '# ${{ values.projectName }}'),

        # Docker / Containers example json and Dockerfile
        ('"image_name": "${{ values.projectName }}-backend"', '"image_name": "${{ values.projectName }}-backend"'),
        ('"image_name": "${{ values.projectName }}-frontend"', '"image_name": "${{ values.projectName }}-frontend"'),
        ('"containerapp_name": "ca-${{ values.projectName }}-${TARGET_ENV}-api"', '"containerapp_name": "ca-${{ values.projectName }}-${TARGET_ENV}-api"'),
        ('${{ values.projectName }}:latest', '${{ values.projectName }}:latest'),
        ('${{ values.projectName }}-ui:latest', '${{ values.projectName }}-ui:latest'),
        ('${{ values.projectName }}-api:latest', '${{ values.projectName }}-api:latest'),
    ]

    for src, dst in global_replacements:
        if src in content:
            content = content.replace(src, dst)
            modified = True

    return content, modified


def skeletonize(
    source_root: Path,
    target_root: Path | None,
    dry_run: bool = False,
) -> dict[str, str]:
    """Scans and transforms files from source_root into target_root."""
    transformed_files: dict[str, str] = {}
    copied_count = 0
    modified_count = 0

    for root, dirs, files in os.walk(source_root):
        # Exclude directories in-place to prevent traversing them
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]

        for file in files:
            src_path = Path(root) / file
            if should_ignore(src_path, source_root):
                continue

            rel_path = str(src_path.relative_to(source_root))
            ext = src_path.suffix.lower()

            try:
                if ext in TEXT_EXTENSIONS or file in {"Dockerfile", "Justfile", ".gitignore", "nginx.conf", ".env.example"}:
                    with open(src_path, "r", encoding="utf-8") as f:
                        content = f.read()

                    new_content, is_modified = apply_file_transformations(rel_path, content)
                    if is_modified:
                        modified_count += 1
                    transformed_files[rel_path] = new_content
                else:
                    # Binary or non-text file
                    if not dry_run and target_root:
                        dst_path = target_root / rel_path
                        dst_path.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copy2(src_path, dst_path)
                copied_count += 1
            except Exception as e:
                print(f"[!] Warning reading {rel_path}: {e}")

    # Write transformed text files if not dry-run
    if not dry_run and target_root:
        for rel_path, content in transformed_files.items():
            dst_path = target_root / rel_path
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            with open(dst_path, "w", encoding="utf-8") as f:
                f.write(content)

    return transformed_files


def sync_to_branch(source_root: Path, target_branch: str = "main"):
    """Safely transforms dev working tree and updates target_branch in git."""
    print(f"[*] Synchronizing Backstage skeleton to branch: '{target_branch}'...")

    # Verify git status
    res = subprocess.run(
        ["git", "status", "--porcelain"],
        cwd=source_root,
        capture_output=True,
        text=True,
        check=True,
    )
    uncommitted = [line for line in res.stdout.strip().splitlines() if not line.endswith("scripts/skeletonize.py")]
    if uncommitted:
        print("[!] Note: You have uncommitted changes on current branch.")

    # Step 1: Render transformed files in-memory
    print("[*] Generating skeleton transformation in-memory...")
    transformed_files = skeletonize(source_root, None, dry_run=False)

    template_yaml_path = source_root / "template.yaml"
    template_yaml_content = ""
    if template_yaml_path.exists():
        template_yaml_content = template_yaml_path.read_text(encoding="utf-8")

    # Current branch
    curr_branch = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=source_root,
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    print(f"[*] Current branch is '{curr_branch}'. Switching to '{target_branch}'...")
    subprocess.run(["git", "checkout", target_branch], cwd=source_root, check=True)

    try:
        # Write transformed files directly
        print(f"[*] Applying {len(transformed_files)} skeletonized files to '{target_branch}'...")
        for rel_path, content in transformed_files.items():
            dst = source_root / rel_path
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(content, encoding="utf-8")

        if template_yaml_content:
            (source_root / "template.yaml").write_text(template_yaml_content, encoding="utf-8")

        # Stage changes
        subprocess.run(["git", "add", "-A"], cwd=source_root, check=True)

        status_res = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=source_root,
            capture_output=True,
            text=True,
            check=True,
        )

        if not status_res.stdout.strip():
            print(f"[+] Branch '{target_branch}' is already up-to-date with skeleton.")
        else:
            commit_msg = (
                "chore: update Backstage skeleton from dev\n\n"
                "- Updated: template files with Backstage placeholders\n"
                "- Added: template.yaml at repository root"
            )
            subprocess.run(
                ["git", "commit", "--no-verify", "-m", commit_msg],
                cwd=source_root,
                check=True,
            )
            commit_hash = subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                cwd=source_root,
                capture_output=True,
                text=True,
                check=True,
            ).stdout.strip()
            print(f"[+] Successfully committed skeleton update to '{target_branch}' (commit: {commit_hash}).")

    finally:
        # Switch back to original branch
        print(f"[*] Switching back to '{curr_branch}'...")
        subprocess.run(["git", "checkout", curr_branch], cwd=source_root, check=True)

    print(f"\n[✓] Skeleton synchronization complete! '{target_branch}' is ready to be pushed with your SSH key.")


def main():
    parser = argparse.ArgumentParser(description="SPARK Fullstack Template Skeletonizer")
    parser.add_argument("--dry-run", action="store_true", help="Preview substitutions without modifying files")
    parser.add_argument("--output-dir", help="Output directory to write skeleton files")
    parser.add_argument("--to-branch", help="Git branch to commit skeleton to (e.g. main)")

    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent

    if args.to_branch:
        sync_to_branch(root, target_branch=args.to_branch)
        return

    if args.dry_run:
        print("[*] Running dry-run skeleton inspection...")
        transformed = skeletonize(root, None, dry_run=True)
        print(f"\n[+] Total text files processed: {len(transformed)}")
        print("[*] Sample placeholder verification:")
        for key in ["template.yaml", "compose.yaml", "README.md", ".env.example", "backend/pyproject.toml", "frontend/package.json", "infrastructure/layers/dev.tfvars"]:
            if key in transformed:
                has_placeholder = ("$" + "{{ values.") in transformed[key] or ("$" + "{{ parameters.") in transformed[key]
                status = "✓ OK" if has_placeholder else "! MISSING PLACEHOLDER"
                print(f"    - {key}: {status}")
        return

    if args.output_dir:
        out = Path(args.output_dir).resolve()
        out.mkdir(parents=True, exist_ok=True)
        print(f"[*] Writing skeleton to: {out}")
        skeletonize(root, out, dry_run=False)
        print("[+] Done!")
        return

    print("Please specify --dry-run, --output-dir, or --to-branch main.")


if __name__ == "__main__":
    main()
