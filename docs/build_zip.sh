#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZIP_NAME="PG_SICP_PRCSE_C1_Group6.zip"
CHECK_ONLY=0

if [[ "${1:-}" == "--check" ]]; then
    CHECK_ONLY=1
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0 [--check]"
    echo "  --check   Validate required deliverables without building the zip"
    exit 0
fi

cd "$ROOT_DIR"

required_files=(
    "report.pdf"
    "presentation.pptx"
    "README.md"
    "part1/provision.sh"
    "part2/audit.sh"
    "part2/audit.cron"
    "part3/analyze_auth.sh"
    "part3/output.txt"
    "pls/PL1.pdf"
    "pls/PL2.pdf"
)

missing=0
for f in "${required_files[@]}"; do
    if [[ ! -f "$f" ]]; then
        echo "[MISSING] $f"
        missing=1
    else
        echo "[OK]      $f"
    fi
done

check_dir_has_files() {
    local dir="$1"
    local pattern="$2"
    if [[ ! -d "$dir" ]] || ! find "$dir" -maxdepth 2 -type f -name "$pattern" ! -name '.gitkeep' | grep -q .; then
        echo "[MISSING] $dir (no matching '$pattern' files)"
        missing=1
    else
        echo "[OK]      $dir"
    fi
}

check_dir_has_files "pls/PL1_scripts" "*.sh"
check_dir_has_files "pls/PL2_scripts" "*.sh"
check_dir_has_files "tests" "*"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    exit "$missing"
fi

if [[ "$missing" -ne 0 ]]; then
    echo "Error: missing required deliverables. Fix the items above before packaging." >&2
    exit 1
fi

if ! command -v zip >/dev/null 2>&1; then
    echo "Error: 'zip' command not found. Install with: sudo apt install zip" >&2
    exit 1
fi

rm -f "$ZIP_NAME"
zip -r "$ZIP_NAME" \
    report.pdf \
    presentation.pptx \
    README.md \
    part1 \
    part2 \
    part3 \
    pls \
    tests \
    -x "*/.gitkeep" "pls/README.md"

echo "Created $ROOT_DIR/$ZIP_NAME successfully."
