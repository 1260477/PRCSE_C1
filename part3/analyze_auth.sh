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

# Valores fixos do enunciado (3.3 e 3.4), sem opção na linha de comandos
readonly SPRAY_WINDOW=60   # janela do password spray, em minutos
readonly SPRAY_MAX_AVG=3   # máximo de tentativas por username, em média
readonly SUCCESS_WINDOW=60 # janela das falhas antes de um login com sucesso, em minutos
readonly TYPO_MAX=3        # falhas do IP habitual que ainda são typo (3.4; assunção, não vem do enunciado)

# Ficheiros de log recebidos na linha de comandos (plain ou .gz, qualquer ordem)
LOG_FILES=()

# Ficheiro temporário com os eventos já preparados (criado em read_logs)
EVENTS_FILE=""

# Resultados das deteções, uma linha CSV por elemento (preenchidos pelas detect_*,
# lidos por print_report). Vírgula como separador: não aparece em timestamps nem
# em usernames Linux, e a lista de usernames (com espaços) fica num só campo.
# BRUTE_RESULTS: ip,first_attempt,last_attempt,failures,top_usernames,successes
#   successes: "user@timestamp" de cada login com sucesso do IP, separados por espaço
#   (vazio se não houve nenhum)
BRUTE_RESULTS=()
# SPRAY_RESULTS: ip,first_attempt,last_attempt,num_usernames,existing,non_existing
#   existing / non_existing: usernames separados por espaço, pela ordem da 1.ª tentativa
SPRAY_RESULTS=()
# SUCCESS_RESULTS: ip,user,time,failures_before,reason
#   uma linha por login com sucesso detetado (o mesmo IP pode aparecer mais de uma vez)
#   failures_before: falhas nos 60 minutos antes do login, do mesmo IP ou do mesmo user
#     (se as duas vias detetarem o login, fica o maior dos dois números)
#   reason: ip, user ou both (por qual das vias foi detetado)
SUCCESS_RESULTS=()

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
    # 1.º awk: das linhas "Failed password" e "Accepted password/publickey" imprime
    #   "IP timestamp username tipo" (tipo = fail ou success).
    #   O IP é o campo a seguir a "from" (a coluna muda com/sem "invalid user")
    #   e o username é o campo antes de "from".
    # sort: agrupa por IP (-k1,1 = só a 1.ª coluna). -s (estável) mantém a ordem
    #   original dentro de cada IP, que já é cronológica (EVENTS_FILE está ordenado).
    # 2.º awk: janela deslizante sobre as falhas, um IP de cada vez; os sucessos
    #   são só guardados para o output.
    # mapfile: guarda cada linha do output do pipeline num elemento de BRUTE_RESULTS.
    #   Usa-se "< <(...)" e não "pipeline | mapfile": num pipe o mapfile correria
    #   num subshell e o array global ficaria vazio.
    mapfile -t BRUTE_RESULTS < <(awk '/Failed password/ || /Accepted (password|publickey) for/ {
        type = "fail"
        if (/Accepted (password|publickey) for/)
            type = "success"
        for (i = 1; i <= NF; i++) {
            if ($i == "from") {
                user = $(i-1)
                # "invalid user  from": username vazio. O awk junta os dois espaços,
                # por isso o campo antes de "from" seria a palavra "user" da mensagem
                if ($(i-2) == "invalid" && $(i-1) == "user")
                    user = "<empty>"
                print $(i+1), $1, user, type
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
                print prev_ip "," first_ts "," last_ts "," k "," top_users(3) "," successes
        }

        {
            # Começa um IP novo: fecha o anterior e reinicia o estado
            if ($1 != prev_ip) {
                report()
                prev_ip = $1
                k = 0
                detected = 0
                successes = ""
                # Ao contrário de t[k], a chave aqui é o username: sem limpar, os
                # usernames do IP anterior somavam-se aos deste
                delete users
            }

            # Login com sucesso: guarda "user@timestamp" e passa à linha seguinte,
            # para não contar como falha (não entra em k, t[k] nem users)
            if ($4 == "success") {
                if (successes != "")
                    successes = successes " "
                successes = successes $3 "@" $2
                next
            }

            users[$3]++                  # tentativas por username, só deste IP
            k++                          # número desta falha dentro do IP
            t[k] = to_epoch($2)          # tempo da falha k, em segundos
            # Primeira falha do IP (texto original, para o output). Fica aqui e não
            # na mudança de IP porque o primeiro evento do IP pode ser um sucesso
            if (k == 1)
                first_ts = $2
            last_ts = $2                 # última falha vista até agora

            # Janela deslizante: o bloco de N falhas que termina na falha k
            # começa na falha k - N + 1, que só existe quando k >= N
            if (k >= n && t[k] - t[k - n + 1] <= window)
                detected = 1
        }

        # O último IP não tem nenhum IP a seguir que o feche
        END { report() }
    ')
}

# Secção 3.3: deteta IPs que tentam >= SPRAY_THRESHOLD usernames diferentes em 60 minutos,
# com no máximo 3 tentativas por username em média
detect_password_spray() {
    # 1.º awk: das linhas "Failed password" imprime "IP timestamp username estado".
    #   estado = invalid se a linha diz "for invalid user" (o username não existe
    #   no servidor), valid caso contrário. IP e username encontram-se como no brute force.
    # sort: agrupa por IP mantendo a ordem cronológica (igual ao brute force).
    # 2.º awk: janela deslizante de SPRAY_WINDOW minutos, um IP de cada vez.
    mapfile -t SPRAY_RESULTS < <(awk '/Failed password/ {
        status = "valid"
        if (/Failed password for invalid user /)
            status = "invalid"
        for (i = 1; i <= NF; i++) {
            if ($i == "from") {
                user = $(i-1)
                # "invalid user  from": username vazio (ver detect_brute_force)
                if ($(i-2) == "invalid" && $(i-1) == "user")
                    user = "<empty>"
                print $(i+1), $1, user, status
            }
        }
    }' "$EVENTS_FILE" \
    | LC_ALL=C sort -s -k1,1 \
    | TZ=UTC awk -v n="$SPRAY_THRESHOLD" -v window="$((SPRAY_WINDOW * 60))" \
                 -v max_avg="$SPRAY_MAX_AVG" '
        # Converte o timestamp ISO 8601 em segundos (igual ao detect_brute_force)
        function to_epoch(ts) {
            ts = substr(ts, 1, 19)
            gsub(/[-T:]/, " ", ts)
            return mktime(ts)
        }

        # Fecha o IP anterior: se foi detetado, imprime-o numa linha CSV
        function report() {
            if (detected)
                print prev_ip "," first_ts "," last_ts "," n_users "," existing "," non_existing
        }

        {
            # Começa um IP novo: fecha o anterior e reinicia o estado
            if ($1 != prev_ip) {
                report()
                prev_ip = $1
                k = 0                    # número da falha atual dentro do IP
                left = 1                 # número da falha mais antiga ainda na janela
                distinct = 0             # usernames diferentes dentro da janela
                detected = 0
                n_users = 0              # usernames diferentes em toda a atividade do IP
                existing = ""
                non_existing = ""
                delete in_window         # tentativas por username, só dentro da janela
                delete seen              # usernames já vistos neste IP (para as listas)
            }

            k++
            t[k] = to_epoch($2)          # tempo da falha k, em segundos
            u[k] = $3                    # username da falha k (para saber quem sai da janela)
            if (k == 1)
                first_ts = $2
            last_ts = $2

            # Listas para o output: cada username entra uma vez, na 1.ª tentativa,
            # na lista de existentes ou de não existentes
            if (!($3 in seen)) {
                seen[$3] = 1
                n_users++
                if ($4 == "valid")
                    existing = existing (existing == "" ? "" : " ") $3
                else
                    non_existing = non_existing (non_existing == "" ? "" : " ") $3
            }

            # A falha k entra na janela: se o username ainda não estava lá, é mais um diferente
            in_window[$3]++
            if (in_window[$3] == 1)
                distinct++

            # Saem pela esquerda as falhas a mais de SPRAY_WINDOW minutos da atual.
            # while e não if: podem ter de sair várias de uma vez
            while (t[k] - t[left] > window) {
                in_window[u[left]]--
                if (in_window[u[left]] == 0)
                    distinct--           # já não há nenhuma tentativa deste username na janela
                left++
            }

            # >= N usernames diferentes e média de tentativas por username <= max_avg.
            # (k - left + 1) / distinct <= max_avg, escrito sem divisão (distinct >= 1)
            if (distinct >= n && (k - left + 1) <= max_avg * distinct)
                detected = 1
        }

        # O último IP não tem nenhum IP a seguir que o feche
        END { report() }
    ')
}

# Secção 3.4, passo 1: das linhas "Failed password" e "Accepted password/publickey" imprime
#   "IP timestamp username tipo habitual" (tipo = fail ou success), como no detect_brute_force.
#   O IP é o campo a seguir a "from" e o username é o campo antes de "from".
#   habitual = IP do 1.º login com sucesso anterior desse username ("-" se ainda não
#   houve nenhum, e sempre "-" nas falhas). EVENTS_FILE está por ordem cronológica,
#   por isso o 1.º sucesso que aparece é o mais antigo.
success_events() {
    awk '/Failed password/ || /Accepted (password|publickey) for/ {
        type = "fail"
        if (/Accepted (password|publickey) for/)
            type = "success"
        for (i = 1; i <= NF; i++) {
            if ($i == "from") {
                user = $(i-1)
                # "invalid user  from": username vazio (ver detect_brute_force)
                if ($(i-2) == "invalid" && $(i-1) == "user")
                    user = "<empty>"
                usual = "-"
                if (type == "success") {
                    if (user in first_ip)
                        usual = first_ip[user]       # já houve um sucesso antes deste
                    else
                        first_ip[user] = $(i+1)      # 1.º sucesso: passa a ser o IP habitual
                }
                print $(i+1), $1, user, type, usual
            }
        }
    }' "$EVENTS_FILE"
}

