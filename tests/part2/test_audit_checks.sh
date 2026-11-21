#!/usr/bin/env bash
# Ubuntu, Bash e pacote acl. Executar com a conta normal da VM.
set -euo pipefail
export LC_ALL=C
audit=${1:-"$(dirname -- "$0")/../../part2/audit.sh"}
source "$audit"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
passed=0
expect() {
    local name=$1 expected=$2
    shift 2
    "$@" > "$tmp/actual"
    if ! diff -u <(printf '%s' "$expected") "$tmp/actual"; then
        printf 'FALHOU: %s\n' "$name" >&2
        exit 1
    fi
    passed=$((passed + 1))
    printf 'OK: %s\n' "$name"
}

# Dados sintéticos para testar a lógica sem modificar contas da VM.
(
    getent() { printf '%s\n' 'root:x:0:0::/:/bin/bash' 'teste:x:1000:1000::/:/bin/bash'; }
    expect 'root legítimo' '' check_uid_zero_accounts
    getent() { printf '%s\n' 'root:x:0:0::/:/bin/bash' 'duplicado:x:0:0::/:/bin/bash'; }
    expect 'outro UID zero' $'[UID0] duplicado: UID 0\n' check_uid_zero_accounts
    getent() { printf '%s\n' 'permitido:x:1:1::/:/bin/bash' 'fora:x:2:2::/:/bin/bash'; }
    id() {
        case "${!#}" in
            permitido) echo 'sudo it';;
            fora) echo 'sudo audit';;
        esac
    }
    expect 'sudo com e sem it' $'[SUDO] fora: pertence a sudo e não pertence a it\n' check_sudo_membership
)

expect 'palavra-passe vazia e contas bloqueadas' $'[EMPTY_PASSWORD] vazia: campo de palavra-passe vazio\n' check_empty_passwords <<'DATA'
vazia::20000:0:99999:7:::
bloqueada:!:20000:0:99999:7:::
sistema:*:20000:0:99999:7:::
DATA

expect 'expirações e limite de sete dias' $'[PWDEXP] ontem: palavra-passe expirou há 1 dia(s)\n[PWDEXP] hoje: palavra-passe expira em 0 dia(s)\n[PWDEXP] sete: palavra-passe expira em 7 dia(s)\n[ACCTEXP] conta: conta expira em 7 dia(s)\n' check_expirations 20000 <<'DATA'
ontem:demo:19989:0:10:7:::
hoje:demo:19990:0:10:7:::
sete:demo:19997:0:10:7:::
oito:demo:19998:0:10:7:::
conta:!:19990:::::20007:
depois:!:19990:::::20008:
antes:!:19990:::::19999:
sem_expiracao:demo:19990::::::
DATA

tree="$tmp/tree"
mkdir -p "$tree/aberta" "$tree/sticky"
touch "$tree/sticky/aberto" "$tree/normal"
chmod 0777 "$tree/aberta"
chmod 1777 "$tree/sticky"
chmod 0666 "$tree/sticky/aberto"
chmod 0644 "$tree/normal"
ln -s "$tree/sticky/aberto" "$tree/link"
world_sorted() { check_world_writable "$tree" | sort; }
expect 'escrita pública, sticky bit e ligação simbólica' "[WORLDW] $tree/aberta: escrita permitida a outros
[WORLDW] $tree/sticky/aberto: escrita permitida a outros
" world_sorted

folder="$tmp/equipa"
policy="$tmp/politica.csv"
group=$(id -gn)
[[ $group != adm ]] || { echo 'Este cenário usa adm como segundo grupo.' >&2; exit 1; }
printf 'folder,group,access\n%s,adm,r-x\n%s,%s,rwx\n' "$folder" "$folder" "$group" > "$policy"
expect 'primeiro grupo com rwx' "$folder"$'\t'"$group"$'\n' policy_owner_groups "$policy"
expect 'pasta ausente' "[POLICY] $folder: pasta ausente ou de tipo incorreto"$'\n' check_policy_directories "$policy"

mkdir -p "$folder/arquivo"
chmod 0700 "$folder"
printf 'folder,group,access\n%s,%s,rwx\n%s,adm,r-x\n' "$folder" "$group" "$folder/arquivo" > "$policy"
setfacl -m "g::rwx,d:g::rwx,g:$group:rwx,d:g:$group:rwx,g:adm:--x" "$folder"
expect 'travessia legítima' '' check_policy_group_acls "$policy" "$folder"
setfacl -m g:adm:r-x "$folder"
expect 'leitura excessiva' "[POLICY] $folder: group:adm = r-x (esperado: --x)"$'\n' check_policy_group_acls "$policy" "$folder"
setfacl -m g:adm:--x,d:g:adm:--x "$folder"
expect 'ACL por omissão indevida' "[POLICY] $folder: entrada de grupo não prevista: default:group:adm:--x"$'\n' check_policy_group_acls "$policy" "$folder"
setfacl -x d:g:adm "$folder"
expect 'ACL corrigida' '' check_policy_group_acls "$policy" "$folder"

