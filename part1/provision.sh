#!/usr/bin/env bash
set -euo pipefail

# Códigos de saída definidos no enunciado (Secção 1.4)
readonly EXIT_OK=0
readonly EXIT_FATAL=1
readonly EXIT_REJECTED=2

# Ficheiro de log oficial (Secção 1.4)
readonly LOG_FILE="/var/log/provision.log"

# Registo persistente de usernames já atribuídos (nunca reutilizar, mesmo após offboarding)
readonly USERNAME_HISTORY_FILE="/var/lib/provision/usernames.txt"

# Ficheiro onde ficam guardadas as passwords iniciais das novas contas (só root lê)
readonly INITIAL_PASSWORDS_FILE="/root/initial-passwords.txt"

# Diretórios usados no offboarding e nas pastas partilhadas
readonly ARCHIVE_DIR="/srv/archive"
readonly COMPANY_DIR="/srv/company"

# Variáveis globais para opções, caminhos dos CSVs e contadores de estado
DRY_RUN=0
EMP_CSV=""
POLICY_CSV=""
CHANGES_MADE=0
HAS_REJECTED=0

# Estruturas em memória para as regras de access-policy.csv:
# - POLICY_FOLDERS guarda as pastas únicas pela ordem do ficheiro
# - POLICY_RULES é um dicionário: chave = pasta, valor = "grupo1:rwx grupo2:r-x"
POLICY_FOLDERS=()
declare -A POLICY_RULES

# Lista de departamentos válidos extraídos dinamicamente da política
VALID_DEPARTMENTS=()

# Valores permitidos para role e status (Secção 1.1)
readonly VALID_ROLES=("staff" "manager" "intern")
readonly VALID_STATUSES=("active" "left")

# Grupos globais obrigatórios além dos departamentos (Secção 1.2)
readonly GLOBAL_GROUPS=("employees" "managers")

# Estruturas em memória para os funcionários válidos lidos de employees.csv:
# - EMP_IDS guarda os employee_id pela ordem do ficheiro
# - Os dicionários abaixo guardam os dados normalizados de cada employee_id
EMP_IDS=()
declare -A EMP_FIRST
declare -A EMP_LAST
declare -A EMP_DEPT
declare -A EMP_ROLE
declare -A EMP_STATUS
declare -A EMP_END_DATE
declare -A EMP_USERNAME

# Controlo de usernames ocupados (sistema + histórico persistente + atribuições atuais)
declare -A USED_USERNAMES

# Utilizadores geridos já existentes no sistema (identificados por "(E...)" no GECOS)
declare -A EXISTING_EMP_USER=()
declare -A EXISTING_EMP_GECOS=()

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