# Secção 3.4, passo 2: janela deslizante de SUCCESS_WINDOW minutos sobre as falhas,
#   um grupo de cada vez. $1 = coluna que define o grupo: 1 (IP) ou 3 (username).
#   O input tem de vir agrupado por essa coluna e em ordem cronológica dentro do grupo.
#   Imprime "ip,user,time,failures,reason" para cada sucesso com >= FAIL_THRESHOLD
#   falhas do mesmo grupo nos SUCCESS_WINDOW minutos antes; reason = ip ou user.
#   Typo: se o sucesso vem do IP habitual do user e as falhas na janela vindas desse
#   IP são <= TYPO_MAX, essas falhas não contam (as de outros IPs contam sempre).
success_window() {
    TZ=UTC awk -v col="$1" -v n="$FAIL_THRESHOLD" -v window="$((SUCCESS_WINDOW * 60))" \
        -v typo_max="$TYPO_MAX" '
        # Converte o timestamp ISO 8601 em segundos (igual ao detect_brute_force)
        function to_epoch(ts) {
            ts = substr(ts, 1, 19)
            gsub(/[-T:]/, " ", ts)
            return mktime(ts)
        }

        BEGIN {
            reason = "ip"
            if (col == 3)
                reason = "user"
        }

        {
            # Começa um grupo novo (IP ou username): reinicia a janela
            if ($col != prev_group) {
                prev_group = $col
                k = 0                    # número da última falha dentro do grupo
                left = 1                 # número da falha mais antiga ainda na janela
            }

            now = to_epoch($2)

            # Falha: só é guardada, para contar quando vier um sucesso
            if ($4 == "fail") {
                k++
                t[k] = now
                ip[k] = $1               # IP da falha k (para o typo)
                next
            }

            # Sucesso: saem pela esquerda as falhas a mais de SUCCESS_WINDOW minutos dele.
            # while e não if: podem ter de sair várias de uma vez.
            # left <= k: não passar da última falha (a janela pode ficar vazia)
            while (left <= k && now - t[left] > window)
                left++

            # Falhas que ficaram na janela = da left à k
            failures = k - left + 1

            # Typo: o sucesso vem do IP habitual ($5) do user. Conta as falhas da
            # janela que vieram desse IP; se forem poucas, tira-as da contagem
            if ($1 == $5) {
                from_usual = 0
                for (j = left; j <= k; j++)
                    if (ip[j] == $1)
                        from_usual++
                if (from_usual <= typo_max)
                    failures -= from_usual
            }

            if (failures >= n)
                print $1 "," $3 "," $2 "," failures "," reason
        }
    '
}