# A máscara de acesso retira a escrita efetiva na pasta atual.
setfacl -n -m m::r-x "$folder"
expect 'máscara de acesso restritiva' \
    "[POLICY] $folder: mask: = r-x (esperado: rwx)"$'\n' \
    check_policy_group_acls "$policy" "$folder"

# Repor a máscara de acesso e restringir apenas a máscara por omissão.
setfacl -n -m m::rwx,d:m::r-x "$folder"
expect 'máscara por omissão restritiva' \
    "[POLICY] $folder: default:mask: = r-x (esperado: rwx)"$'\n' \
    check_policy_group_acls "$policy" "$folder"

# Com as duas máscaras repostas, a verificação deve ficar sem alertas.
setfacl -n -m d:m::rwx "$folder"
expect 'ambas as máscaras corretas' '' \
    check_policy_group_acls "$policy" "$folder"

# Testar a deteção de leitura e travessia por omissão para others.
setfacl -n -m d:o::r-x "$folder"
expect 'others com acesso por omissão' \
    "[POLICY] $folder: default:other: = r-x (esperado: ---)"$'\n' \
    check_policy_group_acls "$policy" "$folder"

# Confirmar que o alerta desaparece depois da correção.
setfacl -n -m d:o::--- "$folder"
expect 'others sem acesso por omissão' '' \
    check_policy_group_acls "$policy" "$folder"

# Alterar apenas a entrada por omissão do grupo proprietário.
setfacl -n -m d:g::r-x "$folder"
expect 'grupo proprietário com herança restritiva' \
    "[POLICY] $folder: default:group: = r-x (esperado: rwx)"$'\n' \
    check_policy_group_acls "$policy" "$folder"

# Repor a entrada e confirmar que o alerta desaparece.
setfacl -n -m d:g::rwx "$folder"
expect 'herança do grupo proprietário corrigida' '' \
    check_policy_group_acls "$policy" "$folder"

# Teste de integração: percorrer o CSV e detetar um desvio na ACL da pasta.
integration_folder="$tmp/integracao"
integration_policy="$tmp/integracao.csv"

mkdir "$integration_folder"
chmod 2770 "$integration_folder"
integration_group=$(stat -c '%G' "$integration_folder")

printf 'folder,group,access\n%s,%s,rwx\n' \
    "$integration_folder" "$integration_group" > "$integration_policy"

setfacl -m "g:$integration_group:rwx,d:g:$integration_group:rwx" "$integration_folder"
setfacl -n -m d:o::r-x "$integration_folder"

expected_owner=''
if (( EUID != 0 )); then
    expected_owner="[POLICY] $integration_folder: proprietário com UID $EUID (esperado: 0)"$'\n'
fi

expect 'auditoria das pastas lê o CSV e verifica a ACL' \
    "${expected_owner}[POLICY] $integration_folder: default:other: = r-x (esperado: ---)"$'\n' \
    check_policy_directories "$integration_policy"

# Auditoria dos ficheiros dentro das pastas da política.
files_folder="$tmp/ficheiros"
child_folder="$files_folder/reservado"
files_policy="$tmp/ficheiros.csv"
sample="$files_folder/documento com espacos"

mkdir -p "$child_folder"
printf 'folder,group,access\n%s,%s,rwx\n%s,adm,r-x\n%s,adm,rwx\n' \
    "$files_folder" "$group" "$files_folder" "$child_folder" > "$files_policy"

touch "$sample"
chmod 0600 "$sample"
setfacl -m g:adm:r--,u:nobody:r-- "$sample"

expect 'leitura autorizada e ACL individual de leitura compatível com estagiário' '' \
    check_policy_files "$files_policy" "$files_folder"

chmod o+r "$sample"
expect 'ficheiro com leitura para others' \
    "[POLICY] $sample: acesso de others (r--)"$'\n' \
    check_policy_files "$files_policy" "$files_folder"
chmod o-r "$sample"

setfacl -m g:adm:rw- "$sample"
expect 'ficheiro com escrita para grupo só de leitura' \
    "[POLICY] $sample: escrita de grupo não autorizada (adm)"$'\n' \
    check_policy_files "$files_policy" "$files_folder"

setfacl -n -m m::r-- "$sample"
expect 'máscara retira a escrita efetiva' '' \
    check_policy_files "$files_policy" "$files_folder"

