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

# Ficheiro temporário com todas as linhas dos logs, por ordem cronológica (criado em read_logs)
EVENTS_FILE=""

# Ficheiro temporário com os eventos SSH já tratados (criado em extract_ssh_events),
# um por linha, por ordem cronológica, campos separados por espaço:
#   ip epoch timestamp user type status usual
#   epoch:     timestamp em segundos desde 1970 (para as janelas)
#   timestamp: texto original ISO 8601 (para o output)
#   user:      username tentado ("<empty>" se vazio)
#   type:      fail ("Failed password") ou success ("Accepted password/publickey")
#   status:    invalid se a linha diz "for invalid user" (não existe no servidor), senão valid
#   usual:     só nos sucessos: IP do 1.º login com sucesso anterior do user ("-" se não houve)
SSH_FILE=""

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
# Secção 3.5: um array por lista, porque as três têm colunas diferentes
# TOP_IPS_RESULTS: ip,failures,successes
#   os TOP_N IPs com mais tentativas (falhas + sucessos), do maior para o menor
TOP_IPS_RESULTS=()
# TOP_USERS_RESULTS: user,failures
#   os TOP_N usernames com mais falhas (os mais atacados), do maior para o menor
TOP_USERS_RESULTS=()
# ROOT_LOGINS_RESULTS: ip,time
#   cada login com sucesso como root por SSH, por ordem cronológica
ROOT_LOGINS_RESULTS=()
# Secção 3.6
# "Contas seguidas" = as contas suspeitas da 3.4 e as contas criadas no log
# origin (em SESSION_RESULTS e SUDO_RESULTS): grupo da conta, suspicious (login da 3.4)
#   ou created (criada no log); uma conta que seja as duas coisas fica em suspicious
# SESSION_RESULTS: user,origin,ip,start,end
#   todas as sessões SSH das contas seguidas, pela ordem de abertura
#   start: timestamp do login (linha Accepted); end: timestamp do "session closed"
#   do mesmo processo sshd, ou "-" se a sessão não fechou até ao fim do log
SESSION_RESULTS=()
# SUDO_RESULTS: user,origin,time,session,command
#   todos os comandos sudo das contas seguidas, por ordem cronológica
#   session: start da sessão SSH do user aberta nesse momento (liga o comando a uma linha
#   de SESSION_RESULTS), ou "-" se o user não tinha nenhuma aberta
#   command fica em último porque pode conter vírgulas (o read põe o resto da linha nele)
SUDO_RESULTS=()
# ACCOUNT_RESULTS: time,action,account,uid,by,details
#   cada alteração de conta em todo o log (linhas useradd[...] e passwd[...]), por ordem cronológica
#   action: created (useradd "new user:") ou password (passwd "password changed for")
#   uid: UID da conta criada, "-" em password
#   by: conta seguida com uma sessão aberta nesse momento (quem fez a alteração), ou "-"
#   details: restantes campos do useradd separados por espaço (GID, home, shell, from),
#   "-" em password; fica em último pelo mesmo motivo que command no SUDO_RESULTS
ACCOUNT_RESULTS=()
# TIMELINE_RESULTS: time,description
#   um evento-chave por linha, de todas as secções, por ordem cronológica
#   description fica em último porque pode conter vírgulas (ex.: comandos sudo)
TIMELINE_RESULTS=()

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

    # Apaga os ficheiros temporários sempre que o script termina (normal, erro ou Ctrl+C).
    # As aspas simples adiam a expansão das variáveis para o momento da saída, por isso
    # SSH_FILE (criado mais tarde, em extract_ssh_events) também é apagado.
    trap 'rm -f "$EVENTS_FILE" "$SSH_FILE"' EXIT

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