# Secção 3.4: deteta logins com sucesso com >= FAIL_THRESHOLD falhas do mesmo IP
# ou do mesmo username nos SUCCESS_WINDOW minutos antes
detect_success_after_failures() {
    # Corre a janela duas vezes, com o input agrupado de maneiras diferentes:
    #   sort -k1,1 agrupa por IP, sort -k3,3 agrupa por username. -s (estável) mantém
    #   a ordem cronológica dentro de cada grupo (EVENTS_FILE já está ordenado).
    # awk de junção: o mesmo login pode ser detetado pelas duas vias. A chave
    #   "ip,user,time" identifica o login; se aparecer duas vezes fica só uma linha,
    #   com reason = both e o maior número de falhas.
    # sort final: por tempo (3.ª coluna do CSV), para o output sair em ordem cronológica.
    # mapfile: guarda cada linha CSV num elemento de SUCCESS_RESULTS ("< <(...)" pelo
    #   mesmo motivo do detect_brute_force: num pipe o array ficaria vazio).
    mapfile -t SUCCESS_RESULTS < <(
        {
            success_events | LC_ALL=C sort -s -k1,1 | success_window 1
            success_events | LC_ALL=C sort -s -k3,3 | success_window 3
        } | awk -F, '
            {
                key = $1 "," $2 "," $3
                if (!(key in failures)) {
                    order[++count] = key     # guarda a ordem para não usar "for (key in ...)"
                    failures[key] = $4
                    reason[key] = $5
                } else {
                    if ($4 > failures[key])
                        failures[key] = $4
                    reason[key] = "both"
                }
            }
            END {
                for (i = 1; i <= count; i++)
                    print order[i] "," failures[order[i]] "," reason[order[i]]
            }
        ' | LC_ALL=C sort -t, -k3,3
    )
}

