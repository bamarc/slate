#!/usr/bin/env python3
import sys
import re
import subprocess

# Standard commit types
VALID_TYPES = {"feat", "fix", "docs", "style", "refactor", "perf", "test", "chore", "ci"}

# Predefined body action categories
VALID_CATEGORIES = {"Added", "Removed", "Changed", "Fixed", "Updated", "Security"}

def get_current_branch():
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True,
            text=True,
            check=True
        )
        return result.stdout.strip()
    except Exception:
        return ""

def check_branch_rules(branch_name):
    if not branch_name:
        return

    # Check for direct commits to main, master, dev
    if branch_name in {"main", "master", "dev", "development"}:
        print("⚠️  WARNING: Direct commits to main/dev branches are discouraged. Please use feature branches.")

    # Check for ticket number in branch name (e.g. contains digits or ticket pattern like SPARK-123)
    has_ticket = re.search(r"(\b\d+\b|[A-Za-z0-9]+-\d+)", branch_name)
    if not has_ticket:
        print("⚠️  WARNING: Current branch name does not contain a ticket/issue number.")

def validate_commit_msg(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as error:
        print(f"❌ Error: Could not read commit message file '{filepath}': {error}")
        return False

    # Filter comments and DCO signatures from the validated message.
    clean_lines = [
        line.strip()
        for line in lines
        if not line.strip().startswith("#") and not line.strip().startswith("Signed-off-by:")
    ]

    if not clean_lines or not "".join(clean_lines).strip():
        print("❌ Error: Commit message is empty.")
        return False

    # 1. Validate Subject Line (first non-comment line)
    subject = clean_lines[0]
    
    # Subject line length check
    if len(subject) > 100:
        print(f"❌ Error: Subject line exceeds 100 characters (currently {len(subject)}).")
        return False

    # Subject line pattern check: type(#ticket-id-short-name): summary OR type: summary
    pattern_with_ticket = r"^([a-z]+)\(#([A-Za-z0-9_.-]+)\):\s+(.+)$"
    pattern_without_ticket = r"^([a-z]+):\s+(.+)$"
    
    match = re.match(pattern_with_ticket, subject)
    has_ticket = True
    
    if not match:
        match = re.match(pattern_without_ticket, subject)
        has_ticket = False
        
    if not match:
        print("❌ Error: Subject line does not match the format: <type>(#<ticket-id>-<ticket-short-name>): <summary> OR <type>: <summary>")
        print("   Example: feat(#105-security-hooks): integrate husky with gitleaks scanning")
        print("   Example: feat: integrate husky with gitleaks scanning")
        return False

    commit_type = match.group(1)
    
    if commit_type not in VALID_TYPES:
        print(f"❌ Error: Invalid commit type '{commit_type}'. Must be one of: {', '.join(sorted(VALID_TYPES))}")
        return False

    if has_ticket:
        ticket_id = match.group(2)
        if "-" not in ticket_id:
            print(f"❌ Error: Ticket ID '{ticket_id}' must include a short name (e.g., #105-husky or #SPARK-105-husky).")
            return False
    else:
        print("⚠️  WARNING: Commit message does not contain a ticket/issue number.")

    # 2. Validate Body
    body_lines = [line for line in clean_lines[1:] if line.strip()]

    if not body_lines:
        print("❌ Error: Commit message body is required and must contain a list of changes.")
        print("   Example:")
        print("   - Added: gitleaks check to pre-commit hook")
        return False

    bullet_pattern = r"^-\s+([A-Za-z]+):\s+(.+)$"
    for line in body_lines:
        match_bullet = re.match(bullet_pattern, line)
        if not match_bullet:
            print(f"❌ Error: Body line '{line}' must be a bullet point matching the format: - <Category>: <Description>")
            print(f"   Valid categories: {', '.join(sorted(VALID_CATEGORIES))}")
            return False
        
        category = match_bullet.group(1)
        # Case insensitive check, but we recommend matching capitalization
        matched_cat = next((c for c in VALID_CATEGORIES if c.lower() == category.lower()), None)
        if not matched_cat:
            print(f"❌ Error: Invalid action category '{category}' in line '{line}'.")
            print(f"   Must be one of: {', '.join(sorted(VALID_CATEGORIES))}")
            return False

    return True

def main():
    if len(sys.argv) < 2:
        print("Usage: validate-commit-msg.py <commit-msg-file>")
        sys.exit(1)

    branch = get_current_branch()
    check_branch_rules(branch)

    filepath = sys.argv[1]
    if not validate_commit_msg(filepath):
        sys.exit(1)

    print("✅ Commit message format is valid.")
    sys.exit(0)

if __name__ == "__main__":
    main()
