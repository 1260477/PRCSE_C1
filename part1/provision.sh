#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: provision.sh [-h] [--dry-run] <employees.csv> <access-policy.csv>

Synchronize Linux users, groups, shared folders, ACLs, and offboarding
from the HR employee export and access policy CSV.

Options:
  --dry-run   Print what would change without modifying the system
  -h, --help  Show this help message and exit

Exit codes:
  0  Everything applied
  1  Fatal error (not root, missing file, wrong header, etc.)
  2  Finished, but some rows were rejected
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

echo "TODO: implement provision.sh" >&2
exit 1
