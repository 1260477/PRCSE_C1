#!/usr/bin/env bash
set -euo pipefail

# Testes automatizados da Fase 3 (offboarding e desaparecimentos) via --dry-run
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROVISION="${REPO_ROOT}/part1/provision.sh"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

assert_contains() {
    local name="$1"
    local needle="$2"
    local haystack="$3"

    if echo "$haystack" | grep -qF "$needle"; then
        echo "[PASS] $name"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $name (missing: '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1"
    local needle="$2"
    local haystack="$3"

    if ! echo "$haystack" | grep -qF "$needle"; then
        echo "[PASS] $name"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $name (unexpected: '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# Wrappers de getent e id em TMP_DIR/bin para simular contas geridas existentes sem tocar em /etc/passwd
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/getent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "passwd" && -z "${2:-}" ]]; then
    /usr/bin/getent passwd
    echo "jleft:x:9901:9901:Joao Left (E9001):/tmp:/bin/bash"
    echo "jmissing:x:9902:9902:Joao Missing (E9002):/tmp:/bin/bash"
    exit 0
elif [[ "${1:-}" == "passwd" && "${2:-}" == "jleft" ]]; then
    echo "jleft:x:9901:9901:Joao Left (E9001):/tmp:/bin/bash"
    exit 0
elif [[ "${1:-}" == "passwd" && "${2:-}" == "jmissing" ]]; then
    echo "jmissing:x:9902:9902:Joao Missing (E9002):/tmp:/bin/bash"
    exit 0
fi
exec /usr/bin/getent "$@"
EOF
chmod +x "$TMP_DIR/bin/getent"

cat > "$TMP_DIR/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "jleft" || "${1:-}" == "jmissing" ]]; then
    exit 0
fi
exec /usr/bin/id "$@"
EOF
chmod +x "$TMP_DIR/bin/id"

# Política e CSV sintéticos para testar 3.1, 3.2 e 3.3:
# - E9000: status=left sem conta existente -> 3.1 (não faz nada)
# - E9001: status=left com conta existente (jleft) -> 3.2 (offboarding completo)
# - E9002 (jmissing): existe no sistema mas não está no CSV -> 3.3 (apenas aviso)
cat > "$TMP_DIR/pol.csv" <<'EOF'
folder,group,access
/srv/company/it,it,rwx
EOF

cat > "$TMP_DIR/emp.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E9000,Ana,Ninguem,it,staff,left,
E9001,Joao,Left,it,staff,left,
EOF

OUT="$(PATH="$TMP_DIR/bin:$PATH" "$PROVISION" --dry-run "$TMP_DIR/emp.csv" "$TMP_DIR/pol.csv" 2>&1)"
TODAY="$(date '+%Y-%m-%d')"

# 3.1: status=left sem conta existente não gera qualquer ação
assert_not_contains "3.1 nao cria conta para E9000 (left sem conta)" "Created user" "$OUT"
assert_not_contains "3.1 nao faz offboard de E9000" "(E9000)" "$OUT"

# 3.2: status=left com conta existente executa os passos esperados em --dry-run
assert_contains "3.2 bloqueia conta e termina sessoes de jleft" "[DRY-RUN] Locked account and terminated active sessions for 'jleft' (E9001)" "$OUT"
assert_contains "3.2 arquiva home de jleft para /srv/archive" "[DRY-RUN] Archived home '/tmp' to '/srv/archive/jleft_E9001_${TODAY}.tar.gz' (verified)" "$OUT"
assert_contains "3.2 remove crontab, conta e home de jleft" "[DRY-RUN] Removed crontab, account, and home for 'jleft' (E9001)" "$OUT"

# 3.3: utilizador gerido desaparecido do CSV gera aviso mas não é removido
assert_contains "3.3 imprime aviso para jmissing (E9002) em falta no CSV" "Warning: Managed user 'jmissing' (E9002) is missing from CSV without status=left; account NOT removed." "$OUT"
assert_not_contains "3.3 nao bloqueia nem remove jmissing" "Locked account and terminated active sessions for 'jmissing'" "$OUT"
assert_not_contains "3.3 nao arquiva jmissing" "/srv/archive/jmissing_" "$OUT"

echo "----------------------------------------"
echo "Fase 3 -> Passou: $PASS | Falhou: $FAIL"
[[ "$FAIL" -eq 0 ]]