# Extrai uma única vez os eventos SSH de EVENTS_FILE para SSH_FILE (formato no topo).
# Todas as detect_* leem SSH_FILE, por isso o parsing das linhas e a conversão do
# tempo estão só aqui.
extract_ssh_events() {
    SSH_FILE="$(mktemp)" || fatal "Could not create temporary file."

    # Das linhas "Failed password" e "Accepted password/publickey":
    #   IP = campo a seguir a "from" (a coluna muda com/sem "invalid user")
    #   username = campo antes de "from"
    # TZ=UTC: o mktime não depende do fuso horário da máquina
    TZ=UTC awk '
        # Converte "2026-10-30T14:05:42.527481+00:00" em segundos desde 1970 (epoch).
        # mktime espera "YYYY MM DD HH MM SS"
        function to_epoch(ts) {
            ts = substr(ts, 1, 19)       # "2026-10-30T14:05:42" (sem fração nem fuso)
            gsub(/[-T:]/, " ", ts)       # "2026 10 30 14 05 42"
            return mktime(ts)
        }

        /Failed password/ || /Accepted (password|publickey) for/ {
            type = "fail"
            if (/Accepted (password|publickey) for/)
                type = "success"
            status = "valid"
            if (/Failed password for invalid user /)
                status = "invalid"

            for (i = 1; i <= NF; i++) {
                if ($i == "from") {
                    ip = $(i+1)
                    user = $(i-1)
                    # "invalid user  from": username vazio. O awk junta os dois espaços,
                    # por isso o campo antes de "from" seria a palavra "user" da mensagem
                    if ($(i-2) == "invalid" && $(i-1) == "user")
                        user = "<empty>"

                    # IP habitual: EVENTS_FILE está por ordem cronológica, por isso
                    # o 1.º sucesso de cada user que aparece é o mais antigo
                    usual = "-"
                    if (type == "success") {
                        if (user in first_ip)
                            usual = first_ip[user]   # já houve um sucesso antes deste
                        else
                            first_ip[user] = ip      # 1.º sucesso: passa a ser o IP habitual
                    }

                    print ip, to_epoch($1), $1, user, type, status, usual
                }
            }
        }
    ' "$EVENTS_FILE" > "$SSH_FILE"
}

