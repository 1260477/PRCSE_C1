#!/usr/bin/env bash
set -euo pipefail

# Códigos de saída
readonly EXIT_OK=0
readonly EXIT_FATAL=1

# Limiares e opções, com os valores por omissão do enunciado (Secção 3)
BRUTE_THRESHOLD=10   # -b: falhas de password para brute force
BRUTE_WINDOW=5       # -w: janela do brute force, em minutos
SPRAY_THRESHOLD=5    # -s: usernames distintos em 60 min para password spray
FAIL_THRESHOLD=5     # -f: falhas antes de um login com sucesso
TOP_N=10             # -t: quantos IPs/usernames mostrar nos tops

# Ficheiros de log recebidos na linha de comandos (plain ou .gz, qualquer ordem)
LOG_FILES=()

# Mostra as instruções de utilização do script
usage() {
    cat <<'EOF'
Usage: analyze_auth.sh [-h] [-b N] [-w MIN] [-s N] [-f N] [-t N] FILE...

Analyze one or more auth.log files (plain or .gz, in any order) and print
a security incident report.

Options:
  -b N        Brute force threshold: failed passwords (default: 10)
  -w MIN      Brute force window in minutes (default: 5)
  -s N        Password spray threshold: distinct usernames in 60 min (default: 5)
  -f N        Successful login after >= N failures in prior 60 min (default: 5)
  -t N        Top N IPs and usernames to display (default: 10)
  -h, --help  Show this help message and exit
EOF
}

# Imprime uma mensagem de erro para stderr e termina com exit code 1
fatal() {
    echo "Error: $*" >&2
    exit "$EXIT_FATAL"
}

# Valida que o valor de uma opção é um inteiro positivo (> 0)
# $1 = nome da opção (para a mensagem de erro), $2 = valor recebido
require_positive_int() {
    local option="$1"
    local value="$2"

    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        fatal "Option $option requires a positive integer, got '$value'."
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
            -b|-w|-s|-f|-t)
                # Estas opções precisam de um valor a seguir
                if [[ $# -lt 2 ]]; then
                    fatal "Option $1 requires a value."
                fi
                require_positive_int "$1" "$2"

                case "$1" in
                    -b) BRUTE_THRESHOLD="$2" ;;
                    -w) BRUTE_WINDOW="$2" ;;
                    -s) SPRAY_THRESHOLD="$2" ;;
                    -f) FAIL_THRESHOLD="$2" ;;
                    -t) TOP_N="$2" ;;
                esac
                shift 2   # Avança a opção e o seu valor
                ;;
            -*)
                # Qualquer outra flag começada por '-' é inválida
                fatal "Unknown option '$1'. Use -h for help."
                ;;
            *)
                # Argumentos posicionais: ficheiros de log
                LOG_FILES+=("$1")
                shift
                ;;
        esac
    done

    # Garante que foi dado pelo menos um ficheiro de log
    if [[ "${#LOG_FILES[@]}" -eq 0 ]]; then
        echo "Error: no log files given. At least one FILE is required." >&2
        echo >&2
        usage >&2
        exit "$EXIT_FATAL"
    fi
}

# Verifica se um ficheiro está comprimido com gzip pelo conteúdo, não pela extensão:
# os 2 primeiros bytes de um ficheiro gzip são sempre 1f 8b ("magic number")
is_gzip() {
    local file="$1"
    local magic

    # head -c 2 lê 2 bytes; od -An -tx1 mostra-os em hexadecimal (ex: " 1f 8b")
    magic="$(head -c 2 "$file" | od -An -tx1 | tr -d ' \n')"
    [[ "$magic" == "1f8b" ]]
}

# Valida os ficheiros de entrada (não precisa de root: só lê os logs)
# - Ficheiro inexistente ou ilegível: erro fatal
# - Ficheiro gzip corrompido: aviso e é ignorado (a análise continua com os restantes)
check_pre_reqs() {
    local file
    local valid_files=()

    for file in "${LOG_FILES[@]}"; do
        # Cada ficheiro tem de ser um ficheiro regular e legível
        if [[ ! -f "$file" || ! -r "$file" ]]; then
            fatal "Log file not found or not readable: $file"
        fi

        # Se for gzip, gzip -t testa a integridade sem descomprimir para o disco
        if is_gzip "$file" && ! gzip -t "$file" 2>/dev/null; then
            echo "Warning: compressed file is corrupted, skipping: $file" >&2
            continue
        fi

        valid_files+=("$file")
    done

    # Se todos os ficheiros foram ignorados, não há nada para analisar
    if [[ "${#valid_files[@]}" -eq 0 ]]; then
        fatal "No valid log files to analyze."
    fi

    # Daqui em diante só se usam os ficheiros válidos
    LOG_FILES=("${valid_files[@]}")
}

main() {
    parse_args "$@"
    check_pre_reqs

    echo "TODO: implement analyze_auth.sh" >&2
    exit "$EXIT_FATAL"
}

# Corre main só quando o script é executado diretamente (não quando é feito 'source' nos testes)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
