#!/usr/bin/env python3
# Script to sync and filter global dev.tfvars and prod.tfvars into individual infrastructure layers.

import os
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LAYERS = ["base", "networking", "data", "services"]

def get_declared_vars(variables_tf_path):
    if not os.path.exists(variables_tf_path):
        return set()
    with open(variables_tf_path, 'r') as f:
        content = f.read()
    # Find all variable "name"
    return set(re.findall(r'variable\s+"([^"]+)"', content))

def filter_tfvars(global_tfvars_path, declared_vars):
    if not os.path.exists(global_tfvars_path):
        return ""
    with open(global_tfvars_path, 'r') as f:
        lines = f.readlines()
        
    filtered_lines = []
    in_block = False
    
    # We want to preserve comments and blank lines, but only include assignments for declared_vars
    for line in lines:
        stripped = line.strip()
        # Check for assignment at the start of a line (top-level, no indentation)
        match = re.match(r'^([a-zA-Z0-9_-]+)\s*=', line)
        if match:
            var_name = match.group(1)
            if var_name in declared_vars:
                in_block = True
                filtered_lines.append(line)
            else:
                in_block = False
        elif in_block:
            filtered_lines.append(line)
        elif stripped == "" or stripped.startswith("#") or stripped.startswith("//"):
            # Keep comments/newlines
            filtered_lines.append(line)
            
    return "".join(filtered_lines)

print("Filtering and syncing global tfvars to layers...")

for layer in LAYERS:
    layer_dir = os.path.join(SCRIPT_DIR, layer)
    variables_tf = os.path.join(layer_dir, "variables.tf")
    declared_vars = get_declared_vars(variables_tf)
    
    print(f"-> Syncing to layers/{layer} ({len(declared_vars)} variables declared)...")
    
    for env in ["dev", "prod"]:
        # 1. Sync tfvars
        global_tfvars = os.path.join(SCRIPT_DIR, f"{env}.tfvars")
        layer_tfvars = os.path.join(layer_dir, f"{env}.tfvars")
        
        filtered_content = filter_tfvars(global_tfvars, declared_vars)
        
        header = (
            "# ==============================================================================\n"
            "# DO NOT TOUCH/EDIT THIS FILE DIRECTLY!\n"
            "# This file is AUTO-GENERATED from the global tfvars file above the layers:\n"
            f"#   infrastructure/layers/{env}.tfvars\n"
            "#\n"
            "# Run the sync script to update all layers:\n"
            "#   ./infrastructure/layers/sync_tfvars.py\n"
            "# ==============================================================================\n\n"
        )
        
        with open(layer_tfvars, 'w') as f:
            f.write(header + filtered_content)
            
        # 2. Sync and customize HTTP backend files
        global_backend = os.path.join(os.path.dirname(SCRIPT_DIR), f"{env}.http.tfbackend")
        layer_backend = os.path.join(layer_dir, f"{env}.http.tfbackend")
        
        if os.path.exists(global_backend):
            with open(global_backend, 'r') as f:
                backend_content = f.read()
            # Replace /state/{env} with /state/{env}-{layer} to segregate backend states
            backend_content = backend_content.replace(f"/state/{env}", f"/state/{env}-{layer}")
            with open(layer_backend, 'w') as f:
                f.write(backend_content)

print("Sync complete!")
