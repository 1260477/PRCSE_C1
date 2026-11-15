#!/usr/bin/env bash
set -euo pipefail

# Testes automatizados da Fase 1 (parsing, validação dos CSVs, departamentos e usernames)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROVISION="${REPO_ROOT}/part1/provision.sh"

REAL_EMP="/home/hcosteira/Documents/C1/C1_files/employees.csv"
REAL_POL="/home/hcosteira/Documents/C1/C1_files/access-policy.csv"

PASS=0
FAIL=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

assert_exit() {
    local name="$1"
    local expected_rc="$2"
    shift 2

    local actual_rc=0
    local out
    out="$("$@" 2>&1)" || actual_rc=$?

    if [[ "$actual_rc" -eq "$expected_rc" ]]; then
        echo "[PASS] $name (exit=$actual_rc)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $name (expected exit=$expected_rc, got exit=$actual_rc)"
        echo "$out"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$actual" == "$expected" ]]; then
        echo "[PASS] $name ('$actual')"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# --- Ficheiros base válidos para reutilizar nos testes ---
cat > "$TMP_DIR/pol_valid.csv" <<'EOF'
folder,group,access
/srv/company/it,it,rwx
/srv/company/hr,hr,rwx
/srv/company/hr/payroll,finance,r-x
/srv/company/public,employees,r-x
EOF

cat > "$TMP_DIR/emp_valid.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Ana,Silva,it,staff,active,
EOF

# --- 1.1 Leitura e validação de access-policy.csv ---
printf '\xef\xbb\xbffolder,group,access\r\n\r\n/srv/company/marketing, marketing , rwx \r\n' > "$TMP_DIR/pol_bom_crlf.csv"
printf '\xef\xbb\xbfemployee_id,first_name,last_name,department,role,status,end_date\r\n\r\nE001, Jorge , Costa , Marketing , Staff , ACTIVE , \r\n' > "$TMP_DIR/emp_bom_crlf.csv"
assert_exit "1.1/1.2/1.3 BOM + CRLF + espacos + maiusculas + dept sintetico" 0 "$PROVISION" --dry-run "$TMP_DIR/emp_bom_crlf.csv" "$TMP_DIR/pol_bom_crlf.csv"

printf 'folder,group,access\n/srv/company/it,it,rw-\n' > "$TMP_DIR/pol_bad_acc.csv"
assert_exit "1.1 access invalido (rw-) devolve exit 1" 1 "$PROVISION" --dry-run "$TMP_DIR/emp_valid.csv" "$TMP_DIR/pol_bad_acc.csv"

printf 'folder,group,access\n/srv/company/it,it,rwx,extra\n' > "$TMP_DIR/pol_bad_cols.csv"
assert_exit "1.1 colunas a mais na politica devolve exit 1" 1 "$PROVISION" --dry-run "$TMP_DIR/emp_valid.csv" "$TMP_DIR/pol_bad_cols.csv"

printf 'folder,group,access\nsrv/company/it,it,rwx\n' > "$TMP_DIR/pol_rel_path.csv"
assert_exit "1.1 caminho relativo sem / devolve exit 1" 1 "$PROVISION" --dry-run "$TMP_DIR/emp_valid.csv" "$TMP_DIR/pol_rel_path.csv"

# --- 1.2 Extração dinâmica de departamentos ---
printf 'folder,group,access\n/srv/company/public,employees,r-x\n/srv/company/projects,managers,rwx\n' > "$TMP_DIR/pol_nodept.csv"
assert_exit "1.2 politica sem departamentos validos devolve exit 1" 1 "$PROVISION" --dry-run "$TMP_DIR/emp_valid.csv" "$TMP_DIR/pol_nodept.csv"

# --- 1.4 Validação e rejeição de linhas em employees.csv (exit 2) ---
cat > "$TMP_DIR/emp_missing.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Ana,Silva,it,,active,
EOF
assert_exit "1.4 campo obrigatorio em falta devolve exit 2" 2 "$PROVISION" --dry-run "$TMP_DIR/emp_missing.csv" "$TMP_DIR/pol_valid.csv"

cat > "$TMP_DIR/emp_bad_dept.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Ana,Silva,logistics,staff,active,
EOF
assert_exit "1.4 departamento desconhecido devolve exit 2" 2 "$PROVISION" --dry-run "$TMP_DIR/emp_bad_dept.csv" "$TMP_DIR/pol_valid.csv"

cat > "$TMP_DIR/emp_bad_role.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Ana,Silva,it,director,active,
EOF
assert_exit "1.4 role invalido devolve exit 2" 2 "$PROVISION" --dry-run "$TMP_DIR/emp_bad_role.csv" "$TMP_DIR/pol_valid.csv"

cat > "$TMP_DIR/emp_bad_status.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Ana,Silva,it,staff,vacation,
EOF
assert_exit "1.4 status invalido devolve exit 2" 2 "$PROVISION" --dry-run "$TMP_DIR/emp_bad_status.csv" "$TMP_DIR/pol_valid.csv"

cat > "$TMP_DIR/emp_dup.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Ana,Silva,it,staff,active,
E001,Ana,Silva,hr,staff,active,
EOF
assert_exit "1.4 employee_id duplicado devolve exit 2" 2 "$PROVISION" --dry-run "$TMP_DIR/emp_dup.csv" "$TMP_DIR/pol_valid.csv"

cat > "$TMP_DIR/emp_intern_nodate.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Ana,Silva,it,intern,active,
EOF
assert_exit "1.4 intern sem end_date devolve exit 2" 2 "$PROVISION" --dry-run "$TMP_DIR/emp_intern_nodate.csv" "$TMP_DIR/pol_valid.csv"

cat > "$TMP_DIR/emp_intern_baddate.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E001,Ana,Silva,it,intern,active,2026-02-30
EOF
assert_exit "1.4 intern com data inexistente (2026-02-30) devolve exit 2" 2 "$PROVISION" --dry-run "$TMP_DIR/emp_intern_baddate.csv" "$TMP_DIR/pol_valid.csv"

assert_exit "1.4 employees.csv real (com 4 linhas invalidas) devolve exit 2" 2 "$PROVISION" --dry-run "$REAL_EMP" "$REAL_POL"

# --- 1.5 & 1.6 Geração de usernames e resolução de colisões ---
eval "$(sed -n '/^normalize_alpha()/,/^}/p' "$PROVISION")"
eval "$(sed -n '/^generate_base_username()/,/^}/p' "$PROVISION")"

assert_eq "1.5 acentos e cedilha (Joao Goncalves)" "jgoncalves" "$(generate_base_username "João" "Gonçalves")"
assert_eq "1.5 apostrofo (Erica O'Connor)" "eoconnor" "$(generate_base_username "Érica" "O'Connor")"
assert_eq "1.5 nomes compostos (Ana Maria / Silva Costa)" "acosta" "$(generate_base_username "Ana Maria" "Silva Costa")"

# Testa resolve_usernames em subshell isolado para validar colisoes 2, 3
collision_result="$(bash -c '
    set -euo pipefail
    source <(sed -n "/^trim()/,/^}/p" "'"$PROVISION"'")
    source <(sed -n "/^normalize_alpha()/,/^}/p" "'"$PROVISION"'")
    source <(sed -n "/^generate_base_username()/,/^}/p" "'"$PROVISION"'")
    source <(sed -n "/^resolve_usernames()/,/^}/p" "'"$PROVISION"'")
    EMP_IDS=("E1" "E2" "E3")
    declare -A EMP_FIRST=(["E1"]="João" ["E2"]="José" ["E3"]="Joana")
    declare -A EMP_LAST=(["E1"]="Silva" ["E2"]="Silva" ["E3"]="Silva")
    declare -A EMP_STATUS=(["E1"]="active" ["E2"]="active" ["E3"]="active")
    declare -A EMP_USERNAME=()
    declare -A USED_USERNAMES=()
    declare -A EXISTING_EMP_USER=()
    resolve_usernames
    echo "${EMP_USERNAME[E1]},${EMP_USERNAME[E2]},${EMP_USERNAME[E3]}"
')"
assert_eq "1.6 colisao de usernames por ordem do CSV" "jsilva,jsilva2,jsilva3" "$collision_result"

echo "----------------------------------------"
echo "Fase 1 -> Passou: $PASS | Falhou: $FAIL"
[[ "$FAIL" -eq 0 ]]