# Imprime o relatório a partir dos arrays de resultados das detect_*
print_report() {
    local line ip first last failures users successes login
    local logins=()

    echo "=== Brute force (>= $BRUTE_THRESHOLD failed passwords in $BRUTE_WINDOW min) ==="
    if [[ "${#BRUTE_RESULTS[@]}" -eq 0 ]]; then
        echo "No brute force attacks detected."
    else
        for line in "${BRUTE_RESULTS[@]}"; do
            # IFS=, só para este read: parte a linha CSV nos 6 campos
            IFS=, read -r ip first last failures users successes <<< "$line"
            echo "IP: $ip"
            echo "  First attempt: $first"
            echo "  Last attempt:  $last"
            echo "  Failures:      $failures"
            echo "  Top usernames: $users"

            if [[ -z "$successes" ]]; then
                echo "  Successful logins: none"
            else
                echo "  Successful logins:"
                # read -a: parte a lista (separada por espaços) num array, um login por elemento
                read -r -a logins <<< "$successes"
                for login in "${logins[@]}"; do
                    # login = "user@timestamp": %%@* tira de "@" até ao fim (fica o user),
                    # #*@ tira do início até "@" (fica o timestamp)
                    echo "    ${login%%@*} at ${login#*@}"
                done
            fi
        done
    fi

    local num_users existing non_existing

    echo
    echo "=== Password spray (>= $SPRAY_THRESHOLD usernames in $SPRAY_WINDOW min, <= $SPRAY_MAX_AVG attempts per username on average) ==="
    if [[ "${#SPRAY_RESULTS[@]}" -eq 0 ]]; then
        echo "No password spray attacks detected."
    else
        for line in "${SPRAY_RESULTS[@]}"; do
            IFS=, read -r ip first last num_users existing non_existing <<< "$line"
            echo "IP: $ip"
            echo "  Period:    $first -> $last"
            echo "  Usernames: $num_users"
            echo "  Existing on the server:     ${existing:-none}"
            echo "  Not existing on the server: ${non_existing:-none}"
        done
    fi

    local user time reason

    echo
    echo "=== Successful login after failures (>= $FAIL_THRESHOLD failures from the same IP or for the same user in the $SUCCESS_WINDOW min before) ==="
    if [[ "${#SUCCESS_RESULTS[@]}" -eq 0 ]]; then
        echo "No successful logins after failures detected."
    else
        for line in "${SUCCESS_RESULTS[@]}"; do
            IFS=, read -r ip user time failures reason <<< "$line"
            echo "User: $user"
            echo "  IP:              $ip"
            echo "  Time:            $time"
            echo "  Failures before: $failures"
            echo "  Detected by:     $reason"
        done
    fi
}

main() {
    parse_args "$@"
    check_pre_reqs
    read_logs
    detect_brute_force
    detect_password_spray
    detect_success_after_failures
    print_report

    echo "TODO: implement analyze_auth.sh" >&2
    exit "$EXIT_FATAL"
}

# Corre main só quando o script é executado diretamente (não quando é feito 'source' nos testes)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
