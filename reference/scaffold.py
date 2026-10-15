#!/usr/bin/env python3
"""
Scaffolding CLI script for the contract-first Fullstack Template.
Bootstraps a fresh, customized clone of this project in a few commands.
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import shutil
import subprocess
import sys


# Reconfigure standard streams to UTF-8 if supported (Python 3.7+) to support colored output and icons
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass


def print_banner():
    banner = """\033[1;35m
===================================================================
                    FULLSTACK TEMPLATE SCAFFOLDER                 
       React + Vite + TS  |  FastAPI + SQLAlchemy  |  OpenAPI     
===================================================================
\033[0m"""
    print(banner)


def prompt(text: str, default: str | None = None) -> str:
    """Prompt the user with colored console logs."""
    if default:
        val = input(f"\033[1;34m[i] {text}\033[0m [\033[33m{default}\033[0m]: ").strip()
        return val if val else default
    else:
        while True:
            val = input(f"\033[1;34m[i] {text}\033[0m: ").strip()
            if val:
                return val


def prompt_choice(text: str, choices: list[str], default: str) -> str:
    """Prompt the user for a choice from a list."""
    choices_str = "/".join(
        f"\033[32m{c}\033[0m" if c == default else c for c in choices
    )
    while True:
        val = input(f"\033[1;34m[i] {text}\033[0m ({choices_str}): ").strip()
        if not val:
            return default
        if val.lower() in [c.lower() for c in choices]:
            # return matching choice in correct casing
            return next(c for c in choices if c.lower() == val.lower())
        print(f"\033[1;31m[!] Invalid choice. Please choose from: {', '.join(choices)}\033[0m")


def copy_project(src: str, dst: str):
    """Recursively copy project files, excluding git and dev caches."""
    dst_real = os.path.realpath(dst)
    ignore_patterns = [
        ".git",
        ".anthropic",
        ".goose",
        ".kilocode",
        "scaffold.py",
        "__pycache__",
        ".venv",
        "node_modules",
        "dist",
        "tmp",
        ".pytest_cache",
        ".vitest_cache",
        "*.pyc",
        "*.egg-info",
        ".antigravity",
        ".codeiumrules",
        ".cursorrules",
    ]

    def ignore_func(directory, contents):
        dir_real = os.path.realpath(directory)
        if dir_real == dst_real or dir_real.startswith(dst_real + os.sep):
            return contents
        ignored = []
        for item in contents:
            full_item_path = os.path.realpath(os.path.join(directory, item))
            if full_item_path == dst_real or full_item_path.startswith(dst_real + os.sep):
                ignored.append(item)
                continue
            # Check if matching ignore patterns
            for pattern in ignore_patterns:
                if pattern.startswith("*"):
                    if item.endswith(pattern[1:]):
                        ignored.append(item)
                        break
                elif item == pattern or os.path.join(directory, item).endswith(pattern):
                    ignored.append(item)
                    break
        return ignored

    shutil.copytree(src, dst, ignore=ignore_func, dirs_exist_ok=True)


def replace_placeholders(dst_dir: str, replacements: dict[str, str]):
    """Walk through files in destination and replace placeholder strings."""
    # List of common text extensions to safely do replacement
    text_extensions = {
        ".py", ".toml", ".json", ".yaml", ".yml", ".md", ".sh", ".ini",
        ".ts", ".tsx", ".html", ".css", ".js", ".conf", ".txt", ".env",
        ".tfvars", ".tfbackend", ".tf"
    }

    for root, _, files in os.walk(dst_dir):
        for file in files:
            ext = os.path.splitext(file)[1]
            if ext in text_extensions or file in {".gitignore", "Dockerfile", ".env.example", "Justfile"}:
                file_path = os.path.join(root, file)
                try:
                    with open(file_path, "r", encoding="utf-8") as f:
                        content = f.read()

                    modified = False
                    for placeholder, value in replacements.items():
                        if placeholder in content:
                            content = content.replace(placeholder, value)
                            modified = True

                    if modified:
                        with open(file_path, "w", encoding="utf-8") as f:
                            f.write(content)
                except Exception as e:
                    print(f"\033[1;33m[!] Warning: Could not perform replacement in {file_path}: {e}\033[0m")


def configure_database(dst_dir: str, db_type: str, project_name: str):
    """Adjust compose.yaml and dependencies depending on selected Database."""
    compose_path = os.path.join(dst_dir, "compose.yaml")
    if not os.path.exists(compose_path):
        return

    if db_type == "MongoDB":
        # 1. Update compose.yaml to use Mongo
        mongo_compose = f"""services:
  db:
    image: mongo:7.0-alpine
    container_name: {project_name}-db
    restart: unless-stopped
    ports:
      - "27017:27017"
    volumes:
      - mongodb_data:/data/db

  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: {project_name}-backend
    restart: unless-stopped
    ports:
      - "8000:8000"
    environment:
      MONGODB_URL: mongodb://db:27017
      MONGODB_DB_NAME: {project_name.replace('-', '_')}
      CORS_ORIGINS: '["http://localhost", "http://localhost:5173", "http://localhost:80", "http://127.0.0.1"]'
    depends_on:
      - db
    command: >
      uv run uvicorn app.main:app --host 0.0.0.0 --port 8000

  frontend:
    build:
      context: ./frontend
      dockerfile: Dockerfile
    container_name: {project_name}-frontend
    restart: unless-stopped
    ports:
      - "80:80"
    depends_on:
      - backend

volumes:
  mongodb_data:
    name: {project_name.replace('-', '_')}_mongodb_data
"""
        with open(compose_path, "w", encoding="utf-8") as f:
            f.write(mongo_compose)
        print("[*] Custom compose.yaml configured for MongoDB.")
    else:
        print("[*] Custom compose.yaml configured for PostgreSQL.")


def generate_license(dst_dir: str, license_type: str, author: str, year: int):
    """Generate a LICENSE file in the target project root."""
    license_path = os.path.join(dst_dir, "LICENSE")
    
    mit_text = f"""MIT License

Copyright (c) {year} {author}

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

    apache_text = f"""                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

Copyright {year} {author}

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""

    bsd_text = f"""BSD 3-Clause License

Copyright (c) {year}, {author}
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""

    proprietary_text = f"""All Rights Reserved.

Copyright (c) {year} {author}

The academic/proprietary contents of this codebase belong solely to {author}.
Unauthorized copying of files, distribution, or modifications via any medium
is strictly prohibited.
"""

    text = ""
    if license_type == "MIT":
        text = mit_text
    elif license_type == "Apache-2.0":
        text = apache_text
    elif license_type == "BSD-3":
        text = bsd_text
    else:
        text = proprietary_text

    with open(license_path, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"[+] Custom {license_type} LICENSE file generated.")


def initialize_git(dst_dir: str):
    """Initialize a fresh Git repository and make an initial commit."""
    try:
        # Check if git is available
        subprocess.run(["git", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    except Exception:
        print("\033[1;33m[!] Warning: Git CLI is not installed or available. Skipping git initialization.\033[0m")
        return

    try:
        # 1. Git Init
        subprocess.run(["git", "init"], cwd=dst_dir, check=True, stdout=subprocess.DEVNULL)
        
        # 2. Git Add
        subprocess.run(["git", "add", "."], cwd=dst_dir, check=True, stdout=subprocess.DEVNULL)
        
        # 3. Git Commit
        subprocess.run(
            ["git", "commit", "-m", "feat: initial project bootstrap from fullstack-template"],
            cwd=dst_dir,
            check=True,
            stdout=subprocess.DEVNULL
        )
        print("[+] Fresh Git repository initialized and first commit created successfully!")
    except Exception as e:
        print(f"\033[1;31m[!] Error during Git initialization: {e}\033[0m")


def main():
    parser = argparse.ArgumentParser(description="Scaffold a new project from this template.")
    parser.add_argument("--name", help="New project name (kebab-case)")
    parser.add_argument("--description", help="Short description")
    parser.add_argument("--author", help="Author's name")
    parser.add_argument("--email", help="Author's email")
    parser.add_argument("--license", choices=["MIT", "Apache-2.0", "BSD-3", "Proprietary"], help="License type")
    parser.add_argument("--db", choices=["PostgreSQL", "MongoDB"], help="Database system")
    parser.add_argument("target_dir", nargs="?", help="Target directory for scaffolding")

    args = parser.parse_args()

    print_banner()

    # Determine running mode (interactive vs automated)
    is_interactive = not all([args.name, args.description, args.author, args.email, args.license, args.db])

    project_name = args.name
    if not project_name:
        if is_interactive:
            project_name = prompt("Project Name (kebab-case)", "my-awesome-app")
            # Enforce kebab-case
            project_name = re.sub(r'[^a-zA-Z0-9-]', '-', project_name).lower()
            project_name = re.sub(r'-+', '-', project_name).strip('-')
        else:
            project_name = "my-awesome-app"

    project_description = args.description or (
        prompt("Short Description", "A contract-first fullstack application") if is_interactive
        else "A contract-first fullstack application"
    )

    author = args.author or (
        prompt("Author's Name", "Marc") if is_interactive
        else "Marc"
    )

    email = args.email or (
        prompt("Author's Email", "marc@example.com") if is_interactive
        else "marc@example.com"
    )

    license_type = args.license or (
        prompt_choice("License Type", ["MIT", "Apache-2.0", "BSD-3", "Proprietary"], "MIT") if is_interactive
        else "MIT"
    )

    db_type = args.db or (
        prompt_choice("Database System", ["PostgreSQL", "MongoDB"], "PostgreSQL") if is_interactive
        else "PostgreSQL"
    )

    # Determine target directory
    default_dir = os.path.abspath(os.path.join(os.getcwd(), "..", project_name))
    target_dir = args.target_dir
    if not target_dir:
        if is_interactive:
            target_dir = prompt("Target Directory", default_dir)
        else:
            target_dir = default_dir
    target_dir = os.path.abspath(target_dir)

    print(f"\n\033[1;32m[+] Starting scaffolding to: {target_dir}...\033[0m")

    # Guard: Check if target directory already exists and is not empty
    if os.path.exists(target_dir) and os.listdir(target_dir):
        print(f"\033[1;31m[!] Error: Target directory '{target_dir}' already exists and is not empty!\033[0m")
        sys.exit(1)

    # Prepare custom replacement values
    project_snake = project_name.replace("-", "_")
    project_title = " ".join(word.capitalize() for word in project_name.split("-"))

    replacements = {
        "fullstack-template-backend": f"{project_name}-backend",
        "fullstack-template-frontend": f"{project_name}-frontend",
        "fullstack_template_test": f"{project_snake}_test",
        "fullstack_template": project_snake,
        "fullstack-template": project_name,
        "Fullstack Template API": f"{project_title} API",
        "Fullstack Template": project_title,
        "FastAPI backend for fullstack template": project_description,
        "repo.eon-cds.de/dkipac1gridtemplate-docker": f"repo.eon-cds.de/dkipac1grid{project_name}-docker",
        "fullstack-template-docker": f"{project_name}-docker",
        "em-dkip-webapp-dev": f"em-dkip-{project_name}-dev",
        "em-dkip-webapp-prod": f"em-dkip-{project_name}-prod",
        "rg-em-dkip-ac2-shared-d-fullstack-template-dev": f"rg-em-dkip-ac2-{project_name}-dev",
        "rg-em-dkip-ac2-shared-d-fullstack-template-prod": f"rg-em-dkip-ac2-{project_name}-prod",
        "rg-em-dkip-ac1-grid-Z-B-fullstack-template-dev": f"rg-em-dkip-ac2-{project_name}-dev",
        "rg-em-dkip-ac1-grid-Z-B-fullstack-template-stage": f"rg-em-dkip-ac2-{project_name}-stage",
        "rg-em-dkip-ac1-grid-Z-B-fullstack-template-prod": f"rg-em-dkip-ac2-{project_name}-prod",
        "repos/ai-automation-envia/ops/webapp-template-python-react": f"repos/{project_name}",
        "${{ values.gitlabProjectId }}": "00000",
    }

    # Execute Copying
    print("[+] Copying template structure...")
    copy_project(os.getcwd(), target_dir)

    # Database Customization
    configure_database(target_dir, db_type, project_name)

    # Perform Replacements
    print("[*] Customizing project files with replacements...")
    replace_placeholders(target_dir, replacements)

    # Generate License
    generate_license(target_dir, license_type, author, datetime.datetime.now().year)

    # Initialize Git
    initialize_git(target_dir)

    print(f"\n\033[1;32m[+] Success! {project_title} has been successfully bootstrapped at:\033[0m")
    print(f"\033[36m--> {target_dir}\033[0m\n")
    print("To get started running the project locally:")
    print(f"  1. \033[1mcd {os.path.relpath(target_dir, os.getcwd()) if os.getcwd() in target_dir else target_dir}\033[0m")
    print("  2. \033[1mdocker compose up --build\033[0m (or podman compose up --build)")


if __name__ == "__main__":
    main()
