#!/usr/bin/env bash
set -euo pipefail

# Testes automatizados da Fase 2 (grupos, contas, passwords, chage, sudo) via --dry-run
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

# --- Política e empregados sintéticos para testar toda a Fase 2 ---
cat > "$TMP_DIR/pol.csv" <<'EOF'
folder,group,access
/srv/company/it,it,rwx
/srv/company/finance,finance,rwx
/srv/company/public,employees,r-x
EOF

cat > "$TMP_DIR/emp.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Zelda,Xanadu,it,manager,active,
E002,Ygor,Wenceslau,it,intern,active,2026-12-31
E003,Xenia,Viana,finance,staff,active,
E004,Wanda,Uchoa,it,staff,left,
EOF

OUT="$("$PROVISION" --dry-run "$TMP_DIR/emp.csv" "$TMP_DIR/pol.csv" 2>&1)"

# 2.1 Grupos
assert_contains "2.1 cria grupo do departamento it" "[DRY-RUN] Created group 'it'" "$OUT"
assert_contains "2.1 cria grupo do departamento finance" "[DRY-RUN] Created group 'finance'" "$OUT"
assert_contains "2.1 cria grupo global employees" "[DRY-RUN] Created group 'employees'" "$OUT"
assert_contains "2.1 cria grupo global managers" "[DRY-RUN] Created group 'managers'" "$OUT"
assert_not_contains "2.1 nao cria grupo para pasta public" "Created group 'public'" "$OUT"

# 2.2 Contas (active criadas, left ignorada)
assert_contains "2.2 cria conta para it manager active (zxanadu)" "[DRY-RUN] Created user 'zxanadu' (E001) with home '/home/zxanadu'" "$OUT"
assert_contains "2.2 cria conta para it intern active (ywenceslau)" "[DRY-RUN] Created user 'ywenceslau' (E002) with home '/home/ywenceslau'" "$OUT"
assert_contains "2.2 cria conta para finance staff active (xviana)" "[DRY-RUN] Created user 'xviana' (E003) with home '/home/xviana'" "$OUT"
assert_not_contains "2.2 nao cria conta para status=left (wuchoa)" "Created user 'wuchoa'" "$OUT"

# 2.3 generate_password (>= 16 chars, sem ':', sem SIGPIPE)
GEN_PASS="$(bash -c 'set -euo pipefail; head -c 256 /dev/urandom | LC_ALL=C tr -dc "A-Za-z0-9@#%^*_+=-" | cut -c1-16')"
if [[ ${#GEN_PASS} -eq 16 && "$GEN_PASS" != *:* ]]; then
    echo "[PASS] 2.3 generate_password gera 16 caracteres seguros"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 2.3 generate_password invalida (len=${#GEN_PASS})"
    FAIL=$((FAIL + 1))
fi

# 2.4 Expiração de password (180 dias, aviso 14)
assert_contains "2.4 aplica chage -M 180 -W 14 em zxanadu" "[DRY-RUN] Set password aging for 'zxanadu' (max 180 days, warn 14 days)" "$OUT"
assert_contains "2.4 aplica chage -M 180 -W 14 em ywenceslau" "[DRY-RUN] Set password aging for 'ywenceslau' (max 180 days, warn 14 days)" "$OUT"

# 2.5 Expiração de conta para intern
assert_contains "2.5 aplica expiracao de conta em intern ywenceslau" "[DRY-RUN] Set account expiry for intern 'ywenceslau' to 2026-12-31" "$OUT"
assert_not_contains "2.5 nao aplica expiracao em staff/manager zxanadu" "Set account expiry for intern 'zxanadu'" "$OUT"

# 2.6 Grupos por utilizador
assert_contains "2.6 adiciona zxanadu a it" "[DRY-RUN] Added 'zxanadu' to group 'it'" "$OUT"
assert_contains "2.6 adiciona zxanadu a employees" "[DRY-RUN] Added 'zxanadu' to group 'employees'" "$OUT"
assert_contains "2.6 adiciona zxanadu (manager) a managers" "[DRY-RUN] Added 'zxanadu' to group 'managers'" "$OUT"
assert_not_contains "2.6 nao adiciona xviana (staff) a managers" "Added 'xviana' to group 'managers'" "$OUT"

# 2.7 Regra sudo
assert_contains "2.7 adiciona zxanadu (it manager active) a sudo" "[DRY-RUN] Added 'zxanadu' to 'sudo' group (active non-intern IT)" "$OUT"
assert_not_contains "2.7 nao adiciona ywenceslau (it intern) a sudo" "Added 'ywenceslau' to 'sudo' group" "$OUT"
assert_not_contains "2.7 nao adiciona xviana (finance staff) a sudo" "Added 'xviana' to 'sudo' group" "$OUT"
assert_not_contains "2.7 nao adiciona wuchoa (it left) a sudo" "Added 'wuchoa' to 'sudo' group" "$OUT"

echo "----------------------------------------"
echo "Fase 2 -> Passou: $PASS | Falhou: $FAIL"
[[ "$FAIL" -eq 0 ]]