# Secção 3.2: deteta IPs com >= BRUTE_THRESHOLD falhas de password numa janela de BRUTE_WINDOW minutos
detect_brute_force() {
    # sort: agrupa por IP (-k1,1 = só a 1.ª coluna). -s (estável) mantém a ordem
    #   original dentro de cada IP, que já é cronológica (SSH_FILE está ordenado).
    # awk: janela deslizante sobre as falhas, um IP de cada vez; os sucessos
    #   são só guardados para o output.
    # mapfile: guarda cada linha do output do pipeline num elemento de BRUTE_RESULTS.
    #   Usa-se "< <(...)" e não "pipeline | mapfile": num pipe o mapfile correria
    #   num subshell e o array global ficaria vazio.
    mapfile -t BRUTE_RESULTS < <(LC_ALL=C sort -s -k1,1 "$SSH_FILE" \
    | awk -v n="$BRUTE_THRESHOLD" -v window="$((BRUTE_WINDOW * 60))" '
        # Devolve os "top" usernames mais tentados do IP atual, no formato "user(N) ..."
        # Procura o máximo, guarda-o e remove-o do array; repete "top" vezes
        # A ordem de "for (u in users)" depende do awk, por isso os empates são desempatados
        # pelo username (ordem alfabética), para o resultado ser igual em gawk e mawk
        function top_users(top, list, j, u, best) {
            list = ""
            for (j = 1; j <= top; j++) {
                best = ""
                for (u in users)
                    if (best == "" || users[u] > users[best] || (users[u] == users[best] && u < best))
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

        # Campos de SSH_FILE: $1 ip, $2 epoch, $3 timestamp, $4 user, $5 type
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
            if ($5 == "success") {
                if (successes != "")
                    successes = successes " "
                successes = successes $4 "@" $3
                next
            }

            users[$4]++                  # tentativas por username, só deste IP
            k++                          # número desta falha dentro do IP
            t[k] = $2                    # tempo da falha k, em segundos
            # Primeira falha do IP (texto original, para o output). Fica aqui e não
            # na mudança de IP porque o primeiro evento do IP pode ser um sucesso
            if (k == 1)
                first_ts = $3
            last_ts = $3                 # última falha vista até agora

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
    # sort: agrupa por IP mantendo a ordem cronológica (igual ao brute force).
    # awk: janela deslizante de SPRAY_WINDOW minutos sobre as falhas, um IP de cada vez.
    mapfile -t SPRAY_RESULTS < <(LC_ALL=C sort -s -k1,1 "$SSH_FILE" \
    | awk -v n="$SPRAY_THRESHOLD" -v window="$((SPRAY_WINDOW * 60))" \
          -v max_avg="$SPRAY_MAX_AVG" '
        # Fecha o IP anterior: se foi detetado, imprime-o numa linha CSV
        function report() {
            if (detected)
                print prev_ip "," first_ts "," last_ts "," n_users "," existing "," non_existing
        }

        # Campos de SSH_FILE: $1 ip, $2 epoch, $3 timestamp, $4 user, $5 type, $6 status.
        # Só as falhas interessam: o padrão $5 == "fail" ignora as linhas de sucesso
        $5 == "fail" {
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
            t[k] = $2                    # tempo da falha k, em segundos
            u[k] = $4                    # username da falha k (para saber quem sai da janela)
            if (k == 1)
                first_ts = $3
            last_ts = $3

            # Listas para o output: cada username entra uma vez, na 1.ª tentativa,
            # na lista de existentes ou de não existentes
            if (!($4 in seen)) {
                seen[$4] = 1
                n_users++
                if ($6 == "valid")
                    existing = existing (existing == "" ? "" : " ") $4
                else
                    non_existing = non_existing (non_existing == "" ? "" : " ") $4
            }

            # A falha k entra na janela: se o username ainda não estava lá, é mais um diferente
            in_window[$4]++
            if (in_window[$4] == 1)
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

# Secção 3.4: janela deslizante de SUCCESS_WINDOW minutos sobre as falhas, um grupo
#   de cada vez. $1 = coluna de SSH_FILE que define o grupo: 1 (IP) ou 4 (username).
#   O input tem de vir agrupado por essa coluna e em ordem cronológica dentro do grupo.
#   Imprime "ip,user,time,failures,reason" para cada sucesso com >= FAIL_THRESHOLD
#   falhas do mesmo grupo nos SUCCESS_WINDOW minutos antes; reason = ip ou user.
#   Typo: se o sucesso vem do IP habitual do user e as falhas na janela vindas desse
#   IP são <= TYPO_MAX, essas falhas não contam (as de outros IPs contam sempre).
success_window() {
    awk -v col="$1" -v n="$FAIL_THRESHOLD" -v window="$((SUCCESS_WINDOW * 60))" \
        -v typo_max="$TYPO_MAX" '
        BEGIN {
            reason = "ip"
            if (col == 4)
                reason = "user"
        }

        # Campos de SSH_FILE: $1 ip, $2 epoch, $3 timestamp, $4 user, $5 type, $7 usual
        {
            # Começa um grupo novo (IP ou username): reinicia a janela
            if ($col != prev_group) {
                prev_group = $col
                k = 0                    # número da última falha dentro do grupo
                left = 1                 # número da falha mais antiga ainda na janela
            }

            # Falha: só é guardada, para contar quando vier um sucesso
            if ($5 == "fail") {
                k++
                t[k] = $2
                ip[k] = $1               # IP da falha k (para o typo)
                next
            }

            # Sucesso: saem pela esquerda as falhas a mais de SUCCESS_WINDOW minutos dele.
            # while e não if: podem ter de sair várias de uma vez.
            # left <= k: não passar da última falha (a janela pode ficar vazia)
            while (left <= k && $2 - t[left] > window)
                left++

            # Falhas que ficaram na janela = da left à k
            failures = k - left + 1

            # Typo: o sucesso vem do IP habitual ($7) do user. Conta as falhas da
            # janela que vieram desse IP; se forem poucas, tira-as da contagem
            if ($1 == $7) {
                from_usual = 0
                for (j = left; j <= k; j++)
                    if (ip[j] == $1)
                        from_usual++
                if (from_usual <= typo_max)
                    failures -= from_usual
            }

            if (failures >= n)
                print $1 "," $4 "," $3 "," failures "," reason
        }
    '
}

# Secção 3.4: deteta logins com sucesso com >= FAIL_THRESHOLD falhas do mesmo IP
# ou do mesmo username nos SUCCESS_WINDOW minutos antes
detect_success_after_failures() {
    # Corre a janela duas vezes, com o input agrupado de maneiras diferentes:
    #   sort -k1,1 agrupa por IP, sort -k4,4 agrupa por username. -s (estável) mantém
    #   a ordem cronológica dentro de cada grupo (SSH_FILE já está ordenado).
    # awk de junção: o mesmo login pode ser detetado pelas duas vias. A chave
    #   "ip,user,time" identifica o login; se aparecer duas vezes fica só uma linha,
    #   com reason = both e o maior número de falhas.
    # sort final: por tempo (3.ª coluna do CSV), para o output sair em ordem cronológica.
    # mapfile: guarda cada linha CSV num elemento de SUCCESS_RESULTS ("< <(...)" pelo
    #   mesmo motivo do detect_brute_force: num pipe o array ficaria vazio).
    mapfile -t SUCCESS_RESULTS < <(
        {
            LC_ALL=C sort -s -k1,1 "$SSH_FILE" | success_window 1
            LC_ALL=C sort -s -k4,4 "$SSH_FILE" | success_window 4
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

# Secção 3.5: top TOP_N IPs (falhas e sucessos), top TOP_N usernames atacados
# e logins como root por SSH
detect_most_active() {
    # Top IPs
    # awk: conta falhas e sucessos de cada IP e imprime "ip,failures,successes,total".
    #   Aqui usam-se arrays indexados pelo IP (e não sort + um IP de cada vez), porque
    #   só é preciso contar, sem janela; a ordem do "for (ip in ...)" não importa,
    #   porque o sort a seguir é que ordena.
    # sort: -t, separa por vírgulas; -k4,4nr = total, numérico, do maior para o menor;
    #   -k1,1 = em caso de empate, pelo IP, para o resultado ser sempre o mesmo.
    # head: fica com os TOP_N primeiros. cut: tira o total (só servia para ordenar).
    mapfile -t TOP_IPS_RESULTS < <(awk '
        # Campos de SSH_FILE: $1 ip, $5 type
        {
            total[$1]++
            if ($5 == "fail")
                failures[$1]++
            else
                successes[$1]++
        }
        END {
            # "+ 0": um IP sem falhas (ou sem sucessos) imprime 0 e não vazio
            for (ip in total)
                print ip "," failures[ip] + 0 "," successes[ip] + 0 "," total[ip]
        }
    ' "$SSH_FILE" | LC_ALL=C sort -t, -k4,4nr -k1,1 | head -n "$TOP_N" | cut -d, -f1-3)

    # Top usernames atacados
    # awk: conta as falhas de cada username (atacado = tentativa falhada) e imprime
    #   "user,failures". O username vazio conta como "<empty>" (pressuposto 6).
    # sort: falhas, numérico, do maior para o menor; empate pelo username. head: TOP_N.
    mapfile -t TOP_USERS_RESULTS < <(awk '
        # Campos de SSH_FILE: $4 user, $5 type
        $5 == "fail" { failures[$4]++ }
        END {
            for (user in failures)
                print user "," failures[user]
        }
    ' "$SSH_FILE" | LC_ALL=C sort -t, -k2,2nr -k1,1 | head -n "$TOP_N")

    # Logins como root por SSH
    # awk: dos sucessos do user root imprime "ip,time". Não precisa de sort, porque
    #   SSH_FILE já está por ordem cronológica. Não leva head: mostram-se todos.
    mapfile -t ROOT_LOGINS_RESULTS < <(awk '
        # Campos de SSH_FILE: $1 ip, $3 timestamp, $4 user, $5 type
        $4 == "root" && $5 == "success" { print $1 "," $3 }
    ' "$SSH_FILE")
}

# Secção 3.6: para as contas suspeitas da 3.4 e as contas criadas no log, as suas
# sessões, comandos sudo e alterações de contas; e uma timeline dos eventos principais
#
# Um só awk percorre EVENTS_FILE (por ordem cronológica):
#   - contas seguidas: começam por ser as da 3.4; cada conta criada por useradd entra no
#     conjunto nesse momento (como o log é cronológico, as sessões de uma conta criada
#     só podem aparecer depois da criação, por isso uma passagem chega)
#   - sessões: cada "Accepted ... for <conta seguida>" abre uma sessão, chaveada pelo processo
#     sshd que escreveu a linha ($3, ex.: "sshd[35410]:"); o "session closed" do mesmo processo
#     fecha-a. Sessões que não fecham até ao fim do log ficam com end = "-"
#   - sudo: todas as linhas "sudo: <conta seguida> : ... COMMAND=..."
#   - alterações de contas: todas as linhas useradd[...] e passwd[...] do log, escolhidas pelo
#     3.º campo (o processo), para não apanhar as linhas do sudo, cujo 3.º campo é "sudo:"
#     mesmo quando o comando é useradd ou passwd. São atribuídas (coluna by) à conta seguida
#     que tem uma sessão aberta nesse momento (a aberta mais recentemente, se houver várias),
#     ou "-" se não houver nenhuma.
# Usa as linhas do próprio useradd/passwd e não as do sudo, porque confirmam que a alteração
# aconteceu, e também apanham alterações feitas sem sudo (ex.: por uma conta com UID 0).
# O awk escreve três tipos de linha, com o tipo na 1.ª coluna:
#   "session,user,origin,ip,start,end", "sudo,user,origin,time,session,command" e "account,time,action,account,uid,by,details"
detect_what_happened() {
    local line user
    local users=""
    local results=()

    # Users da 3.4, separados por espaço (os repetidos não fazem mal: o awk usa-os como chave)
    for line in "${SUCCESS_RESULTS[@]}"; do
        IFS=, read -r _ user _ <<< "$line"
        users+="$user "
    done

    mapfile -t results < <(
        awk -v users="$users" '
            # Conta seguida com sessão aberta neste momento (a aberta mais recentemente),
            # ou "-". As sessões são numeradas pela ordem de abertura, por isso é a de maior número.
            function owner(   pid, best) {
                best = 0
                for (pid in open_session)
                    if (open_session[pid] > best) best = open_session[pid]
                return best ? s_user[best] : "-"
            }
            # Início da sessão aberta deste user (a aberta mais recentemente), ou "-"
            function session_of(user,   pid, best) {
                best = 0
                for (pid in open_session)
                    if (s_user[open_session[pid]] == user && open_session[pid] > best)
                        best = open_session[pid]
                return best ? s_start[best] : "-"
            }
            BEGIN {
                n = split(users, list, " ")
                # tracked[conta] = grupo da conta (origin): suspicious (3.4) ou created
                for (i = 1; i <= n; i++) tracked[list[i]] = "suspicious"
            }
            # Conta criada: "... useradd[35590]: new user: name=sysupdate, UID=0, GID=0, home=/root, shell=/bin/bash, from=/dev/pts/2"
            $3 ~ /^useradd\[/ && index($0, "new user:") {
                name = "-"; uid = "-"; details = ""
                for (i = 6; i <= NF; i++) {
                    value = $i
                    sub(/,$/, "", value)              # tira a vírgula do fim
                    if (value ~ /^name=/)
                        name = substr(value, 6)       # depois de "name=" (5 caracteres)
                    else if (value ~ /^UID=/)
                        uid = substr(value, 5)        # depois de "UID=" (4 caracteres)
                    else
                        details = details (details == "" ? "" : " ") value
                }
                if (details == "") details = "-"
                print "account," $1 ",created," name "," uid "," owner() "," details
                # a conta criada passa a ser seguida (se já era suspeita da 3.4, fica nesse grupo)
                if (!(name in tracked)) tracked[name] = "created"
                next
            }
            # Password alterada: "... passwd[35600]: pam_unix(passwd:chauthtok): password changed for sysupdate"
            $3 ~ /^passwd\[/ && index($0, "password changed for") {
                print "account," $1 ",password," $NF ",-," owner() ",-"
                next
            }
            # Início de sessão: "... sshd[35410]: Accepted password for rfaria from 192.0.2.77 port 36513 ssh2"
            # (user = campo antes de "from", IP = campo depois)
            $3 ~ /^sshd\[/ && $4 == "Accepted" {
                for (i = 5; i < NF; i++)
                    if ($i == "from") break
                if ($(i - 1) in tracked) {
                    n_sessions++
                    s_user[n_sessions]  = $(i - 1)
                    s_origin[n_sessions] = tracked[$(i - 1)]
                    s_ip[n_sessions]    = $(i + 1)
                    s_start[n_sessions] = $1
                    s_end[n_sessions]   = "-"
                    open_session[$3] = n_sessions
                }
                next
            }
            # Fim de sessão: "session closed" escrito pelo mesmo processo sshd
            ($3 in open_session) && index($0, "session closed") {
                s_end[open_session[$3]] = $1
                delete open_session[$3]
                next
            }
            # Comando sudo de uma conta seguida: "... sudo: rfaria : TTY=pts/2 ; ... COMMAND=/usr/bin/cat /etc/shadow"
            $3 == "sudo:" && ($4 in tracked) && index($0, "COMMAND=") {
                # tudo o que vem depois de "COMMAND=" (8 caracteres)
                print "sudo," $4 "," tracked[$4] "," $1 "," session_of($4) "," substr($0, index($0, "COMMAND=") + 8)
            }
            # As sessões são escritas no fim, pela ordem de abertura
            END {
                for (k = 1; k <= n_sessions; k++)
                    print "session," s_user[k] "," s_origin[k] "," s_ip[k] "," s_start[k] "," s_end[k]
            }
        ' "$EVENTS_FILE"
    )

    # Separa as linhas pelo tipo: ${line%%,*} = 1.ª coluna, ${line#*,} = o resto
    for line in "${results[@]}"; do
        case "${line%%,*}" in
            session) SESSION_RESULTS+=("${line#*,}") ;;
            sudo)    SUDO_RESULTS+=("${line#*,}") ;;
            account) ACCOUNT_RESULTS+=("${line#*,}") ;;
        esac
    done
}

# Timeline (3.6): um evento-chave por linha, para todo o período do log, por ordem cronológica.
# Não lê os logs: junta eventos dos arrays de resultados das secções anteriores, para a timeline
# ser coerente com elas. Atividade que parece legítima fica de fora:
#   - das contas suspeitas da 3.4, só a sessão aberta pelo login detetado e os sudo corridos
#     nela (as sessões normais da conta, ex.: rfaria a partir de 10.20.3.14, não entram)
#   - os logins root da 3.5 não entram
# As contas criadas no log entram sempre, com todas as sessões e sudo.
build_timeline() {
    local line ip first last failures users successes login num_users user time
    local failures_before origin start end session command action account uid by desc
    local logins=()
    local events=()
    # Logins da 3.4, chave "user@time": a sessão e os sudo de uma conta suspeita só entram
    # se a sessão começou num destes logins (o start da sessão é o time do login)
    local -A suspicious_login=()

    # Início do período: 1.ª linha de EVENTS_FILE (já ordenado); ${line%% *} = 1.º campo
    line=$(head -n 1 "$EVENTS_FILE")
    events+=("${line%% *},Start of the analysed logs")

    # Brute force (3.2): início, fim e logins com sucesso do IP
    for line in "${BRUTE_RESULTS[@]}"; do
        IFS=, read -r ip first last failures users successes <<< "$line"
        events+=("$first,Brute force from $ip started")
        events+=("$last,Brute force from $ip ended ($failures failed passwords; top usernames: $users)")
        read -r -a logins <<< "$successes"
        for login in "${logins[@]}"; do
            events+=("${login#*@},Successful login as ${login%%@*} from brute force source $ip")
        done
    done

    # Password spray (3.3): início e fim
    for line in "${SPRAY_RESULTS[@]}"; do
        IFS=, read -r ip first last num_users _ <<< "$line"
        events+=("$first,Password spray from $ip started")
        events+=("$last,Password spray from $ip ended ($num_users usernames tried)")
    done

    # Logins suspeitos (3.4)
    for line in "${SUCCESS_RESULTS[@]}"; do
        IFS=, read -r ip user time failures_before _ <<< "$line"
        suspicious_login["$user@$time"]=1
        events+=("$time,Suspicious login: $user from $ip after $failures_before failed attempts")
    done

    # Sessões (3.6). O início da sessão de uma conta suspeita já é a linha do login da 3.4,
    # por isso só se acrescenta o fim; nas contas criadas acrescentam-se os dois
    for line in "${SESSION_RESULTS[@]}"; do
        IFS=, read -r user origin ip start end <<< "$line"
        if [[ "$origin" == "created" ]]; then
            events+=("$start,Login as $user from $ip (account created in the log)")
        elif [[ -z "${suspicious_login["$user@$start"]:-}" ]]; then
            continue                                  # sessão normal da conta suspeita
        fi
        if [[ "$end" != "-" ]]; then
            events+=("$end,Session of $user from $ip closed")
        fi
    done

    # Comandos sudo (3.6): os das contas criadas e os corridos na sessão suspeita
    for line in "${SUDO_RESULTS[@]}"; do
        IFS=, read -r user origin time session command <<< "$line"
        if [[ "$origin" == "created" || -n "${suspicious_login["$user@$session"]:-}" ]]; then
            events+=("$time,sudo by $user: $command")
        fi
    done

    # Alterações de contas (3.6)
    for line in "${ACCOUNT_RESULTS[@]}"; do
        IFS=, read -r time action account uid by _ <<< "$line"
        if [[ "$by" == "-" ]]; then
            by="unknown"
        fi
        if [[ "$action" == "created" ]]; then
            desc="Account created: $account (UID=$uid) by $by"
            if [[ "$uid" == "0" && "$account" != "root" ]]; then
                desc+=" - WARNING: UID 0 gives root privileges"
            fi
        else
            desc="Password changed: $account by $by"
        fi
        events+=("$time,$desc")
    done

    # Fim do período: última linha de EVENTS_FILE (acrescentado em último para, com o
    # mesmo timestamp de outro evento, ficar depois dele)
    line=$(tail -n 1 "$EVENTS_FILE")
    events+=("${line%% *},End of the analysed logs")

    # Ordena pelo timestamp (1.ª coluna). Os timestamps ISO estão todos em +00:00, por isso a
    # ordem alfabética (LC_ALL=C) é a cronológica; -s mantém a ordem de inserção nos empates
    mapfile -t TIMELINE_RESULTS < <(printf '%s\n' "${events[@]}" | LC_ALL=C sort -s -t, -k1,1)
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

    local successes

    # Tops em tabela: printf com larguras fixas alinha as colunas
    # (%-15s = texto à esquerda em 15 caracteres, %8s = à direita em 8, bom para números)
    echo
    echo "=== Top $TOP_N IPs (failed + successful logins) ==="
    if [[ "${#TOP_IPS_RESULTS[@]}" -eq 0 ]]; then
        echo "No SSH login attempts found."
    else
        printf "%-15s %8s %10s\n" "IP" "Failed" "Successful"
        for line in "${TOP_IPS_RESULTS[@]}"; do
            IFS=, read -r ip failures successes <<< "$line"
            printf "%-15s %8s %10s\n" "$ip" "$failures" "$successes"
        done
    fi

    echo
    echo "=== Top $TOP_N attacked usernames (failed logins) ==="
    if [[ "${#TOP_USERS_RESULTS[@]}" -eq 0 ]]; then
        echo "No failed logins found."
    else
        printf "%-20s %8s\n" "Username" "Failed"
        for line in "${TOP_USERS_RESULTS[@]}"; do
            IFS=, read -r user failures <<< "$line"
            printf "%-20s %8s\n" "$user" "$failures"
        done
    fi

    echo
    echo "=== Logins as root over SSH ==="
    if [[ "${#ROOT_LOGINS_RESULTS[@]}" -eq 0 ]]; then
        echo "No root logins over SSH."
    else
        for line in "${ROOT_LOGINS_RESULTS[@]}"; do
            IFS=, read -r ip time <<< "$line"
            echo "$time from $ip"
        done
    fi

    local start end command origin group title found

    # As contas seguidas são de dois grupos (coluna origin): suspicious (login da 3.4)
    # e created (criadas no log). Cada grupo tem as suas secções de sessões e de sudo.
    for group in suspicious created; do
        if [[ "$group" == "suspicious" ]]; then
            title="suspicious accounts (successful login after failures)"
        else
            title="accounts created in the log"
        fi

        echo
        echo "=== Sessions of $title ==="
        found=0
        for line in "${SESSION_RESULTS[@]}"; do
            IFS=, read -r user origin ip start end <<< "$line"
            if [[ "$origin" == "$group" ]]; then
                echo "$start -> $end $user from $ip"
                found=1
            fi
        done
        if [[ "$found" -eq 0 ]]; then
            echo "No sessions of $title."
        fi

        echo
        echo "=== Sudo commands of $title ==="
        found=0
        for line in "${SUDO_RESULTS[@]}"; do
            # command é a última variável: fica com o resto da linha, mesmo com vírgulas
            IFS=, read -r user origin time _ command <<< "$line"
            if [[ "$origin" == "$group" ]]; then
                echo "$time $user: $command"
                found=1
            fi
        done
        if [[ "$found" -eq 0 ]]; then
            echo "No sudo commands of $title."
        fi
    done

    local action account uid by details

    echo
    echo "=== Account changes (useradd / passwd) ==="
    if [[ "${#ACCOUNT_RESULTS[@]}" -eq 0 ]]; then
        echo "No account changes detected."
    else
        for line in "${ACCOUNT_RESULTS[@]}"; do
            IFS=, read -r time action account uid by details <<< "$line"
            # by = "-": nenhuma conta seguida tinha sessão aberta
            if [[ "$by" == "-" ]]; then
                by="unknown"
            fi
            case "$action" in
                created)
                    echo "$time account created: $account (UID=$uid $details) by $by"
                    # UID 0 numa conta que não é root = outra conta com privilégios de root
                    if [[ "$uid" == "0" && "$account" != "root" ]]; then
                        echo "  WARNING: UID 0 gives $account root privileges"
                    fi
                    ;;
                password)
                    echo "$time password changed: $account by $by"
                    ;;
            esac
        done
    fi

    local desc

    echo
    echo "=== Timeline (key events, whole period) ==="
    for line in "${TIMELINE_RESULTS[@]}"; do
        # desc é a última variável: fica com o resto da linha, mesmo com vírgulas
        IFS=, read -r time desc <<< "$line"
        echo "$time $desc"
    done
}

main() {
    parse_args "$@"
    check_pre_reqs
    read_logs
    extract_ssh_events
    detect_brute_force
    detect_password_spray
    detect_success_after_failures
    detect_most_active
    detect_what_happened
    build_timeline
    print_report

    exit "$EXIT_OK"
}

# Corre main só quando o script é executado diretamente (não quando é feito 'source' nos testes)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
