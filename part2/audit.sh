#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: audit.sh [-h] --policy FILE [--full] [--state-dir DIR] [--report-dir DIR]

Daily security audit for srv-files01. Reports NEW and RESOLVED findings
compared to the previous run.

Options:
  --policy FILE       Path to access-policy.csv (required)
  --full              Print every current finding without using or changing state
  --state-dir DIR     Directory for audit state (default: /var/lib/audit)
  --report-dir DIR    Directory for daily reports (default: /var/log/audit)
  -h, --help          Show this help message and exit

Exit codes:
  0  No new findings
  1  Error
  2  New findings detected
EOF
}

check_uid_zero_accounts() {
    getent passwd | awk -F: '
        $3 == 0 && $1 != "root" {
            printf "[UID0] %s: UID 0\n", $1
        }
    '
}

check_sudo_membership() {
    local username groups

    getent passwd | cut -d: -f1 | while IFS= read -r username; do
        groups=$(id -nG -- "$username") || return 1

        if [[ " $groups " == *" sudo "* && " $groups " != *" it "* ]]; then
            printf '[SUDO] %s: pertence a sudo e não pertence a it\n' "$username"
        fi
    done
}

check_empty_passwords() {
    awk -F: '
        NF == 9 && $2 == "" {
            printf "[EMPTY_PASSWORD] %s: campo de palavra-passe vazio\n", $1
        }
    '
}

check_expirations() {
    local today=$1

    awk -F: -v today="$today" '
        NF != 9 { next }

        {
            user = $1
            password = $2
            last_change = $3
            max_age = $5
            account_expiry = $8

            if (password != "" && password !~ /^[!*]/) {
                if (last_change == "0") {
                    printf "[PWDEXP] %s: alteração obrigatória no próximo login\n", user
                } else if (last_change ~ /^[0-9]+$/ && max_age ~ /^[0-9]+$/) {
                    days_left = last_change + max_age - today

                    if (days_left < 0) {
                        printf "[PWDEXP] %s: palavra-passe expirou há %d dia(s)\n", user, -days_left
                    } else if (days_left <= 7) {
                        printf "[PWDEXP] %s: palavra-passe expira em %d dia(s)\n", user, days_left
                    }
                }
            }

            if (account_expiry ~ /^[0-9]+$/ && account_expiry > 0) {
                days_left = account_expiry - today

                if (days_left >= 0 && days_left <= 7) {
                    printf "[ACCTEXP] %s: conta expira em %d dia(s)\n", user, days_left
                }
            }
        }
    '
}

check_world_writable() {
    local search_root=$1

    find -P "$search_root" \
        \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \
        -perm -0002 \
        \( -type f -o \( -type d ! -perm -1000 \) \) \
        -printf '[WORLDW] %p: escrita permitida a outros\n'
}

policy_owner_groups() {
    local policy_file=$1

    awk -F, '
        {
            sub(/\r$/, "")
            for (i = 1; i <= NF; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            }
            if ($1 != "/") sub(/\/$/, "", $1)
        }

        $3 == "rwx" && !seen[$1] {
            print $1 "\t" $2
            seen[$1] = 1
        }
    ' "$policy_file"
}

policy_group_acls() {
    local policy_file=$1 folder=$2

    awk -F, -v folder="$folder" '
        {
            for (i = 1; i <= NF; i++) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
            }
            if ($1 != "/") sub(/\/$/, "", $1)
        }

        $1 == folder {
            direct[$2] = $3
        }

        $1 != folder && index($1, folder == "/" ? "/" : folder "/") == 1 {
            descendant[$2] = 1
        }

        END {
            for (group in direct) {
                print "group:" group ":" direct[group]
                print "default:group:" group ":" direct[group]
            }
            for (group in descendant) {
                if (!(group in direct)) {
                    print "group:" group ":--x"
                }
            }
        }
    ' "$policy_file"
}

