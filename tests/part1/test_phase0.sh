#!/usr/bin/env bash
set -euo pipefail

# Testes automatizados da Fase 0 (CLI, pré-requisitos, cabeçalhos, dry-run e exit codes)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROVISION="${REPO_ROOT}/part1/provision.sh"

REAL_EMP="/home/hcosteira/Documents/C1/C1_files/employees.csv"
REAL_EMP_V2="/home/hcosteira/Documents/C1/C1_files/employees_v2.csv"
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

# 1. Ajuda (-h / --help)
assert_exit "Flag -h devolve exit 0" 0 "$PROVISION" -h
assert_exit "Flag --help devolve exit 0" 0 "$PROVISION" --help

# 2. Argumentos inválidos -> exit 1
assert_exit "Opcao desconhecida devolve exit 1" 1 "$PROVISION" --unknown
assert_exit "Sem argumentos devolve exit 1" 1 "$PROVISION"
assert_exit "Apenas 1 argumento devolve exit 1" 1 "$PROVISION" --dry-run "$REAL_EMP"
assert_exit "3 argumentos devolvem exit 1" 1 "$PROVISION" --dry-run "$REAL_EMP" "$REAL_POL" extra.csv

# 3. Root e ficheiros -> exit 1
if [[ "$(id -u)" -ne 0 ]]; then
    assert_exit "Execucao sem root e sem --dry-run devolve exit 1" 1 "$PROVISION" "$REAL_EMP" "$REAL_POL"
fi
assert_exit "Ficheiro employees inexistente devolve exit 1" 1 "$PROVISION" --dry-run "$TMP_DIR/nao_existe.csv" "$REAL_POL"
assert_exit "Ficheiro policy inexistente devolve exit 1" 1 "$PROVISION" --dry-run "$REAL_EMP" "$TMP_DIR/nao_existe.csv"
assert_exit "Diretorio em vez de ficheiro devolve exit 1" 1 "$PROVISION" --dry-run "$TMP_DIR" "$REAL_POL"

# 4. Cabeçalhos inválidos ou ficheiro vazio -> exit 1
touch "$TMP_DIR/empty.csv"
assert_exit "Ficheiro employees vazio devolve exit 1" 1 "$PROVISION" --dry-run "$TMP_DIR/empty.csv" "$REAL_POL"
assert_exit "Cabecalhos trocados devolvem exit 1" 1 "$PROVISION" --dry-run "$REAL_POL" "$REAL_EMP"

# 5. Ficheiros reais (com BOM + CRLF e linhas invalidas) e --dry-run -> exit 2
assert_exit "employees.csv + access-policy.csv em --dry-run" 2 "$PROVISION" --dry-run "$REAL_EMP" "$REAL_POL"
assert_exit "employees_v2.csv + access-policy.csv em --dry-run" 2 "$PROVISION" --dry-run "$REAL_EMP_V2" "$REAL_POL"

echo "----------------------------------------"
echo "Fase 0 -> Passou: $PASS | Falhou: $FAIL"
[[ "$FAIL" -eq 0 ]]
