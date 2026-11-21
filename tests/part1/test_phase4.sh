#!/usr/bin/env bash
set -euo pipefail

# Testes automatizados da Fase 4 (pastas partilhadas, ACLs, travessia --x, interns e idempotência)
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

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo "[PASS] $name"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $name (expected '$expected', got '$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# 1. Testar --dry-run com o conjunto real (employees.csv + access-policy.csv)
REAL_OUT="$("$PROVISION" --dry-run "${REPO_ROOT}/../C1_files/employees.csv" "${REPO_ROOT}/../C1_files/access-policy.csv" 2>&1 || true)"

assert_contains "4.1 cria /srv/company em --dry-run" "[DRY-RUN] Created company root '/srv/company' (owner=root:root, mode=0711)" "$REAL_OUT"
assert_contains "4.1 cria /srv/company/hr com grupo hr e 2770" "[DRY-RUN] Created shared folder '/srv/company/hr' (owner=root:hr, mode=2770)" "$REAL_OUT"
assert_contains "4.1 cria /srv/company/hr/payroll com grupo hr e 2770" "[DRY-RUN] Created shared folder '/srv/company/hr/payroll' (owner=root:hr, mode=2770)" "$REAL_OUT"
assert_contains "4.1 cria /srv/company/public com grupo managers (1.o rwx) e 2770" "[DRY-RUN] Created shared folder '/srv/company/public' (owner=root:managers, mode=2770)" "$REAL_OUT"
assert_contains "4.2 sincroniza ACLs de /srv/company/hr" "[DRY-RUN] Synchronized ACLs and default ACLs on '/srv/company/hr'" "$REAL_OUT"
assert_contains "4.2 sincroniza ACLs de /srv/company/hr/payroll" "[DRY-RUN] Synchronized ACLs and default ACLs on '/srv/company/hr/payroll'" "$REAL_OUT"

# 2. Testar funções internas com política e utilizadores sintéticos (4.1, 4.3, 4.4, 4.5)
cat > "$TMP_DIR/pol.csv" <<'EOF'
folder,group,access
/srv/company/alpha,alpha,rwx
/srv/company/alpha/secret,beta,r-x
/srv/company/readonly,alpha,r-x
EOF

cat > "$TMP_DIR/emp.csv" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E8001,Ana,Estagiaria,alpha,intern,active,2027-06-30
E8002,Bruno,Beta,beta,intern,active,2027-06-30
E8003,Carla,Staff,alpha,staff,active,
EOF

# Carrega funções de provision.sh sem executar main (removendo a última linha "main \"$@\"")
FUNCS_SH="$TMP_DIR/provision_funcs.sh"
sed -e '$d' -e 's/^readonly COMPANY_DIR=/COMPANY_DIR=/' "$PROVISION" > "$FUNCS_SH"

TEST_FUNCS_OUT="$(bash -c '
    set -euo pipefail
    source "'"$FUNCS_SH"'"
    EMP_CSV="'"$TMP_DIR/emp.csv"'"
    POLICY_CSV="'"$TMP_DIR/pol.csv"'"
    load_policy
    extract_departments
    load_employees
    resolve_usernames

    echo "GRP_ALPHA=$(get_folder_group_owner /srv/company/alpha)"
    echo "GRP_SECRET=$(get_folder_group_owner /srv/company/alpha/secret)"
    echo "GRP_READONLY=$(get_folder_group_owner /srv/company/readonly)"
    echo "TRAV_ALPHA=$(get_traversal_groups_for_folder /srv/company/alpha | tr "\n" ",")"
    echo "INTERN_ALPHA=$(get_folder_interns /srv/company/alpha | tr "\n" ",")"
    echo "INTERN_READONLY=$(get_folder_interns /srv/company/readonly | tr "\n" ",")"
    if is_under_other_policy_folder /srv/company/alpha/secret/doc.txt /srv/company/alpha; then
        echo "NESTED_EXCLUDED=1"
    else
        echo "NESTED_EXCLUDED=0"
    fi
')"

assert_contains "4.1 primeiro grupo rwx em /srv/company/alpha e alpha" "GRP_ALPHA=alpha" "$TEST_FUNCS_OUT"
assert_contains "4.1 pasta sem rwx (/srv/company/alpha/secret) usa fallback root" "GRP_SECRET=root" "$TEST_FUNCS_OUT"
assert_contains "4.1 pasta readonly usa fallback root" "GRP_READONLY=root" "$TEST_FUNCS_OUT"
assert_contains "4.3 beta recebe travessia --x em /srv/company/alpha" "TRAV_ALPHA=beta," "$TEST_FUNCS_OUT"
assert_contains "4.4 intern aestagiaria (alpha rwx) recebe excecao em /srv/company/alpha" "INTERN_ALPHA=aestagiaria," "$TEST_FUNCS_OUT"
assert_eq "4.4 intern nao recebe excecao em pasta onde dept so tem r-x" "1" "$(echo "$TEST_FUNCS_OUT" | grep -c '^INTERN_READONLY=$')"
assert_contains "4.5 exclui subpasta com politica propria ao sincronizar pasta-pai" "NESTED_EXCLUDED=1" "$TEST_FUNCS_OUT"

# 3. Testar idempotência em pastas existentes quando getfacl já devolve exatamente a ACL esperada
mkdir -p "$TMP_DIR/srv/alpha" "$TMP_DIR/bin"
chmod 2770 "$TMP_DIR/srv/alpha"

cat > "$TMP_DIR/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "%U" ]]; then
    echo "root"
    exit 0
elif [[ "${1:-}" == "-c" && "${2:-}" == "%G" ]]; then
    echo "alpha"
    exit 0
elif [[ "${1:-}" == "-c" && "${2:-}" == "%a" ]]; then
    echo "2770"
    exit 0
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$TMP_DIR/bin/stat"

cat > "$TMP_DIR/bin/getfacl" <<'EOF'
#!/usr/bin/env bash
cat <<'ACL'
user::rwx
group::rwx
group:alpha:rwx
mask::rwx
other::---
default:user::rwx
default:group::rwx
default:group:alpha:rwx
default:mask::rwx
default:other::---
ACL
EOF
chmod +x "$TMP_DIR/bin/getfacl"

cat > "$TMP_DIR/pol_idemp.csv" <<EOF
folder,group,access
${TMP_DIR}/srv/alpha,alpha,rwx
EOF

IDEMP_OUT="$(PATH="$TMP_DIR/bin:$PATH" bash -c '
    set -euo pipefail
    source "'"$FUNCS_SH"'"
    DRY_RUN=1
    COMPANY_DIR="'"$TMP_DIR/srv"'"
    POLICY_CSV="'"$TMP_DIR/pol_idemp.csv"'"
    load_policy
    ensure_shared_folders
    ensure_folder_acls
    echo "CHANGES_MADE=$CHANGES_MADE"
')"

assert_contains "4.6 idempotencia: zero alteracoes quando pasta, dono, modo e ACL ja coincidem" "CHANGES_MADE=0" "$IDEMP_OUT"

echo "----------------------------------------"
echo "Fase 4 -> Passou: $PASS | Falhou: $FAIL"
[[ "$FAIL" -eq 0 ]]
