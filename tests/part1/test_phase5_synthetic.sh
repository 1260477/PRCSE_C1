#!/usr/bin/env bash
set -euo pipefail

# Teste automatizado da Fase 5 (5.6 - 2.o conjunto sintetico sem departamentos/pastas hard-coded)
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

POL="$TMP_DIR/access-policy-synth.csv"
EMP="$TMP_DIR/employees-synth.csv"

cat > "$POL" <<'EOF'
folder,group,access
/srv/company/synth_mkt,synth_mkt,rwx
/srv/company/synth_ops,synth_ops,rwx
/srv/company/synth_rnd,synth_rnd,rwx
/srv/company/synth_rnd/prototypes,synth_rnd,rwx
/srv/company/synth_rnd/prototypes,synth_ops,r-x
/srv/company/public,employees,r-x
/srv/company/public,managers,rwx
EOF

cat > "$EMP" <<'EOF'
employee_id,first_name,last_name,department,role,status,end_date
E5001,Beatriz,Sousa,synth_mkt,manager,active,
E5002,Diogo,Almeida,synth_ops,staff,active,
E5003,Ines,Ferreira,synth_rnd,intern,active,2027-06-30
E5004,Tiago,Mendes,synth_rnd,staff,left,
E5005,Carla,Nunes,unknown_dept,staff,active,
EOF

rc=0
out="$("$PROVISION" --dry-run "$EMP" "$POL" 2>&1)" || rc=$?

if [[ "$rc" -eq 2 ]]; then
    echo "[PASS] 5.6 conjunto sintetico devolve exit 2 por linha invalida"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 5.6 conjunto sintetico (expected exit=2, got exit=$rc)"
    FAIL=$((FAIL + 1))
fi

# Departamentos dinamicos (synth_mkt, synth_ops, synth_rnd) e NAO os do enunciado (hr, finance, it)
assert_contains "5.6 cria grupo sintetico synth_mkt" "Created group 'synth_mkt'" "$out"
assert_contains "5.6 cria grupo sintetico synth_ops" "Created group 'synth_ops'" "$out"
assert_contains "5.6 cria grupo sintetico synth_rnd" "Created group 'synth_rnd'" "$out"
assert_not_contains "5.6 nao cria grupo hard-coded finance" "Created group 'finance'" "$out"

# Utilizadores e regras de grupo/sudo/expiracao
assert_contains "5.6 cria conta manager synth_mkt (bsousa)" "Created user 'bsousa' (E5001)" "$out"
assert_contains "5.6 adiciona bsousa a managers" "Added 'bsousa' to group 'managers'" "$out"
assert_contains "5.6 cria conta staff synth_ops (dalmeida)" "Created user 'dalmeida' (E5002)" "$out"
assert_contains "5.6 aplica expiracao a intern synth_rnd (iferreira)" "Set account expiry for intern 'iferreira' to 2027-06-30" "$out"
assert_not_contains "5.6 nao cria conta para status=left (tmendes)" "Created user 'tmendes'" "$out"
assert_not_contains "5.6 nao adiciona utilizador fora de it a sudo" "to 'sudo' group" "$out"

# Pastas partilhadas e ACLs dinamicas
assert_contains "5.6 cria /srv/company/synth_mkt (root:synth_mkt)" "Created shared folder '/srv/company/synth_mkt' (owner=root:synth_mkt, mode=2770)" "$out"
assert_contains "5.6 cria /srv/company/synth_rnd/prototypes (root:synth_rnd)" "Created shared folder '/srv/company/synth_rnd/prototypes' (owner=root:synth_rnd, mode=2770)" "$out"
assert_contains "5.6 cria /srv/company/public (root:managers)" "Created shared folder '/srv/company/public' (owner=root:managers, mode=2770)" "$out"
assert_contains "5.6 sincroniza ACLs em /srv/company/synth_rnd (inclui travessia --x e intern)" "Synchronized ACLs and default ACLs on '/srv/company/synth_rnd'" "$out"

echo "----------------------------------------"
echo "Fase 5 (Sintetico) -> Passou: $PASS | Falhou: $FAIL"
[[ "$FAIL" -eq 0 ]]