# Remove espaços e tabs no início e no fim de uma string
trim() {
    echo "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Converte uma string para minúsculas (para comparações case-insensitive)
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Remove acentos, converte para minúsculas e mantém apenas letras a-z
# Nota: LC_ALL=C.UTF-8 é obrigatório para o iconv transliterar acentos (ex: João -> joao)
normalize_alpha() {
    echo "$1" | LC_ALL=C.UTF-8 iconv -f UTF-8 -t ASCII//TRANSLIT | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z]//g'
}

# Gera o username base: 1.ª letra de first_name + última palavra de last_name (só a-z)
generate_base_username() {
    local first_name="$1"
    local last_name="$2"

    # Limpa first_name para a-z minúsculas e fica com o 1.º caráter
    local first_clean
    first_clean="$(normalize_alpha "$first_name")"
    local first_initial="${first_clean:0:1}"

    # Extrai a última palavra de last_name ($NF = último campo) e limpa para a-z
    local last_word
    last_word="$(echo "$last_name" | awk '{print $NF}')"
    local last_clean
    last_clean="$(normalize_alpha "$last_word")"

    echo "${first_initial}${last_clean}"
}

# Verifica se um valor (1.º argumento) existe na lista passada nos argumentos seguintes
in_array() {
    local needle="$1"
    shift

    local item
    for item in "$@"; do
        if [[ "$item" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

# Valida se uma data tem o formato YYYY-MM-DD e existe mesmo no calendário
is_valid_date() {
    local date_str="$1"

    if [[ ! "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        return 1
    fi

    # date -d falha em datas inexistentes (ex: 2026-02-30)
    date -d "$date_str" >/dev/null 2>&1
}

# Regista uma linha rejeitada de employees.csv (imprime linha + motivo e ativa exit code 2)
reject_emp_row() {
    local line_num="$1"
    local reason="$2"

    echo "Warning: Line $line_num in '$EMP_CSV' rejected: $reason" >&2
    HAS_REJECTED=1
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

# Lê access-policy.csv, normaliza quebras de linha/BOM, valida cada regra
# e guarda o resultado em POLICY_FOLDERS e POLICY_RULES
load_policy() {
    local line
    local line_num=0
    local header_skipped=0

    # Lê o ficheiro já sem BOM nem \r; o "|| [[ -n "$line" ]]" garante que a última linha
    # também é lida mesmo que o ficheiro não termine com quebra de linha
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Ignora linhas em branco (vazias ou só com espaços/tabs)
        if [[ -z "$(trim "$line")" ]]; then
            continue
        fi

        # A primeira linha não-vazia é o cabeçalho (já validado em check_policy_csv)
        if [[ "$header_skipped" -eq 0 ]]; then
            header_skipped=1
            continue
        fi

        # Garante que a linha tem exatamente 3 campos (2 vírgulas)
        if [[ "$line" == *,*,*,* ]]; then
            fatal "Invalid policy row at line $line_num in '$POLICY_CSV': too many columns."
        fi

        local folder group access
        IFS=',' read -r folder group access <<< "$line"

        folder="$(trim "$folder")"
        group="$(trim "$group")"
        access="$(trim "$access")"

        # Verifica se algum campo obrigatório ficou vazio
        if [[ -z "$folder" || -z "$group" || -z "$access" ]]; then
            fatal "Invalid policy row at line $line_num in '$POLICY_CSV': missing field."
        fi

        # O caminho da pasta tem de ser absoluto (começar por '/')
        if [[ "$folder" != /* ]]; then
            fatal "Invalid folder path at line $line_num in '$POLICY_CSV': '$folder' (must start with /)."
        fi

        # Remove eventual '/' no fim (exceto se for a raiz '/')
        if [[ "$folder" != "/" ]]; then
            folder="${folder%/}"
        fi

        # O nome do grupo não pode ter espaços nem ':' (usado como separador no dicionário)
        if [[ "$group" == *:* || "$group" == *[[:space:]]* ]]; then
            fatal "Invalid group name at line $line_num in '$POLICY_CSV': '$group'."
        fi

        # A permissão só pode ser 'rwx' ou 'r-x'
        if [[ "$access" != "rwx" && "$access" != "r-x" ]]; then
            fatal "Invalid access value at line $line_num in '$POLICY_CSV': '$access' (expected 'rwx' or 'r-x')."
        fi

        # Guarda no dicionário; se a pasta for nova, adiciona-a também à lista ordenada
        if [[ -z "${POLICY_RULES[$folder]:-}" ]]; then
            POLICY_FOLDERS+=("$folder")
            POLICY_RULES["$folder"]="${group}:${access}"
        else
            POLICY_RULES["$folder"]="${POLICY_RULES[$folder]} ${group}:${access}"
        fi
    done < <(remove_BOM "$POLICY_CSV")

    # Garante que existe pelo menos uma regra além do cabeçalho
    if [[ "${#POLICY_FOLDERS[@]}" -eq 0 ]]; then
        fatal "No policy rules found in '$POLICY_CSV'."
    fi
}

# Extrai dinamicamente os departamentos válidos a partir da política carregada:
# uma pasta de topo /srv/company/<nome> (exceto public) que tenha regra para o grupo <nome>
extract_departments() {
    local folder

    for folder in "${POLICY_FOLDERS[@]}"; do
        # Só interessam pastas dentro de /srv/company/
        if [[ "$folder" != /srv/company/* ]]; then
            continue
        fi

        # Remove o prefixo "/srv/company/" para ficar apenas com o nome da pasta
        local dept="${folder#/srv/company/}"

        # Se estiver vazio ou ainda tiver '/', é uma subpasta (ex: hr/payroll), não pasta de topo
        if [[ -z "$dept" || "$dept" == */* ]]; then
            continue
        fi

        # "public" é uma pasta partilhada geral, nunca um departamento
        if [[ "$dept" == "public" ]]; then
            continue
        fi

        # Procura nas regras desta pasta se existe alguma para o grupo com o mesmo nome
        local rule rule_group rule_access
        for rule in ${POLICY_RULES["$folder"]}; do
            IFS=':' read -r rule_group rule_access <<< "$rule"

            if [[ "$rule_group" == "$dept" ]]; then
                VALID_DEPARTMENTS+=("$dept")
                break
            fi
        done
    done

    # Se não foi encontrado nenhum departamento válido, a política é inválida
    if [[ "${#VALID_DEPARTMENTS[@]}" -eq 0 ]]; then
        fatal "No valid departments found in '$POLICY_CSV'."
    fi
}

# Lê employees.csv, remove BOM/CRLF, ignora linhas em branco e o cabeçalho,
# faz trim aos campos e normaliza department, role e status para minúsculas
load_employees() {
    local line
    local line_num=0
    local header_skipped=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_num=$((line_num + 1))

        # Ignora linhas em branco (vazias ou só com espaços/tabs)
        if [[ -z "$(trim "$line")" ]]; then
            continue
        fi

        # A primeira linha não-vazia é o cabeçalho (já validado em check_emp_csv)
        if [[ "$header_skipped" -eq 0 ]]; then
            header_skipped=1
            continue
        fi

        # Se a linha tiver mais de 7 colunas (7 ou mais vírgulas), rejeita e continua
        if [[ "$line" == *,*,*,*,*,*,*,* ]]; then
            reject_emp_row "$line_num" "too many columns"
            continue
        fi

        local emp_id first_name last_name dept role status end_date
        IFS=',' read -r emp_id first_name last_name dept role status end_date <<< "$line"

        # Remove espaços à volta de todos os campos
        emp_id="$(trim "$emp_id")"
        first_name="$(trim "$first_name")"
        last_name="$(trim "$last_name")"
        dept="$(to_lower "$(trim "$dept")")"
        role="$(to_lower "$(trim "$role")")"
        status="$(to_lower "$(trim "$status")")"
        end_date="$(trim "$end_date")"

        # 1. Verifica campos obrigatórios em falta
        if [[ -z "$emp_id" || -z "$first_name" || -z "$last_name" || -z "$dept" || -z "$role" || -z "$status" ]]; then
            reject_emp_row "$line_num" "missing required field (employee_id='$emp_id')"
            continue
        fi

        # 2. Rejeita employee_id duplicado (mantém o primeiro que apareceu)
        if [[ -n "${EMP_FIRST[$emp_id]:-}" ]]; then
            reject_emp_row "$line_num" "duplicate employee_id '$emp_id'"
            continue
        fi

        # 3. Valida se o departamento existe na política
        if ! in_array "$dept" "${VALID_DEPARTMENTS[@]}"; then
            reject_emp_row "$line_num" "unknown department '$dept' for '$emp_id'"
            continue
        fi

        # 4. Valida role (apenas staff, manager, intern)
        if ! in_array "$role" "${VALID_ROLES[@]}"; then
            reject_emp_row "$line_num" "invalid role '$role' for '$emp_id'"
            continue
        fi

        # 5. Valida status (apenas active, left)
        if ! in_array "$status" "${VALID_STATUSES[@]}"; then
            reject_emp_row "$line_num" "invalid status '$status' for '$emp_id'"
            continue
        fi

        # 6. Estagiários (intern) têm de ter end_date válido no formato YYYY-MM-DD
        if [[ "$role" == "intern" ]]; then
            if [[ -z "$end_date" ]] || ! is_valid_date "$end_date"; then
                reject_emp_row "$line_num" "intern '$emp_id' missing or invalid end_date '$end_date'"
                continue
            fi
        fi

        EMP_IDS+=("$emp_id")
        EMP_FIRST["$emp_id"]="$first_name"
        EMP_LAST["$emp_id"]="$last_name"
        EMP_DEPT["$emp_id"]="$dept"
        EMP_ROLE["$emp_id"]="$role"
        EMP_STATUS["$emp_id"]="$status"
        EMP_END_DATE["$emp_id"]="$end_date"
    done < <(remove_BOM "$EMP_CSV")
}

# Carrega todas as contas Linux existentes e o histórico persistente de usernames:
# - Preenche USED_USERNAMES para impedir colisões ou reutilização de usernames antigos
# - Preenche EXISTING_EMP_USER e EXISTING_EMP_GECOS para reconhecer contas pelo employee_id
load_existing_users() {
    local pw_user pw_gecos

    # 1. Lê todas as contas atuais do sistema (/etc/passwd)
    while IFS=':' read -r pw_user _ _ _ pw_gecos _ _; do
        if [[ -z "$pw_user" ]]; then
            continue
        fi

        # Marca este username como ocupado
        USED_USERNAMES["$pw_user"]=1

        # Se o campo GECOS terminar em "(ID)", ex: "Ana Silva (E1001)", regista o utilizador
        if [[ "$pw_gecos" =~ \(([^()]+)\)[[:space:]]*$ ]]; then
            local found_id="${BASH_REMATCH[1]}"
            EXISTING_EMP_USER["$found_id"]="$pw_user"
            EXISTING_EMP_GECOS["$found_id"]="$pw_gecos"
        fi
    done < <(getent passwd)

    # 2. Lê o histórico persistente de usernames já atribuídos no passado (se existir)
    if [[ -f "$USERNAME_HISTORY_FILE" && -r "$USERNAME_HISTORY_FILE" ]]; then
        local hist_user
        while IFS= read -r hist_user || [[ -n "$hist_user" ]]; do
            hist_user="$(trim "$hist_user")"
            if [[ -n "$hist_user" ]]; then
                USED_USERNAMES["$hist_user"]=1
            fi
        done < "$USERNAME_HISTORY_FILE"
    fi
}

# Atribui o username final a cada funcionário válido, por ordem do CSV:
# - Se já existe conta no Linux com o seu employee_id, mantém o username existente
# - Se é novo e está active, gera o username base e resolve colisões com sufixo 2, 3, ...
# - Se tem status=left e não tem conta, não atribui nem reserva username
resolve_usernames() {
    local emp_id

    for emp_id in "${EMP_IDS[@]}"; do
        # Caso 1: utilizador já reconhecido no sistema pelo employee_id no GECOS
        if [[ -n "${EXISTING_EMP_USER[$emp_id]:-}" ]]; then
            EMP_USERNAME["$emp_id"]="${EXISTING_EMP_USER[$emp_id]}"
            continue
        fi

        # Caso 2: status=left sem conta existente -> não precisa de username
        if [[ "${EMP_STATUS[$emp_id]}" == "left" ]]; then
            EMP_USERNAME["$emp_id"]=""
            continue
        fi

        # Caso 3: novo utilizador ativo -> gera base e resolve colisões
        local base
        base="$(generate_base_username "${EMP_FIRST[$emp_id]}" "${EMP_LAST[$emp_id]}")"

        local candidate="$base"
        local suffix=2
        while [[ -n "${USED_USERNAMES[$candidate]:-}" ]]; do
            candidate="${base}${suffix}"
            suffix=$((suffix + 1))
        done

        EMP_USERNAME["$emp_id"]="$candidate"
        USED_USERNAMES["$candidate"]=1
    done
}

# Guarda um novo username no histórico persistente (para nunca ser reutilizado no futuro)
record_used_username() {
    local username="$1"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi

    local history_dir
    history_dir="$(dirname "$USERNAME_HISTORY_FILE")"
    if [[ ! -d "$history_dir" ]]; then
        mkdir -p "$history_dir"
        chmod 0700 "$history_dir"
    fi

    # Só acrescenta se ainda não estiver no ficheiro
    if [[ ! -f "$USERNAME_HISTORY_FILE" ]] || ! grep -qxF "$username" "$USERNAME_HISTORY_FILE"; then
        echo "$username" >> "$USERNAME_HISTORY_FILE"
        chmod 0600 "$USERNAME_HISTORY_FILE"
    fi
}

# Garante que existem todos os grupos necessários: 1 por departamento + employees + managers
ensure_groups() {
    local target_groups=()
    local grp

    # Junta os departamentos válidos e os grupos globais sem duplicados
    for grp in "${VALID_DEPARTMENTS[@]}" "${GLOBAL_GROUPS[@]}"; do
        if [[ ${#target_groups[@]} -eq 0 ]] || ! in_array "$grp" "${target_groups[@]}"; then
            target_groups+=("$grp")
        fi
    done

    # Cria cada grupo apenas se ainda não existir no sistema (idempotência)
    for grp in "${target_groups[@]}"; do
        if ! getent group "$grp" >/dev/null 2>&1; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                groupadd "$grp"
            fi
            log_change "Created group '$grp'"
        fi
    done
}

# Gera uma password aleatória com 16 caracteres (sem ':' para não quebrar o chpasswd)
generate_password() {
    head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9@#%^*_+=-' | cut -c1-16
}

# Guarda o par username:password em /root/initial-passwords.txt com permissões 0600
save_initial_password() {
    local username="$1"
    local password="$2"

    if [[ ! -f "$INITIAL_PASSWORDS_FILE" ]]; then
        touch "$INITIAL_PASSWORDS_FILE"
    fi
    chmod 0600 "$INITIAL_PASSWORDS_FILE"
    printf '%s:%s\n' "$username" "$password" >> "$INITIAL_PASSWORDS_FILE"
}

# Garante que a conta tem expiração de password de 180 dias e aviso de 14 dias
ensure_password_policy() {
    local username="$1"
    local is_new="$2"
    local needs_update=0

    if [[ "$is_new" -eq 1 ]]; then
        needs_update=1
    else
        # chage -l lê /etc/shadow (só root); se falhar em --dry-run sem root, ignora com segurança
        local chage_out
        if chage_out="$(LC_ALL=C chage -l "$username" 2>/dev/null)"; then
            local max_days warn_days
            max_days="$(echo "$chage_out" | awk -F': ' '/Maximum number of days between password change/{print $2}')"
            warn_days="$(echo "$chage_out" | awk -F': ' '/Number of days of warning before password expires/{print $2}')"
            if [[ "$max_days" != "180" || "$warn_days" != "14" ]]; then
                needs_update=1
            fi
        fi
    fi

    if [[ "$needs_update" -eq 1 ]]; then
        if [[ "$DRY_RUN" -eq 0 ]]; then
            chage -M 180 -W 14 "$username"
        fi
        log_change "Set password aging for '$username' (max 180 days, warn 14 days)"
    fi
}

# Aplica expiração de conta para intern (chage -E <end_date>) e remove para staff/manager (chage -E -1)
ensure_account_expiry() {
    local username="$1"
    local role="$2"
    local end_date="$3"
    local is_new="$4"

    if [[ "$role" == "intern" ]]; then
        local needs_update=0
        if [[ "$is_new" -eq 1 ]]; then
            needs_update=1
        else
            local chage_out
            if chage_out="$(LC_ALL=C chage -l "$username" 2>/dev/null)"; then
                local exp_raw current_exp=""
                exp_raw="$(echo "$chage_out" | awk -F': ' '/Account expires/{print $2}')"
                if [[ "$exp_raw" != "never" && -n "$exp_raw" ]]; then
                    current_exp="$(date -d "$exp_raw" '+%Y-%m-%d' 2>/dev/null || true)"
                fi
                if [[ "$current_exp" != "$end_date" ]]; then
                    needs_update=1
                fi
            fi
        fi

        if [[ "$needs_update" -eq 1 ]]; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                chage -E "$end_date" "$username"
            fi
            log_change "Set account expiry for intern '$username' to $end_date"
        fi
    else
        # Contas novas não-intern já nascem sem expiração; só verifica contas existentes
        if [[ "$is_new" -eq 0 ]]; then
            local chage_out
            if chage_out="$(LC_ALL=C chage -l "$username" 2>/dev/null)"; then
                local exp_raw
                exp_raw="$(echo "$chage_out" | awk -F': ' '/Account expires/{print $2}')"
                if [[ "$exp_raw" != "never" && -n "$exp_raw" ]]; then
                    if [[ "$DRY_RUN" -eq 0 ]]; then
                        chage -E -1 "$username"
                    fi
                    log_change "Removed account expiry for '$username' (role: $role)"
                fi
            fi
        fi
    fi
}

# Sincroniza pertença exata a grupos geridos (departamento atual + employees + managers se manager)
ensure_user_groups() {
    local username="$1"
    local dept="$2"
    local role="$3"
    local is_new="$4"

    local target_groups=("$dept" "employees")
    if [[ "$role" == "manager" ]]; then
        target_groups+=("managers")
    fi

    local current_groups=()
    if [[ "$is_new" -eq 0 ]]; then
        read -r -a current_groups <<< "$(id -nG "$username")"
    fi

    # Adiciona grupos em falta
    local grp
    for grp in "${target_groups[@]}"; do
        if [[ ${#current_groups[@]} -eq 0 ]] || ! in_array "$grp" "${current_groups[@]}"; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                usermod -aG "$grp" "$username"
            fi
            log_change "Added '$username' to group '$grp'"
        fi
    done

    # Remove grupos geridos antigos (ex: mudou de departamento ou deixou de ser manager)
    if [[ "$is_new" -eq 0 && ${#current_groups[@]} -gt 0 ]]; then
        local managed_groups=("${VALID_DEPARTMENTS[@]}" "${GLOBAL_GROUPS[@]}")
        for grp in "${current_groups[@]}"; do
            if in_array "$grp" "${managed_groups[@]}" && ! in_array "$grp" "${target_groups[@]}"; then
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    gpasswd -d "$username" "$grp" >/dev/null
                fi
                log_change "Removed '$username' from group '$grp'"
            fi
        done
    fi
}

# Cria contas novas para funcionários ativos e atualiza o GECOS se o nome mudou
ensure_users() {
    if [[ ${#EMP_IDS[@]} -eq 0 ]]; then
        return 0
    fi

    local emp_id
    for emp_id in "${EMP_IDS[@]}"; do
        local status="${EMP_STATUS["$emp_id"]}"
        if [[ "$status" != "active" ]]; then
            continue
        fi

        local username="${EMP_USERNAME["$emp_id"]}"
        local first="${EMP_FIRST["$emp_id"]}"
        local last="${EMP_LAST["$emp_id"]}"
        local expected_gecos="${first} ${last} (${emp_id})"
        local home_dir="/home/${username}"
        local is_new=0

        # Se já existe uma conta gerida para este employee_id, verifica apenas se o GECOS mudou
        if [[ -n "${EXISTING_EMP_USER["$emp_id"]:-}" ]]; then
            local current_gecos="${EXISTING_EMP_GECOS["$emp_id"]:-}"
            if [[ "$current_gecos" != "$expected_gecos" ]]; then
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    usermod -c "$expected_gecos" "$username"
                fi
                log_change "Updated GECOS for '$username' ($emp_id): '$current_gecos' -> '$expected_gecos'"
            fi
        else
            is_new=1
            # Conta nova: cria com home /home/<username> (0700), shell /bin/bash e comment First Last (ID)
            if [[ "$DRY_RUN" -eq 0 ]]; then
                useradd -m -d "$home_dir" -s /bin/bash -c "$expected_gecos" "$username"
                chmod 0700 "$home_dir"

                # Gera password aleatória (>= 16 chars), aplica via chpasswd, força troca no 1.º login e guarda em 0600
                local init_pass
                init_pass="$(generate_password)"
                printf '%s:%s\n' "$username" "$init_pass" | chpasswd
                chage -d 0 "$username"
                save_initial_password "$username" "$init_pass"

                record_used_username "$username"
                EXISTING_EMP_USER["$emp_id"]="$username"
                EXISTING_EMP_GECOS["$emp_id"]="$expected_gecos"
            fi
            log_change "Created user '$username' ($emp_id) with home '$home_dir' (password set, must change at first login)"
        fi

        ensure_password_policy "$username" "$is_new"
        ensure_account_expiry "$username" "${EMP_ROLE["$emp_id"]}" "${EMP_END_DATE["$emp_id"]:-}" "$is_new"
        ensure_user_groups "$username" "${EMP_DEPT["$emp_id"]}" "${EMP_ROLE["$emp_id"]}" "$is_new"
    done
}

# Garante que apenas membros active não-intern do departamento 'it' pertencem ao grupo sudo
ensure_sudo_access() {
    if ! getent group sudo >/dev/null 2>&1; then
        return 0
    fi

    # Lista de usernames elegíveis para sudo segundo o CSV atual
    local sudo_eligible=()
    local emp_id
    for emp_id in "${EMP_IDS[@]}"; do
        if [[ "${EMP_STATUS["$emp_id"]}" == "active" && \
              "${EMP_DEPT["$emp_id"]}" == "it" && \
              "${EMP_ROLE["$emp_id"]}" != "intern" ]]; then
            sudo_eligible+=("${EMP_USERNAME["$emp_id"]}")
        fi
    done

    # Lê os membros atuais do grupo sudo
    local sudo_members_csv
    sudo_members_csv="$(getent group sudo | awk -F: '{print $4}')"
    local current_sudo=()
    if [[ -n "$sudo_members_csv" ]]; then
        IFS=',' read -r -a current_sudo <<< "$sudo_members_csv"
    fi

    # Adiciona elegíveis que ainda não estejam em sudo
    local user
    for user in "${sudo_eligible[@]}"; do
        if [[ ${#current_sudo[@]} -eq 0 ]] || ! in_array "$user" "${current_sudo[@]}"; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                usermod -aG sudo "$user"
            fi
            log_change "Added '$user' to 'sudo' group (active non-intern IT)"
        fi
    done

    # Remove utilizadores geridos que estejam em sudo sem serem elegíveis
    if [[ ${#current_sudo[@]} -gt 0 ]]; then
        local managed_users=()
        local key
        for key in "${!EXISTING_EMP_USER[@]}"; do
            managed_users+=("${EXISTING_EMP_USER["$key"]}")
        done
        for key in "${!EMP_USERNAME[@]}"; do
            managed_users+=("${EMP_USERNAME["$key"]}")
        done

        for user in "${current_sudo[@]}"; do
            [[ -z "$user" ]] && continue
            if in_array "$user" "${managed_users[@]}"; then
                if [[ ${#sudo_eligible[@]} -eq 0 ]] || ! in_array "$user" "${sudo_eligible[@]}"; then
                    if [[ "$DRY_RUN" -eq 0 ]]; then
                        gpasswd -d "$user" sudo >/dev/null
                    fi
                    log_change "Removed '$user' from 'sudo' group (not active non-intern IT)"
                fi
            fi
        done
    fi
}

# Trata o offboarding de utilizadores com status=left
offboard_users() {
    if [[ ${#EMP_IDS[@]} -eq 0 ]]; then
        return 0
    fi

    local emp_id
    for emp_id in "${EMP_IDS[@]}"; do
        if [[ "${EMP_STATUS["$emp_id"]}" != "left" ]]; then
            continue
        fi

        local username="${EXISTING_EMP_USER["$emp_id"]:-}"

        # Passo 3.1: status=left sem conta Linux existente -> não faz nada
        if [[ -z "$username" ]] || ! id "$username" >/dev/null 2>&1; then
            continue
        fi

        # Passo 3.2: status=left com conta Linux existente -> offboarding completo e seguro
        local today home_dir archive_path
        today="$(date '+%Y-%m-%d')"
        home_dir="$(getent passwd "$username" | cut -d: -f6)"
        archive_path="${ARCHIVE_DIR}/${username}_${emp_id}_${today}.tar.gz"

        # 1. Bloquear a conta e terminar sessões/processos ativos antes de mexer em ficheiros
        if [[ "$DRY_RUN" -eq 0 ]]; then
            # usermod -L bloqueia a password; chage -E 0 expira a conta (impede também login por chave SSH)
            usermod -L "$username"
            chage -E 0 "$username"
            # Termina processos do utilizador (|| true evita abortar com set -e se não houver processos ativos)
            pkill -TERM -u "$username" 2>/dev/null || true
            sleep 1
            pkill -KILL -u "$username" 2>/dev/null || true
        fi
        log_change "Locked account and terminated active sessions for '$username' ($emp_id)"

        # 2. Arquivar pasta home em /srv/archive/<username>_<id>_<YYYY-MM-DD>.tar.gz (só root lê) e validar integridade
        if [[ -n "$home_dir" && -d "$home_dir" ]]; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                # Garante que /srv/archive existe e só é acessível por root (0700)
                mkdir -p "$ARCHIVE_DIR"
                chown root:root "$ARCHIVE_DIR"
                chmod 0700 "$ARCHIVE_DIR"

                # Cria o .tar.gz relativo ao diretório pai da home para evitar caminhos absolutos dentro do tar
                tar -czf "$archive_path" -C "$(dirname "$home_dir")" "$(basename "$home_dir")"
                chown root:root "$archive_path"
                chmod 0600 "$archive_path"

                # Verifica integridade do gzip e da tabela de conteúdos do tar antes de apagar qualquer ficheiro
                if ! gzip -t "$archive_path" || ! tar -tzf "$archive_path" >/dev/null 2>&1; then
                    fatal "Archive integrity check failed for '$archive_path'; aborting offboarding of '$username'"
                fi
            fi
            log_change "Archived home '$home_dir' to '$archive_path' (verified)"
        fi

        # 3. Mudar o dono dos ficheiros do utilizador em /srv/company para root (mantendo o grupo original)
        if [[ -d "$COMPANY_DIR" ]]; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                # chown -h root (sem :grupo) altera apenas o owner e preserva o grupo; -h não segue symlinks
                find "$COMPANY_DIR" -user "$username" -exec chown -h root {} +
            fi
            log_change "Reassigned files owned by '$username' in '$COMPANY_DIR' to root (group preserved)"
        fi

        # 4. Garantir que o username fica no histórico persistente (nunca reutilizar) e remover crontab, conta e home
        if [[ "$DRY_RUN" -eq 0 ]]; then
            record_used_username "$username"
            # || true evita falha caso o utilizador não tenha nenhuma crontab configurada
            crontab -r -u "$username" 2>/dev/null || true
            # userdel -r remove a conta e a home; se falhar por não haver mail spool/home, garante remoção da conta
            userdel -r "$username" 2>/dev/null || userdel "$username"
        fi
        log_change "Removed crontab, account, and home for '$username' ($emp_id)"
    done
}

# Passo 3.3: Deteta utilizadores geridos ((E...) no GECOS) que desapareceram do CSV sem status=left
warn_missing_users() {
    if [[ ${#EXISTING_EMP_USER[@]} -eq 0 ]]; then
        return 0
    fi

    local emp_id
    for emp_id in "${!EXISTING_EMP_USER[@]}"; do
        # Se o employee_id existe no sistema mas não aparece no CSV atual, apenas avisa (não remove)
        if [[ -z "${EMP_STATUS["$emp_id"]:-}" ]]; then
            local username="${EXISTING_EMP_USER["$emp_id"]}"
            echo "Warning: Managed user '$username' ($emp_id) is missing from CSV without status=left; account NOT removed." >&2
        fi
    done
}

# Devolve o primeiro grupo com acesso rwx para uma pasta da política (ou 'root' se não existir nenhum)
get_folder_group_owner() {
    local folder="$1"
    local rules="${POLICY_RULES["$folder"]:-}"
    local entry grp acc

    for entry in $rules; do
        IFS=':' read -r grp acc <<< "$entry"
        if [[ "$acc" == "rwx" ]]; then
            echo "$grp"
            return 0
        fi
    done

    echo "root"
}

# Passo 4.1: Cria as pastas definidas em access-policy.csv com owner root,
# group owner = 1.º grupo rwx, setgid ativo (g+s) e sem acesso para others (2770)
ensure_shared_folders() {
    # Garante a pasta raiz /srv/company (caso não esteja na política) com travessia mínima para não-root
    if [[ ${#POLICY_FOLDERS[@]} -eq 0 ]] || ! in_array "$COMPANY_DIR" "${POLICY_FOLDERS[@]}"; then
        if [[ ! -d "$COMPANY_DIR" ]]; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                mkdir -p "$COMPANY_DIR"
                chown root:root "$COMPANY_DIR"
                chmod 0711 "$COMPANY_DIR"
            fi
            log_change "Created company root '$COMPANY_DIR' (owner=root:root, mode=0711)"
        fi
    fi

    local folder target_group
    for folder in "${POLICY_FOLDERS[@]}"; do
        target_group="$(get_folder_group_owner "$folder")"

        if [[ ! -d "$folder" ]]; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                mkdir -p "$folder"
                chown "root:$target_group" "$folder"
                chmod 2770 "$folder"
            fi
            log_change "Created shared folder '$folder' (owner=root:$target_group, mode=2770)"
            continue
        fi

        local current_owner current_group current_mode
        current_owner="$(stat -c '%U' "$folder")"
        current_group="$(stat -c '%G' "$folder")"
        current_mode="$(stat -c '%a' "$folder")"

        if [[ "$current_owner" != "root" || "$current_group" != "$target_group" ]]; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                chown "root:$target_group" "$folder"
            fi
            log_change "Updated ownership on '$folder' to root:$target_group"
        fi

        if [[ "$current_mode" != "2770" ]]; then
            if [[ "$DRY_RUN" -eq 0 ]]; then
                chmod 2770 "$folder"
            fi
            log_change "Updated base permissions on '$folder' to 2770"
        fi
    done
}

# Normaliza o output de getfacl -p --omit-header para comparação idempotente:
# remove comentários (#...), linhas vazias e ordena as entradas
normalize_getfacl() {
    local target="$1"
    getfacl -p --omit-header "$target" 2>/dev/null | sed 's/[[:space:]]*#.*$//' | grep -v '^$' | sort
}

# Passo 4.3: Devolve os grupos que precisam de travessia mínima (--x) nesta pasta
# porque têm acesso a uma subpasta descendente, mas não têm regra nesta pasta-pai
get_traversal_groups_for_folder() {
    local parent_folder="$1"
    local parent_rules="${POLICY_RULES["$parent_folder"]:-}"
    local parent_groups=()
    local entry grp acc

    for entry in $parent_rules; do
        IFS=':' read -r grp acc <<< "$entry"
        parent_groups+=("$grp")
    done

    local traversal_groups=()
    local sub sub_rules
    for sub in "${POLICY_FOLDERS[@]}"; do
        # Só interessa se sub for descendente estrito de parent_folder
        if [[ "$sub" != "$parent_folder/"* ]]; then
            continue
        fi

        sub_rules="${POLICY_RULES["$sub"]:-}"
        for entry in $sub_rules; do
            IFS=':' read -r grp acc <<< "$entry"
            if [[ ${#parent_groups[@]} -gt 0 ]] && in_array "$grp" "${parent_groups[@]}"; then
                continue
            fi
            if [[ ${#traversal_groups[@]} -eq 0 ]] || ! in_array "$grp" "${traversal_groups[@]}"; then
                traversal_groups+=("$grp")
            fi
        done
    done

    if [[ ${#traversal_groups[@]} -gt 0 ]]; then
        printf '%s\n' "${traversal_groups[@]}"
    fi
}

# Passo 4.4: Devolve os usernames de estagiários (intern) ativos cujo departamento
# tem acesso rwx nesta pasta (para receberem ACL individual r-x)
get_folder_interns() {
    local folder="$1"
    local rules="${POLICY_RULES["$folder"]:-}"
    local emp_id dept

    for emp_id in "${EMP_IDS[@]}"; do
        if [[ "${EMP_STATUS["$emp_id"]}" != "active" || "${EMP_ROLE["$emp_id"]}" != "intern" ]]; then
            continue
        fi

        dept="${EMP_DEPT["$emp_id"]}"
        # Verifica se "<dept>:rwx" consta nas regras desta pasta
        if echo " $rules " | grep -qF " ${dept}:rwx "; then
            echo "${EMP_USERNAME["$emp_id"]}"
        fi
    done
}

# Verifica se um caminho pertence a outra pasta da política mais específica do que owner_folder
# (evita que setfacl em /srv/company/hr sobrescreva /srv/company/hr/payroll)
is_under_other_policy_folder() {
    local path="$1"
    local owner_folder="$2"
    local other

    for other in "${POLICY_FOLDERS[@]}"; do
        if [[ "$other" == "$owner_folder/"* ]]; then
            if [[ "$path" == "$other" || "$path" == "$other/"* ]]; then
                return 0
            fi
        fi
    done
    return 1
}

# Garante ACLs e default ACLs exatas numa pasta (com verificação idempotente prévia)
sync_directory_acl() {
    local target="$1"
    local rules="$2"
    local traversal_list="$3"
    local interns_list="$4"

    local access_entries=("u::rwx" "g::rwx" "o::---" "m::rwx")
    local default_entries=("u::rwx" "g::rwx" "o::---" "m::rwx")
    local expected_lines=("user::rwx" "group::rwx" "other::---" "mask::rwx" "default:user::rwx" "default:group::rwx" "default:other::---" "default:mask::rwx")

    local entry grp acc
    for entry in $rules; do
        IFS=':' read -r grp acc <<< "$entry"
        access_entries+=("g:${grp}:${acc}")
        default_entries+=("g:${grp}:${acc}")
        expected_lines+=("group:${grp}:${acc}" "default:group:${grp}:${acc}")
    done

    local tgrp
    for tgrp in $traversal_list; do
        access_entries+=("g:${tgrp}:--x")
        expected_lines+=("group:${tgrp}:--x")
    done

    local intern_user
    for intern_user in $interns_list; do
        access_entries+=("u:${intern_user}:r-x")
        default_entries+=("u:${intern_user}:r-x")
        expected_lines+=("user:${intern_user}:r-x" "default:user:${intern_user}:r-x")
    done

    local expected_sorted
    expected_sorted="$(printf '%s\n' "${expected_lines[@]}" | sort)"

    local needs_update=0
    if [[ ! -d "$target" ]]; then
        needs_update=1
    else
        local current_sorted
        current_sorted="$(normalize_getfacl "$target")"
        if [[ "$current_sorted" != "$expected_sorted" ]]; then
            needs_update=1
        fi
    fi

    if [[ "$needs_update" -eq 1 ]]; then
        local access_spec default_spec
        access_spec="$(IFS=','; echo "${access_entries[*]}")"
        default_spec="$(IFS=','; echo "${default_entries[*]}")"

        if [[ "$DRY_RUN" -eq 0 ]]; then
            setfacl -b "$target"
            setfacl -m "$access_spec" "$target"
            setfacl -d -m "$default_spec" "$target"
        fi
        log_change "Synchronized ACLs and default ACLs on '$target'"
    fi
}

# Garante ACLs exatas num ficheiro regular existente (rwX/r-X para não dar +x indevido)
sync_file_acl() {
    local target="$1"
    local rules="$2"
    local interns_list="$3"

    # Mantém x apenas se o ficheiro já for executável
    local x_bit="-"
    if [[ -x "$target" ]]; then
        x_bit="x"
    fi

    local access_entries=("u::rw${x_bit}" "g::rw${x_bit}" "o::---" "m::rw${x_bit}")
    local expected_lines=("user::rw${x_bit}" "group::rw${x_bit}" "other::---" "mask::rw${x_bit}")

    local entry grp acc file_acc
    for entry in $rules; do
        IFS=':' read -r grp acc <<< "$entry"
        if [[ "$acc" == "rwx" ]]; then
            file_acc="rw${x_bit}"
        else
            file_acc="r-${x_bit}"
        fi
        access_entries+=("g:${grp}:${file_acc}")
        expected_lines+=("group:${grp}:${file_acc}")
    done

    local intern_user
    for intern_user in $interns_list; do
        access_entries+=("u:${intern_user}:r-${x_bit}")
        expected_lines+=("user:${intern_user}:r-${x_bit}")
    done

    local expected_sorted
    expected_sorted="$(printf '%s\n' "${expected_lines[@]}" | sort)"
    local current_sorted
    current_sorted="$(normalize_getfacl "$target")"

    if [[ "$current_sorted" != "$expected_sorted" ]]; then
        local access_spec
        access_spec="$(IFS=','; echo "${access_entries[*]}")"

        if [[ "$DRY_RUN" -eq 0 ]]; then
            setfacl -b "$target"
            setfacl -m "$access_spec" "$target"
        fi
        log_change "Synchronized ACLs on existing file '$target'"
    fi
}

# Passos 4.2, 4.3, 4.4, 4.5 e 4.6: Aplica ACLs da política, default ACLs,
# travessia --x em pastas-pai, exceção r-x para interns e sincronização de conteúdo existente
ensure_folder_acls() {
    local folder rules traversal_list interns_list

    for folder in "${POLICY_FOLDERS[@]}"; do
        rules="${POLICY_RULES["$folder"]:-}"
        traversal_list="$(get_traversal_groups_for_folder "$folder")"
        interns_list="$(get_folder_interns "$folder")"

        # Aplica ACLs exatas e default ACLs na própria pasta da política
        sync_directory_acl "$folder" "$rules" "$traversal_list" "$interns_list"

        # Passo 4.5: Se a pasta já existe, garante que subpastas e ficheiros já existentes seguem a política
        if [[ -d "$folder" ]]; then
            local item
            while IFS= read -r -d '' item; do
                # Não sobrescreve subpastas que tenham regra própria na política (ex: /srv/company/hr/payroll)
                if is_under_other_policy_folder "$item" "$folder"; then
                    continue
                fi

                if [[ -d "$item" ]]; then
                    sync_directory_acl "$item" "$rules" "" "$interns_list"
                elif [[ -f "$item" ]]; then
                    sync_file_acl "$item" "$rules" "$interns_list"
                fi
            done < <(find "$folder" -mindepth 1 -print0)
        fi
    done
}

main() {
    parse_args "$@"
    check_pre_reqs
    check_headers
    load_policy
    extract_departments
    load_employees
    load_existing_users
    resolve_usernames
    ensure_groups
    ensure_users
    ensure_sudo_access
    offboard_users
    warn_missing_users
    ensure_shared_folders
    ensure_folder_acls

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
