# Setup Instructions

This guide outlines the system requirements and setup steps needed to bootstrap and run this fullstack template.

---

## 🛠️ Prerequisites & System Requirements

Before setting up the project, ensure you have the following installed on your machine:

1. **Git**: Version control tool.
2. **Node.js**: Version 18+ (LTS recommended).
3. **Python**: Version 3.12+ (managed automatically via `uv`).
4. **pnpm**: Fast, disk space efficient package manager for Node.
   ```bash
   npm install -g pnpm
   ```
5. **uv**: Modern, high-performance Python package and project manager.
   ```bash
   curl -LsSf https://astral.sh/uv/install.sh | sh
   ```
6. **just**: A handy command runner to trigger project automation.
   - macOS (Homebrew): `brew install just`
   - Linux: `apt install just` or `pacman -S just`
   - Windows (Chocolatey): `choco install just`
7. **Docker & Docker Compose**: Needed to run the database services and local staging stack.
8. **gitleaks**: Tool for detecting hardcoded secrets like passwords, API keys, and tokens.
   - macOS (Homebrew): `brew install gitleaks`
   - Linux/Windows: Download from the official [Gitleaks releases](https://github.com/gitleaks/gitleaks/releases).

---

## 🚀 Step-by-Step Installation

Follow these steps to bootstrap the project on your machine:

### 1. Clone the Repository
```bash
git clone <repository-url>
cd webapp-template-python-react
```

### 2. Run the Bootstrap Recipe
The project includes a bootstrap script that automatically installs node modules, initializes python virtualenvs, and sets up Git pre-commit hooks:
```bash
just bootstrap
```
*(Alternatively, run `scripts/bootstrap.sh` directly if `just` is not configured.)*

### 3. Configure Environment Variables
Copy the template `.env.example` file to create your local `.env` configuration:
```bash
cp .env.example .env
```
Open the `.env` file and customize the secret keys and database configurations if necessary.

---

## 🖥️ Running the Development Stack

You can run the application either completely inside Docker containers, or locally on your host machine targeting a containerized database.

### Option A: Host Mode with Docker DB (Recommended)
This starts the Postgres database in Docker, while running the backend and frontend dev servers on your host machine for fast hot-reloading:
```bash
just dev
```

### Option B: Complete Docker Stack
This builds and runs all components (FastAPI backend, React frontend, and Postgres database) inside Docker:
```bash
just up
```
The default stack also starts the mandatory OpenTelemetry collector and Jaeger.
Jaeger is available at `http://localhost:16686`.
*To stop the stack, run:*
```bash
just down
```

## Azure Deployment Requirements

The template deploys only to Azure Container Apps using JFrog Artifactory.
Configure the masked GitLab variables `JFROG_REGISTRY`,
`ARTIFACTORY_USERNAME`, and `ARTIFACTORY_TOKEN`. Networking must be supplied
by Atlantis; provide the VNet and subnet component values in the environment
tfvars. The app subnet requires `Microsoft.App/environments` delegation and
the database subnet requires `Microsoft.DBforPostgreSQL/flexibleServers`
delegation.

---

## 🧪 Testing & Verification

To verify that your installation was successful and everything is configured correctly:

### Run Linter Suite
Check for any code formatting, styling, or type errors:
```bash
just lint
```

### Run Tests
Execute the unit testing framework (pytest for python, vitest for frontend):
```bash
just test
```

### Verify Git Hooks & Checkers
Run the test hook validator script to verify that all formatting, linting, secrets scanning (gitleaks), and commit style hooks operate correctly:
```bash
./scripts/test-validation-hooks.py
```

---

## 🔒 Security Scanning & Commit Hooks

This repository uses local pre-commit hooks to automate security auditing before code is committed.

- **Husky & Git Hooks**: During installation or bootstrapping, local hooks are set up to delegate to `scripts/security-scan.sh`.
- **Scan Checks**:
  1. **Secrets Detection**: Scans the workspace using `gitleaks` for any plaintext credentials, passwords, or API keys.
  2. **Dependency Auditing**: Runs `pnpm audit` (for React frontend) and `pip-audit` (for FastAPI backend) if dependency manifest files (`package.json` or `pyproject.toml`) have been changed.
- **Bypassing (Not Recommended)**: To bypass the verification hook (e.g. for a draft commit), run `git commit -m "..." --no-verify`.