# Usar um grupo existente na VM que esteja fora desta política de teste.
extra_group=$(id -gn nobody)
setfacl -m "g:adm:r--,g:$extra_group:r--" "$sample"
expect 'ficheiro com acesso de grupo fora da política' \
    "[POLICY] $sample: acesso de grupo não autorizado ($extra_group)"$'\n' \
    check_policy_files "$files_policy" "$files_folder"
setfacl -x "g:$extra_group" "$sample"

# adm pode escrever na subpasta, mas só pode ler na pasta-mãe.
child_file="$child_folder/documento"
touch "$child_file"
chmod 0600 "$child_file"
setfacl -m g:adm:rw- "$child_file"

check_parent_and_child_files() {
    check_policy_files "$files_policy" "$files_folder" || return 1
    check_policy_files "$files_policy" "$child_folder" || return 1
}

expect 'subpasta usa a sua própria política' '' check_parent_and_child_files

# 2.6 — Comparação entre duas execuções da auditoria.
previous="$tmp/anterior.txt"
current="$tmp/atual.txt"

: > "$previous"
printf '%s\n' '[SUDO] ze: pertence a sudo e não pertence a it' > "$current"

expect '2.6 primeira execução apresenta a ocorrência como NEW' \
    $'NEW [SUDO] ze: pertence a sudo e não pertence a it\n' \
    compare_findings "$previous" "$current"

cp -- "$current" "$previous"
printf '%s\n' '[UID0] duplicado: UID 0' > "$current"

expect '2.6 distingue uma ocorrência nova de uma resolvida' \
    $'NEW [UID0] duplicado: UID 0\nRESOLVED [SUDO] ze: pertence a sudo e não pertence a it\n' \
    compare_findings "$previous" "$current"

printf '%s\n' '[PWDEXP] ana: palavra-passe expira em 7 dia(s)' > "$previous"
printf '%s\n' '[PWDEXP] ana: palavra-passe expira em 6 dia(s)' > "$current"

expect '2.6 mantém a identidade quando muda a contagem de dias' \
    $'Sem alterações.\n' \
    compare_findings "$previous" "$current"

# 2.6 — Estado entre execuções, usando apenas a pasta temporária do teste.
state_file="$tmp/estado"
loaded="$tmp/historico-lido"
finding='[SUDO] ze: pertence a sudo e não pertence a it'
printf '%s\n' "$finding" > "$current"

compare_saved_state() {
    load_audit_state "$state_file" "$loaded" || return 1
    compare_findings "$loaded" "$current"
}

expect '2.6 estado ausente apresenta a ocorrência como NEW' \
    "NEW $finding"$'\n' compare_saved_state

save_audit_state "$state_file" "$current"
expect '2.6 segunda execução recupera o estado anterior' \
    $'Sem alterações.\n' compare_saved_state

expect '2.6 ficheiro de estado privado' \
    $'600\n' stat -c '%a' -- "$state_file"

# Simular uma escrita interrompida mantendo o cabeçalho e perdendo os dados.
sed -i '2,$d' "$state_file"
expect '2.6 estado truncado reinicia a comparação' \
    "NEW $finding"$'\n' compare_saved_state 2> "$tmp/aviso-estado"

expect '2.6 estado truncado produz aviso' \
    "Aviso: estado inválido em $state_file; histórico reiniciado."$'\n' \
    cat "$tmp/aviso-estado"

# Uma auditoria sem ocorrências também tem de poder guardar estado válido.
: > "$current"
save_audit_state "$state_file" "$current"
expect '2.6 estado válido sem ocorrências' \
    $'Sem alterações.\n' compare_saved_state 2> "$tmp/aviso-vazio"

expect '2.6 estado válido vazio é lido sem aviso' \
    '' cat "$tmp/aviso-vazio"

# 2.5 — Uma entrada individual com escrita excede a exceção dos estagiários.
# Usamos a pasta temporária cuja política e ACL já foram validadas.
setfacl -n -m u:nobody:rwx "$folder"

expect '2.5 deteta escrita numa ACL individual da pasta' \
    "[POLICY] $folder: escrita em ACL individual: user:nobody:rwx"$'\n' \
    check_policy_group_acls "$policy" "$folder"

# Retirar a escrita no acesso atual e concedê-la apenas por omissão.
setfacl -n -m u:nobody:r-x,d:u:nobody:rwx "$folder"
expect '2.5 deteta escrita numa ACL individual por omissão' \
    "[POLICY] $folder: escrita em ACL individual: default:user:nobody:rwx"$'\n' \
    check_policy_group_acls "$policy" "$folder"

# Repor a permissão compatível com a exceção de leitura dos estagiários.
setfacl -n -m d:u:nobody:r-x "$folder"
expect '2.5 aceita ACL individual r-x de acesso e por omissão' \
    '' check_policy_group_acls "$policy" "$folder"

echo 'Todos os testes passaram.'
