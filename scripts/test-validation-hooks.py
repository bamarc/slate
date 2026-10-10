#!/usr/bin/env python3
import os
import shutil
import tempfile
import subprocess
import sys

# Color codes for output
GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"

def print_result(name, passed, detail=""):
    status = f"{GREEN}PASS{RESET}" if passed else f"{RED}FAIL{RESET}"
    print(f"[{status}] {name}")
    if not passed and detail:
        print(f"      {detail}")

def run_cmd(args, cwd=None):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True)

def main():
    print("🧪 Starting Validation Hook Verification Test Script...\n")

    # Source files paths
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    validate_script_src = os.path.join(root_dir, "scripts", "validate-commit-msg.py")
    security_script_src = os.path.join(root_dir, "scripts", "security-scan.sh")
    
    # Path to ruff inside python virtualenv
    ruff_path = os.path.join(root_dir, "backend", ".venv", "bin", "ruff")
    if not os.path.exists(ruff_path):
        # Fallback to uv run ruff
        ruff_cmd = ["uv", "run", "ruff"]
    else:
        ruff_cmd = [ruff_path]

    # Create temporary directory simulating the repository environment
    temp_dir = tempfile.mkdtemp()
    try:
        # 1. Initialize temporary Git repository
        run_cmd(["git", "init", "-b", "main"], cwd=temp_dir)
        run_cmd(["git", "config", "user.name", "Test User"], cwd=temp_dir)
        run_cmd(["git", "config", "user.email", "test@example.com"], cwd=temp_dir)

        # Copy the validator scripts to the temporary environment
        temp_scripts_dir = os.path.join(temp_dir, "scripts")
        os.makedirs(temp_scripts_dir, exist_ok=True)
        validate_script = os.path.join(temp_scripts_dir, "validate-commit-msg.py")
        security_script = os.path.join(temp_scripts_dir, "security-scan.sh")
        shutil.copy(validate_script_src, validate_script)
        shutil.copy(security_script_src, security_script)
        os.chmod(validate_script, 0o755)
        os.chmod(security_script, 0o755)

        # Create a baseline commit so Git HEAD exists and Gitleaks can diff against it
        base_file = os.path.join(temp_dir, "init.txt")
        with open(base_file, "w") as f:
            f.write("initial setup")
        run_cmd(["git", "add", "init.txt"], cwd=temp_dir)
        run_cmd(["git", "commit", "-m", "chore(#0-init): initial baseline commit\n\n- Added: baseline"], cwd=temp_dir)

        # -------------------------------------------------------------
        # TEST GROUP 1: Commit Message Validation (validate-commit-msg.py)
        # -------------------------------------------------------------
        print("--- Testing Commit Message Rules ---")

        # Helper to test commit msg
        def test_commit_msg(msg):
            msg_file = os.path.join(temp_dir, "commit_msg_test.txt")
            with open(msg_file, "w", encoding="utf-8") as f:
                f.write(msg)
            # Run validate-commit-msg.py
            res = run_cmd(["python3", validate_script, msg_file], cwd=temp_dir)
            return res.returncode == 0, res.stdout, res.stderr

        # Test 1.1: Invalid commit type
        msg = "invalidtype(#123-husky-setup): some feature\n\n- Added: test message"
        passed, out, err = test_commit_msg(msg)
        print_result("Type Validation (Should Block 'invalidtype')", not passed, "Blocked as expected" if not passed else f"Allowed: {out}")

        # Test 1.2: Missing ticket name
        msg = "feat(#123): missing ticket name description\n\n- Added: test message"
        passed, out, err = test_commit_msg(msg)
        print_result("Ticket Format Validation (Should Block missing ticket-short-name)", not passed, "Blocked as expected" if not passed else f"Allowed: {out}")

        # Test 1.3: Empty body list
        msg = "feat(#123-husky-setup): add hooks"
        passed, out, err = test_commit_msg(msg)
        print_result("Body List Validation (Should Block empty body)", not passed, "Blocked as expected" if not passed else f"Allowed: {out}")

        # Test 1.4: Invalid category prefix in body
        msg = "feat(#123-husky-setup): add hooks\n\n- BadCategory: test message"
        passed, out, err = test_commit_msg(msg)
        print_result("Body Category Validation (Should Block 'BadCategory')", not passed, "Blocked as expected" if not passed else f"Allowed: {out}")

        # Test 1.5: Valid message structure with ticket
        msg = "feat(#123-husky-setup): add hooks\n\n- Added: gitleaks check to pre-commit hook\n- Changed: script validation configs"
        passed, out, err = test_commit_msg(msg)
        print_result("Subject & Body Validation with Ticket (Should Accept)", passed, f"Blocked: {out}")

        # Test 1.6: Valid message structure without ticket (Should accept but warn)
        msg = "feat: add hooks\n\n- Added: gitleaks check\n- Changed: script validation"
        passed, out, err = test_commit_msg(msg)
        warning_warn = "Commit message does not contain a ticket/issue number" in out
        print_result("Subject & Body Validation without Ticket (Should Accept & Warn)", passed and warning_warn, f"Blocked or Warning Missing: Passed={passed}, Warn={warning_warn}, Out={out}")


        # -------------------------------------------------------------
        # TEST GROUP 2: Branch Rule Warnings
        # -------------------------------------------------------------
        print("\n--- Testing Branch Rules & Warnings ---")

        # Test 2.1: Main branch commit warning
        # (We are currently on 'main' from the baseline commit)
        msg = "feat(#123-husky-setup): add hooks\n\n- Added: test"
        passed, out, err = test_commit_msg(msg)
        warning_matches = "Direct commits to main/dev branches are discouraged" in out
        print_result("Main/Dev Direct Commit Warning", warning_matches, "Warning message missing in output")

        # Test 2.2: Missing ticket ID in branch name warning
        run_cmd(["git", "checkout", "-b", "no-ticket-branch-name"], cwd=temp_dir)
        passed, out, err = test_commit_msg(msg)
        warning_matches = "branch name does not contain a ticket/issue number" in out
        print_result("Missing Ticket Branch Warning", warning_matches, "Warning message missing in output")


        # -------------------------------------------------------------
        # TEST GROUP 3: Secrets Detection (Gitleaks / security-scan.sh)
        # -------------------------------------------------------------
        print("\n--- Testing Secret Leaks Scanning (Gitleaks) ---")
        
        # Test 3.1: Commit blocked when staging an SSH private key
        leak_file = os.path.join(temp_dir, "test_private_key.pem")
        with open(leak_file, "w") as f:
            f.write("-----BEGIN OPENSSH PRIVATE KEY-----\n"
                    "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtcn\n"
                    "NhAAAAAwEAAQAAAYEA0K/3V\n"
                    "-----END OPENSSH PRIVATE KEY-----\n")
        
        # Stage the leak
        run_cmd(["git", "add", "test_private_key.pem"], cwd=temp_dir)
        
        # Run security-scan.sh
        res_sec = run_cmd([security_script], cwd=temp_dir)
        blocked_leak = res_sec.returncode != 0 and "Secrets detected in staged changes" in res_sec.stdout
        print_result("Gitleaks Secret Block (Should block SSH Private Key)", blocked_leak, f"Failed to block private key. Code: {res_sec.returncode}, Out: {res_sec.stdout}")

        # Test 3.2: Commit blocked when staging a vulnerable lockfile (OSV Scanner)
        if shutil.which("osv-scanner"):
            # Create a mock lockfile in frontend/pnpm-lock.yaml
            temp_frontend_dir = os.path.join(temp_dir, "frontend")
            os.makedirs(temp_frontend_dir, exist_ok=True)
            mock_lockfile = os.path.join(temp_frontend_dir, "pnpm-lock.yaml")
            with open(mock_lockfile, "w") as f:
                f.write("lockfileVersion: '9.0'\n"
                        "importers:\n"
                        "  .:\n"
                        "    dependencies:\n"
                        "      vite:\n"
                        "        specifier: ^6.4.2\n"
                        "        version: 6.4.2\n")
            
            # Stage the mock lockfile
            run_cmd(["git", "add", "frontend/pnpm-lock.yaml"], cwd=temp_dir)
            
            # Run security-scan.sh
            res_sec_osv = run_cmd([security_script], cwd=temp_dir)
            blocked_osv = res_sec_osv.returncode != 0 and "OSV Scanner found vulnerabilities" in res_sec_osv.stdout
            print_result("OSV Scanner Block (Should block vulnerable vite lockfile)", blocked_osv, f"Failed to block vulnerable lockfile. Code: {res_sec_osv.returncode}, Out: {res_sec_osv.stdout}")
        else:
            print("[INFO] osv-scanner not installed. Skipping OSV Scan integration test.")

        # -------------------------------------------------------------
        # TEST GROUP 4: Code Linting & Formatting Checker
        # -------------------------------------------------------------
        print("\n--- Testing Formatting Checker (Ruff) ---")

        # Test 4.1: Ruff formatter detection on poorly formatted code
        bad_code_file = os.path.join(temp_dir, "bad_format.py")
        with open(bad_code_file, "w") as f:
            f.write("def bad_format() :\n  x=1\n  return x")
        
        # Check if ruff format blocks it
        res_ruff = run_cmd(ruff_cmd + ["format", "--check", "bad_format.py"], cwd=temp_dir)
        ruff_blocked = res_ruff.returncode != 0
        print_result("Ruff Format Check (Should fail on poor spacing)", ruff_blocked, "Failed to identify spacing formatting errors")

        # Test 4.2: Ruff linter detection on unused imports
        with open(bad_code_file, "w") as f:
            f.write("import os\n\ndef my_func():\n    return 5")
            
        res_ruff_lint = run_cmd(ruff_cmd + ["check", "bad_format.py"], cwd=temp_dir)
        ruff_lint_blocked = res_ruff_lint.returncode != 0
        print_result("Ruff Lint Check (Should fail on unused imports)", ruff_lint_blocked, "Failed to identify unused import warnings")

    finally:
        # Cleanup temporary files
        shutil.rmtree(temp_dir)

if __name__ == "__main__":
    main()
