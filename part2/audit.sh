#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: audit.sh [-h] --policy FILE [--full] [--state-dir DIR] [--report-dir DIR]

Daily security audit for srv-files01. Reports NEW and RESOLVED findings
compared to the previous run.

Options:
  --policy FILE       Path to access-policy.csv (required)
  --full              Print every current finding without using or changing state
  --state-dir DIR     Directory for audit state (default: /var/lib/audit)
  --report-dir DIR    Directory for daily reports (default: /var/log/audit)
  -h, --help          Show this help message and exit

Exit codes:
  0  No new findings
  1  Error
  2  New findings detected
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

echo "TODO: implement audit.sh" >&2
exit 1
