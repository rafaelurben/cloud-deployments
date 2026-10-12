#!/usr/bin/env python3
from pathlib import Path
import sys
import yaml

root = Path(__file__).resolve().parents[1]
workflow_dir = root / ".github" / "workflows"

for workflow in workflow_dir.glob("*.yml"):
    try:
        with workflow.open("r", encoding="utf-8") as handle:
            yaml.safe_load(handle)
    except Exception as exc:
        print(f"Invalid workflow YAML: {workflow}: {exc}", file=sys.stderr)
        sys.exit(1)

print("Workflow YAML validation passed")