check_policy_directory() {
    local folder=$1 expected_group=$2
    local metadata owner_uid actual_group mode

    if [[ -L "$folder" || ! -d "$folder" ]]; then
        printf '[POLICY] %s: pasta ausente ou de tipo incorreto\n' "$folder"
        return 0
    fi

    metadata=$(stat -c '%u:%G:%a' -- "$folder") || return 1
    IFS=: read -r owner_uid actual_group mode <<< "$metadata"

    if [[ "$owner_uid" != 0 ]]; then
        printf '[POLICY] %s: proprietário com UID %s (esperado: 0)\n' \
            "$folder" "$owner_uid"
    fi

    if [[ "$actual_group" != "$expected_group" ]]; then
        printf '[POLICY] %s: grupo %s (esperado: %s)\n' \
            "$folder" "$actual_group" "$expected_group"
    fi

    if (( (8#$mode & 0007) != 0 )); then
        printf '[POLICY] %s: permissões concedidas a others (modo %s)\n' \
            "$folder" "$mode"
    fi

    if (( (8#$mode & 02000) == 0 )); then
        printf '[POLICY] %s: falta o bit setgid\n' "$folder"
    fi
}

check_policy_files() {
    local policy_file=$1 folder=$2
    local rules folders child child_group file owner_group
    local -a prune=()

    # Só as regras diretas da pasta autorizam acesso aos seus ficheiros.
    # Uma ACL de travessia na pasta-pai não autoriza a leitura de ficheiros.
    rules=$(policy_group_acls "$policy_file" "$folder") || return 1
    folders=$(policy_owner_groups "$policy_file") || return 1

    # Cada subpasta com política própria será auditada na sua vez.
    while IFS=$'\t' read -r child child_group; do
        if [[ "$child" == "${folder%/}/"* && "$child" != "$folder" &&
              -d "$child" && ! -L "$child" ]]; then
            prune+=( -type d -samefile "$child" -prune -o )
        fi
    done <<< "$folders"

    find -P "$folder" "${prune[@]}" -type f -print0 |
        while IFS= read -r -d '' file; do
            owner_group=$(stat -c '%G' -- "$file") || return 1

            # -e mostra as permissões efetivas depois de aplicada a máscara.
            LC_ALL=C getfacl -cpe -- "$file" |
                awk -v file="$file" -v owner_group="$owner_group" -v rules="$rules" '
                    BEGIN {
                        n = split(rules, lines, "\n")
                        for (i = 1; i <= n; i++) {
                            split(lines[i], entry, ":")
                            if (entry[1] == "default" && entry[2] == "group")
                                allowed[entry[3]] = entry[4]
                        }
                    }

                    /^(other|group):/ {
                        split($1, entry, ":")
                        perm = entry[3]
                        if ($NF ~ /^#effective:/)
                            perm = substr($NF, length("#effective:") + 1)

                        if (perm == "---") next

                        if (entry[1] == "other") {
                            printf "[POLICY] %s: acesso de others (%s)\n", file, perm
                            next
                        }

                        group = (entry[2] == "" ? owner_group : entry[2])
                        if (!(group in allowed)) {
                            printf "[POLICY] %s: acesso de grupo não autorizado (%s)\n", file, group
                        } else if (perm ~ /w/ && allowed[group] !~ /w/) {
                            printf "[POLICY] %s: escrita de grupo não autorizada (%s)\n", file, group
                        }
                    }
                ' || return 1
        done
}

check_policy_directories() {
    local policy_file=$1
    local folder expected_group

    policy_owner_groups "$policy_file" |
        while IFS=$'\t' read -r folder expected_group; do
            check_policy_directory "$folder" "$expected_group" || return 1

            if [[ -d "$folder" && ! -L "$folder" ]]; then
                check_policy_group_acls "$policy_file" "$folder" || return 1
                check_policy_files "$policy_file" "$folder" || return 1
            fi

        done
}

check_acl_entry() {
    local folder=$1 entry=$2 expected=$3

    awk -v folder="$folder" -v entry="$entry" -v expected="$expected" '
        BEGIN {
            prefix = entry ":"
            actual = "ausente"
        }
        index($0, prefix) == 1 {
            actual = substr($0, length(prefix) + 1)
        }
        END {
            if (actual != expected) {
                printf "[POLICY] %s: %s = %s (esperado: %s)\n",
                       folder, entry, actual, expected
            }
        }
    '
}

check_policy_group_acls() {
    local policy_file=$1 folder=$2
    local expected actual line entry permission
    local -A allowed=()

    expected=$(policy_group_acls "$policy_file" "$folder") || return 1
    actual=$(getfacl -cpE -- "$folder") || return 1
        check_acl_entry "$folder" "mask:" "rwx" <<< "$actual" || return 1
        check_acl_entry "$folder" "default:mask:" "rwx" <<< "$actual" || return 1
        check_acl_entry "$folder" "default:other:" "---" <<< "$actual" || return 1
        check_acl_entry "$folder" "user:" "rwx" <<< "$actual" || return 1
        check_acl_entry "$folder" "group:" "rwx" <<< "$actual" || return 1
        check_acl_entry "$folder" "default:user:" "rwx" <<< "$actual" || return 1
        check_acl_entry "$folder" "default:group:" "rwx" <<< "$actual" || return 1

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        entry=${line%:*}
        permission=${line##*:}
        allowed["$entry"]=1
        check_acl_entry "$folder" "$entry" "$permission" <<< "$actual" || return 1
    done <<< "$expected"

    while IFS= read -r line; do
        if [[ "$line" =~ ^(default:)?user:[^:]+:[r-]w[x-]$ ]]; then
            printf '[POLICY] %s: escrita em ACL individual: %s\n' \
                "$folder" "$line"
        fi

        if [[ "$line" =~ ^(default:)?group:[^:]+:[rwx-]{3}$ ]]; then
            entry=${line%:*}
            if [[ -z ${allowed["$entry"]+x} ]]; then
                printf '[POLICY] %s: entrada de grupo não prevista: %s\n' \
                    "$folder" "$line"
            fi
        fi
    done <<< "$actual"
}

compare_findings() {
    local previous=$1 current=$2

    awk '
        function finding_key(line, key) {
            key = line

            # A contagem de dias muda diariamente para a mesma conta.
            if (line ~ /^\[(PWDEXP|ACCTEXP)\] /)
                sub(/: .*/, "", key)

            return key
        }

        FILENAME == ARGV[1] {
            if ($0 == "") next
            key = finding_key($0)
            if (!(key in old))
                old_order[++old_count] = key
            old[key] = $0
            next
        }

        {
            if ($0 == "") next
            key = finding_key($0)
            if (!(key in seen) && !(key in old)) {
                print "NEW " $0
                changed = 1
            }
            seen[key] = 1
        }

        END {
            for (i = 1; i <= old_count; i++) {
                key = old_order[i]
                if (!(key in seen)) {
                    print "RESOLVED " old[key]
                    changed = 1
                }
            }

            if (!changed)
                print "Sem alterações."
        }
    ' "$previous" "$current"
}

save_audit_state() (
    local state_file=$1 current=$2 staged checksum

    umask 077
    staged=$(mktemp -- "${state_file}.tmp.XXXXXXXX") || return 1
    trap 'rm -f -- "$staged"' EXIT

    checksum=$(sha256sum < "$current") || return 1
    printf 'audit-v1 %s\n' "${checksum%% *}" > "$staged" || return 1
    cat -- "$current" >> "$staged" || return 1
    mv -fT -- "$staged" "$state_file" || return 1
)

load_audit_state() {
    local state_file=$1 previous=$2 header checksum
    local status_file=${3:-}

    # A comparação usa um histórico vazio quando ainda não existe estado.
    : > "$previous" || return 1
    if [[ -n "$status_file" ]]; then printf 'first\n' > "$status_file" || return 1; fi

    if [[ ! -e "$state_file" && ! -L "$state_file" ]]; then
        return 0
    fi

    if [[ -L "$state_file" || ! -f "$state_file" || ! -r "$state_file" ]]; then
        printf 'Erro ao abrir o estado: %s\n' "$state_file" >&2
        return 1
    fi

    {
        header=''
        if IFS= read -r header &&
           [[ "$header" =~ ^audit-v1\ [0-9a-f]{64}$ ]]; then
            cat > "$previous" || return 1
            checksum=$(sha256sum < "$previous") || return 1
            if [[ "${checksum%% *}" == "${header#audit-v1 }" ]]; then

                    if [[ -n "$status_file" ]]; then printf 'valid\n' > "$status_file" || return 1; fi

                return 0
            fi
        fi
    } < "$state_file" || return 1

    printf 'Aviso: estado inválido em %s; histórico reiniciado.\n' \
        "$state_file" >&2
    : > "$previous" || return 1
}

collect_findings() {
    local policy=$1 today
    today=$(date -u +%s) || return 1
    today=$((today / 86400))

    check_uid_zero_accounts || return 1
    check_sudo_membership || return 1
    check_empty_passwords < /etc/shadow || return 1
    check_expirations "$today" < /etc/shadow || return 1
    check_world_writable / || return 1
    check_policy_directories "$policy" || return 1
}

run_audit() (
    local policy='' full=0 state_dir=/var/lib/audit report_dir=/var/log/audit
    local work report day status rc=0

    export PATH=/usr/sbin:/usr/bin:/sbin:/bin
    umask 077

    while (($#)); do
        case "$1" in
            -h|--help) usage; return 0 ;;
            --full) full=1; shift ;;
            --policy|--state-dir|--report-dir)
                if (($# < 2)) || [[ -z "$2" || "$2" == --* ]]; then
                    printf 'Erro: falta o valor de %s\n' "$1" >&2
                    return 1
                fi
                case "$1" in
                    --policy) policy=$2 ;;
                    --state-dir) state_dir=$2 ;;
                    --report-dir) report_dir=$2 ;;
                esac
                shift 2
                ;;
            *) printf 'Erro: argumento desconhecido: %s\n' "$1" >&2; return 1 ;;
        esac
    done

    if (( EUID != 0 )); then
        echo 'Erro: executa a auditoria como root.' >&2
        return 1
    fi
    if [[ ! -f "$policy" || ! -r "$policy" ]]; then
        echo 'Erro: indica um ficheiro legível com --policy.' >&2
        return 1
    fi
    if ! awk 'NR == 1 { sub(/\r$/, ""); valid = ($0 == "folder,group,access") }
             END { exit !valid }' "$policy"; then
        echo 'Erro: cabeçalho inválido na política.' >&2
        return 1
    fi

    # O mesmo bloqueio protege o modo normal e --full.
    exec 9>>/run/prcse-audit.lock || return 1
    if ! flock -n 9; then
        echo 'Erro: já existe uma auditoria em execução.' >&2
        return 1
    fi

    work=$(mktemp -d) || return 1
    trap 'rm -rf -- "$work"' EXIT

    # Uma falha na recolha não deve substituir o último estado válido.
    collect_findings "$policy" > "$work/current" || return 1

    if (( full )); then
        cat -- "$work/current" || return 1
        return 0
    fi

    mkdir -p -- "$state_dir" "$report_dir" || return 1
    load_audit_state "$state_dir/state" "$work/previous" "$work/status" || return 1
    compare_findings "$work/previous" "$work/current" > "$work/delta" || return 1

    day=$(date +%F) || return 1
    status=$(< "$work/status")
    report=$(mktemp -- "$report_dir/.audit.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"; rm -f -- "$report"' EXIT

    if [[ "$status" == first ]]; then
        if [[ -s "$work/current" ]]; then
            echo 'Primeira execução com este histórico.' > "$report" || return 1
        else
            echo 'Primeira execução com este histórico. Sem ocorrências.' > "$report" || return 1
        fi
    fi

    if [[ "$status" != first || -s "$work/current" ]]; then
        cat -- "$work/delta" >> "$report" || return 1
    fi

    if grep -q '^NEW ' "$work/delta"; then
        rc=2
    fi

    mv -fT -- "$report" "$report_dir/$day.txt" || return 1
    save_audit_state "$state_dir/state" "$work/current" || return 1
    return "$rc"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # O cron descarta stderr. Enviar os erros também para o log do sistema.
    run_audit "$@" 2> >(tee /dev/stderr | logger -t prcse-audit)
fi
