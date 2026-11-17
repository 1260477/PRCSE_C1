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

# Ficheiro temporário com os eventos já preparados (criado em read_logs)
EVENTS_FILE=""

# Resultados das deteções, uma linha CSV por elemento (preenchidos pelas detect_*,
# lidos por print_report). Vírgula como separador: não aparece em timestamps nem
# em usernames Linux, e a lista de usernames (com espaços) fica num só campo.
# BRUTE_RESULTS: ip,first_attempt,last_attempt,failures,top_usernames
BRUTE_RESULTS=()

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

# Lê todos os ficheiros de LOG_FILES (plain ou gzip) e prepara os eventos por ordem cronológica
read_logs() {
    # mktemp cria um ficheiro com nome único, de forma atómica e com permissões 600
    EVENTS_FILE="$(mktemp)" || fatal "Could not create temporary file."

    # Apaga o ficheiro temporário sempre que o script termina (normal, erro ou Ctrl+C).
    # As aspas simples adiam a expansão de $EVENTS_FILE para o momento da saída.
    trap 'rm -f "$EVENTS_FILE"' EXIT

    # Junta o conteúdo de todos os ficheiros no ficheiro temporário.
    # O gzip é detetado pelo conteúdo (is_gzip), não pela extensão (assunção 1).
    local file
    for file in "${LOG_FILES[@]}"; do
        if is_gzip "$file"; then
            # gzip -dc descomprime para o stdout, sem alterar o ficheiro original
            gzip -dc "$file"
        else
            cat "$file"
        fi | awk 1
        # awk 1: imprime cada linha seguida de \n, incluindo a última. Garante que cada
        # ficheiro termina com quebra de linha, para que a última linha de um ficheiro
        # não fique colada à primeira do seguinte. Fica depois do 'fi' (e não do 'done')
        # para atuar em cada ficheiro, seja texto ou gzip.
    done | LC_ALL=C sort | LC_ALL=C uniq > "$EVENTS_FILE"
    # - sort: o timestamp ISO 8601 está no início da linha, por isso a ordem
    #   alfabética da linha inteira é a ordem cronológica
    # - uniq: remove linhas exatamente iguais (assunção 5); só funciona em linhas
    #   adjacentes, por isso tem de vir depois do sort
    # - LC_ALL=C: compara byte a byte; resultado igual em qualquer máquina e mais rápido

    # Se não houver nenhum evento (ex: todos os ficheiros vazios), não há nada a analisar.
    # -s é verdadeiro se o ficheiro existir e tiver tamanho > 0.
    # O trap EXIT apaga o ficheiro temporário mesmo saindo por aqui.
    if [[ ! -s "$EVENTS_FILE" ]]; then
        fatal "No log entries found in the given files."
    fi
}

# Secção 3.2: deteta IPs com >= BRUTE_THRESHOLD falhas de password numa janela de BRUTE_WINDOW minutos
detect_brute_force() {
    # 1.º awk: das linhas "Failed password" imprime "IP timestamp username".
    #   O IP é o campo a seguir a "from" (a coluna muda com/sem "invalid user")
    #   e o username é o campo antes de "from".
    # sort: agrupa por IP (-k1,1 = só a 1.ª coluna). -s (estável) mantém a ordem
    #   original dentro de cada IP, que já é cronológica (EVENTS_FILE está ordenado).
    # 2.º awk: janela deslizante, um IP de cada vez.
    # mapfile: guarda cada linha do output do pipeline num elemento de BRUTE_RESULTS.
    #   Usa-se "< <(...)" e não "pipeline | mapfile": num pipe o mapfile correria
    #   num subshell e o array global ficaria vazio.
    mapfile -t BRUTE_RESULTS < <(awk '/Failed password/ {
        for (i = 1; i <= NF; i++) {
            if ($i == "from") {
                user = $(i-1)
                # "invalid user  from": username vazio. O awk junta os dois espaços,
                # por isso o campo antes de "from" seria a palavra "user" da mensagem
                if ($(i-2) == "invalid" && $(i-1) == "user")
                    user = "<empty>"
                print $(i+1), $1, user
            }
        }
    }' "$EVENTS_FILE" \
    | LC_ALL=C sort -s -k1,1 \
    | TZ=UTC awk -v n="$BRUTE_THRESHOLD" -v window="$((BRUTE_WINDOW * 60))" '
        # Converte "2026-10-30T14:05:42.527481+00:00" em segundos desde 1970 (epoch).
        # mktime espera "YYYY MM DD HH MM SS"; TZ=UTC evita depender do fuso da máquina.
        function to_epoch(ts) {
            ts = substr(ts, 1, 19)       # "2026-10-30T14:05:42" (sem fração nem fuso)
            gsub(/[-T:]/, " ", ts)       # "2026 10 30 14 05 42"
            return mktime(ts)
        }

        # Devolve os "top" usernames mais tentados do IP atual, no formato "user(N) ..."
        # Procura o máximo, guarda-o e remove-o do array; repete "top" vezes
        function top_users(top, list, j, u, best) {
            list = ""
            for (j = 1; j <= top; j++) {
                best = ""
                for (u in users)
                    if (best == "" || users[u] > users[best])
                        best = u
                if (best == "")
                    break                # já não há mais usernames
                if (list != "")
                    list = list " "      # espaço só entre usernames, não no início
                list = list best "(" users[best] ")"
                delete users[best]
            }
            return list
        }

        # Fecha o IP anterior: se foi detetado, imprime-o numa linha CSV
        function report() {
            if (detected)
                print prev_ip "," first_ts "," last_ts "," k "," top_users(3)
        }

        {
            # Começa um IP novo: fecha o anterior e reinicia o estado
            if ($1 != prev_ip) {
                report()
                prev_ip = $1
                k = 0
                detected = 0
                first_ts = $2            # primeira tentativa (texto original, para o output)
                # Ao contrário de t[k], a chave aqui é o username: sem limpar, os
                # usernames do IP anterior somavam-se aos deste
                delete users
            }

            users[$3]++                  # tentativas por username, só deste IP
            k++                          # número desta falha dentro do IP
            t[k] = to_epoch($2)          # tempo da falha k, em segundos
            last_ts = $2                 # última tentativa vista até agora

            # Janela deslizante: o bloco de N falhas que termina na falha k
            # começa na falha k - N + 1, que só existe quando k >= N
            if (k >= n && t[k] - t[k - n + 1] <= window)
                detected = 1
        }

        # O último IP não tem nenhum IP a seguir que o feche
        END { report() }
    ')
}

# Imprime o relatório a partir dos arrays de resultados das detect_*
print_report() {
    local line ip first last failures users

    echo "=== Brute force (>= $BRUTE_THRESHOLD failed passwords in $BRUTE_WINDOW min) ==="
    if [[ "${#BRUTE_RESULTS[@]}" -eq 0 ]]; then
        echo "No brute force attacks detected."
    else
        for line in "${BRUTE_RESULTS[@]}"; do
            # IFS=, só para este read: parte a linha CSV nos 5 campos
            IFS=, read -r ip first last failures users <<< "$line"
            echo "IP: $ip"
            echo "  First attempt: $first"
            echo "  Last attempt:  $last"
            echo "  Failures:      $failures"
            echo "  Top usernames: $users"
        done
    fi
}

main() {
    parse_args "$@"
    check_pre_reqs
    read_logs
    detect_brute_force
    print_report

    echo "TODO: implement analyze_auth.sh" >&2
    exit "$EXIT_FATAL"
}

# Corre main só quando o script é executado diretamente (não quando é feito 'source' nos testes)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
