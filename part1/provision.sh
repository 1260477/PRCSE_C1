#!/usr/bin/env bash
set -euo pipefail

# Códigos de saída definidos no enunciado (Secção 1.4)
readonly EXIT_OK=0
readonly EXIT_FATAL=1
readonly EXIT_REJECTED=2

# Ficheiro de log oficial (Secção 1.4)
readonly LOG_FILE="/var/log/provision.log"

# Variáveis globais para opções, caminhos dos CSVs e contadores de estado
DRY_RUN=0
EMP_CSV=""
POLICY_CSV=""
CHANGES_MADE=0
HAS_REJECTED=0

# Mostra as instruções de utilização do script
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

# Imprime uma mensagem de erro para stderr e termina com exit code 1
fatal() {
    echo "Error: $*" >&2
    exit "$EXIT_FATAL"
}

# Regista uma alteração: imprime no ecrã e (sem --dry-run) acrescenta ao log com data/hora
# Nota de segurança: NUNCA passar passwords para esta função
log_change() {
    local message="$1"

    # Incrementa o contador para sabermos no fim se houve alguma alteração
    CHANGES_MADE=$((CHANGES_MADE + 1))

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] $message"
    else
        local timestamp
        timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
        echo "$message"
        echo "[$timestamp] $message" >> "$LOG_FILE"
    fi
}

# Remove UTF-8 BOM (1.ª linha) e converte CRLF para LF em fluxo (sem alterar o ficheiro no disco)
remove_BOM() {
    local file="$1"

    # -n verifica se a variável não está vazia (é preciso usar $file, não literal file)
    if [[ -n "$file" ]]; then
        sed '1s/^\xef\xbb\xbf//' "$file" | tr -d '\r'
    fi
}

# Lê e valida os argumentos da linha de comandos
parse_args() {
    # Percorre todos os argumentos enquanto houver elementos ($# > 0)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit "$EXIT_OK"
                ;;
            --dry-run)
                DRY_RUN=1
                shift   # Avança para o próximo argumento
                ;;
            -*)
                # Qualquer outra flag começada por '-' é inválida
                echo "Error: Unknown option '$1'" >&2
                exit "$EXIT_FATAL"
                ;;
            *)
                # Argumentos posicionais: 1.º = employees.csv, 2.º = access-policy.csv
                if [[ -z "$EMP_CSV" ]]; then
                    EMP_CSV="$1"
                elif [[ -z "$POLICY_CSV" ]]; then
                    POLICY_CSV="$1"
                else
                    echo "Error: Too many arguments (unexpected '$1')." >&2
                    exit "$EXIT_FATAL"
                fi
                shift
                ;;
        esac
    done

    # Garante que os dois ficheiros obrigatórios foram fornecidos
    if [[ -z "$EMP_CSV" || -z "$POLICY_CSV" ]]; then
        echo "Error: Expected 2 arguments (<employees.csv> <access-policy.csv>)." >&2
        exit "$EXIT_FATAL"
    fi
}

# Valida privilégios de root (quando não está em --dry-run) e os ficheiros de entrada
check_pre_reqs() {
    # Só exige root quando vai alterar o sistema (sem --dry-run)
    if [[ "$DRY_RUN" -eq 0 ]]; then
        # Em Linux, o UID do utilizador root é sempre 0
        if [[ "$(id -u)" -ne 0 ]]; then
            fatal "This script must be run as root (use sudo) unless --dry-run is used."
        fi
    fi

    # Verifica sempre se ambos os caminhos são ficheiros regulares e legíveis
    if [[ ! -f "$EMP_CSV" || ! -r "$EMP_CSV" ]]; then
        fatal "Employees file not found or not readable: $EMP_CSV"
    fi

    if [[ ! -f "$POLICY_CSV" || ! -r "$POLICY_CSV" ]]; then
        fatal "Policy file not found or not readable: $POLICY_CSV"
    fi
}

# Valida se a primeira linha não-vazia de um CSV corresponde ao cabeçalho esperado
check_csv_header() {
    local file="$1"
    local expected_header="$2"

    # Lê a primeira linha não-vazia já sem BOM, sem \r e sem espaços nas pontas
    # O '|| true' evita que set -e aborte em silêncio se o ficheiro estiver vazio
    local header
    header="$(remove_BOM "$file" | grep -m 1 '[^[:space:]]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"

    if [[ -z "$header" ]]; then
        fatal "CSV file is empty: $file"
    fi

    if [[ "$header" != "$expected_header" ]]; then
        fatal "Invalid header in '$file': expected '$expected_header', got '$header'"
    fi
}

check_emp_csv() {
    check_csv_header "$EMP_CSV" "employee_id,first_name,last_name,department,role,status,end_date"
}

check_policy_csv() {
    check_csv_header "$POLICY_CSV" "folder,group,access"
}

# Valida os cabeçalhos dos dois ficheiros antes de qualquer alteração no sistema
check_headers() {
    check_emp_csv
    check_policy_csv
}

main() {
    parse_args "$@"
    check_pre_reqs
    check_headers

    # Se nenhuma alteração foi feita (ou prevista em --dry-run), informa o utilizador
    if [[ "$CHANGES_MADE" -eq 0 ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            echo "No changes would be made (already up to date)."
        else
            echo "No changes needed (already up to date)."
        fi
    fi

    # Devolve 2 se houve linhas rejeitadas no CSV, ou 0 se tudo correu bem
    if [[ "$HAS_REJECTED" -eq 1 ]]; then
        exit "$EXIT_REJECTED"
    fi
    exit "$EXIT_OK"
}

# Passa todos os argumentos recebidos pelo script para a função main
main "$@"
