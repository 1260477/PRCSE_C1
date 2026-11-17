# Referência Compacta — TP1 & TP2 (PRCSE · ISEP)

Resumo de referência rápida extraído de `TP1.pdf` e `TP2.pdf` para manter toda a resolução alinhada com o que foi dado nas aulas (e gastar o mínimo de tokens possível).

---

## 1. Ferramentas e Comandos Dados nas Aulas (TP1)
- **Sistema & Ficheiros:** `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow`, `/var/log/auth.log`, `/home`, `/srv`.
- **Utilizadores & Grupos:** `useradd -m -s /bin/bash -g <prim> -G <sec> -c "<GECOS>" <u>`, `passwd`, `usermod -aG`, `userdel -r`, `id`, `getent passwd`, `getent group`, `chage -l`, `chage -M`, `sudo -u`.
- **Permissões & Modos:** `ls -ld`, `chmod` (`600`, `640`, `644`, `700`, `750`, `755`, `2770` *setgid*, `1777` *sticky*; nunca `777`), `chown u:g`, `chgrp`, `umask`.
- **ACLs:** `getfacl`, `setfacl -m g:<grp>:<perms>`, `setfacl -m u:<user>:<perms>`, `setfacl -d -m ...` (*default ACLs*), `setfacl -R -m ... rX` (`X` maiúsculo = `x` apenas em pastas), `setfacl -x` (remover entrada), `setfacl -k` (remover defaults), `setfacl -b` (remover todas), `setfacl -m m::...` (*mask*; atenção que `chmod` em pastas com ACL altera a `mask`).
- **Texto & Pesquisa:** `grep` (`-i -c -v -E -o -r`), `sort` (`-n -r -t -k`), `uniq -c`, `cut -d -f`, `sed` (`s/.../.../`, `-n '3,6p'`), `awk -F`, `tr`, `head`, `tail` (`-n +2`, `-f`), `wc -l`, `find` (`-name`, `-type f`, `-user`, `-perm -o=w`, `-exec ... {} \;`).
- **Cron:** `crontab -e`, `crontab -l`, caminhos absolutos nos scripts, formato `min hour day month weekday cmd`.

## 2. Sintaxe e Boas Práticas de Bash (TP2)
- **Variáveis & Aspas:** `x="valor"` (sem espaços em `=`), sempre `"$var"` para evitar *word splitting*, `$(cmd)` para capturar output, `$(( ... ))` para aritmética.
- **Argumentos & Input:** `$0`, `$1`, `$#`, `"$@"`, `read -r`, `read -r -s -p` (para passwords, nunca hardcoded no script).
- **Testes & Controlo:** `[[ ... ]]` (`-f`, `-d`, `-z`, `-eq`, `-ne`, `-lt`, `-gt`, `==`, `!=`, `=~`, `&&`, `||`, `!`), `if/elif/else/fi`, `case "$v" in ... esac`, `for ... in ...; do ...; done`, `while ...; do ...; done`, `break`, `continue`.
- **Leitura de CSVs:** `while IFS=, read -r col1 col2 ...; do ... done < <(tail -n +2 ficheiro.csv)`.
- **Arrays & Funções:** arrays indexados `arr=(a b)` (`"${arr[@]}"`, `${#arr[@]}`), arrays associativos `declare -A map` (`"${!map[@]}"` para chaves), funções `nome() { ... }` definidas antes de serem chamadas.
- **Redirecionamento & Erros:** `>&2` para erros/avisos, `2>/dev/null`, `exit 1` em erro fatal.

## 3. Regras de Qualidade e Entrega (TP1 Slide 18 & TP2 Slide 12)
1. **Explicabilidade:** Nunca entregar um comando ou construção que não consigas explicar flag a flag na defesa.
2. **Validação:** `shellcheck <script>.sh` tem de passar; testar com inputs válidos, inválidos e vazios; correr 2 vezes seguidas para confirmar idempotência.
3. **Segurança:** Ficheiros com segredos/passwords em `0600`; nunca `chmod 777`; validar todos os argumentos de entrada.
