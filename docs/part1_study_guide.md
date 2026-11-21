# Guia de Estudo e Defesa — Parte 1 (`provision.sh`)

> Este documento reúne **todas as decisões técnicas, soluções implementadas, sintaxe Bash relevante e pontos-chave para a apresentação (`.pptx`) e defesa oral** da Parte 1. É atualizado no final de cada fase concluída.

---

## 1. Visão Geral da Arquitetura (`part1/provision.sh`)

O `provision.sh` segue uma abordagem **fail-fast na estrutura e resiliente nos dados de RH**:
- Se houver um erro **estrutural ou de ambiente** (não ser `root`, ficheiro em falta, cabeçalho errado, regra inválida em `access-policy.csv`), o script **para imediatamente com `exit 1`** antes de tocar no sistema.
- Se houver um erro numa **linha individual de `employees.csv`** (departamento desconhecido, campo em falta, ID duplicado, `intern` sem data), o script **rejeita apenas essa linha**, imprime o nº da linha + motivo, ativa `HAS_REJECTED=1` e **continua** para as restantes linhas, terminando no fim com **`exit 2`**.

### Fluxo atual implementado (Fases 0 e 1)
1. `parse_args` → lê `-h`/`--help`, `--dry-run`, `<employees.csv>` e `<access-policy.csv>`.
2. `check_pre_reqs` → exige `root` (exceto em `--dry-run`) e verifica se os dois CSVs existem e são legíveis.
3. `check_headers` → valida a 1.ª linha não-vazia de cada CSV (após limpar BOM e `\r`).
4. `load_policy` → lê `access-policy.csv`, valida cada regra (`rwx` ou `r-x`) e guarda em memória.
5. `extract_departments` → descobre dinamicamente os departamentos válidos a partir da política.
6. `load_employees` → lê `employees.csv`, limpa os campos e rejeita linhas inválidas.
7. `load_existing_users` → lê `/etc/passwd` e `/var/lib/provision/usernames.txt` para mapear contas existentes e usernames já usados.
8. `resolve_usernames` → atribui o username final a cada funcionário (mantendo existentes e resolvendo colisões `2`, `3`, ... por ordem do CSV).

---

## 2. Fase 0 — Base, CLI, Segurança e Logging

### O que foi feito e porquê
- **`set -euo pipefail`**:
  - `-e`: para o script se algum comando falhar.
  - `-u`: dá erro se usarmos uma variável não definida (evita bugs silenciosos).
  - `-o pipefail`: garante que erros dentro de pipelines (`cmd1 | cmd2`) não são escondidos.
- **Códigos de saída explícitos (`EXIT_OK=0`, `EXIT_FATAL=1`, `EXIT_REJECTED=2`)**: cumpre a Secção 1.4 do enunciado.
- **`--dry-run` + `log_change()`**:
  - Todas as alterações passam por `log_change()`. Em `--dry-run`, imprime `[DRY-RUN] ...` sem escrever em `/var/log/provision.log` nem alterar o sistema.
  - Nunca se passam passwords para `log_change()`.
- **Limpeza de CSV em fluxo (`remove_BOM`)**:
  - Os CSVs de RH vêm do Excel/Windows com **UTF-8 BOM** (`\xef\xbb\xbf`) e quebras **CRLF (`\r\n`)**.
  - `sed '1s/^\xef\xbb\xbf//' "$file" | tr -d '\r'` limpa tudo em memória **sem alterar o ficheiro original no disco**.

---

## 3. Fase 1 — Leitura, Validação e Usernames

### 3.1 Leitura de `access-policy.csv` (`load_policy`)
- **Estrutura de dados escolhida:**
  - `POLICY_FOLDERS` (array normal): guarda os caminhos únicos **pela ordem exata do CSV** (importante na Fase 4 porque o *group owner* de uma pasta é o **primeiro** grupo com `rwx`).
  - `POLICY_RULES` (dicionário `declare -A`): chave = pasta, valor = pares `grupo:acesso` separados por espaço (ex.: `POLICY_RULES["/srv/company/hr/payroll"]="hr:rwx finance:r-x"`).
  - *Porquê esta estrutura?* Porque em Bash o valor de um dicionário é sempre uma string simples (não há listas aninhadas), e os dicionários não mantêm ordem. Combinar um array ordenado com um dicionário dá-nos acesso direto por pasta e preserva a ordem.
- **Validações:**
  - Ignora linhas em branco e a 1.ª linha não-vazia (cabeçalho já validado).
  - Exige exatamente 3 colunas (`folder,group,access`), caminho absoluto começado por `/`, grupo sem `:` nem espaços, e `access` igual a `rwx` ou `r-x`.
  - Qualquer falha aqui é erro fatal (`exit 1`).

### 3.2 Descoberta dinâmica de departamentos (`extract_departments`)
- **Regra do enunciado (`C1.pdf` Secção 1.1 + `contracts.md`):**
  - Nenhum departamento pode estar *hard-coded* (o script é avaliado com um 2.º conjunto sintético de ficheiros).
  - Um departamento válido é toda a pasta de topo `/srv/company/<nome>` (sem subpastas como `/srv/company/hr/payroll`), diferente de `public`, que tenha uma regra para o grupo `<nome>` na política.

### 3.3 e 3.4 Leitura e validação de `employees.csv` (`load_employees`)
- **Normalização:**
  - `trim()` remove espaços antes e depois de cada campo (ex.: `" Jorge "` → `"Jorge"`).
  - `to_lower()` normaliza `department`, `role` e `status` para minúsculas (*case-insensitive*), preservando a capitalização original de `first_name` e `last_name`.
- **Regras de rejeição (imprime linha + motivo, marca `HAS_REJECTED=1` e continua):**
  1. Mais de 7 colunas.
  2. Campo obrigatório vazio (`employee_id`, `first_name`, `last_name`, `department`, `role`, `status`).
  3. `employee_id` duplicado (mantém o 1.º, rejeita o seguinte).
  4. `department` não pertence a `VALID_DEPARTMENTS`.
  5. `role` fora de `("staff" "manager" "intern")`.
  6. `status` fora de `("active" "left")`.
  7. `intern` sem `end_date` válido no formato `YYYY-MM-DD` (validado com regex + `date -d` para apanhar datas impossíveis como `2026-02-30`).
- **Armazenamento em memória:**
  - `EMP_IDS` (array ordenado para preservar a ordem do CSV nas colisões) + dicionários por `employee_id` (`EMP_FIRST`, `EMP_LAST`, `EMP_DEPT`, `EMP_ROLE`, `EMP_STATUS`, `EMP_END_DATE`, `EMP_USERNAME`).

### 3.5 Geração de username base (`normalize_alpha` + `generate_base_username`)
- Regra: **1.ª letra de `first_name`** + **última palavra de `last_name`** (`awk '{print $NF}'`), tudo em minúsculas, sem acentos e apenas `a-z` (remove apóstrofos como `O'Connor` → `oconnor`).
- **Armadilha descoberta em teste:** `iconv -f UTF-8 -t ASCII//TRANSLIT` depende do *locale*. Em ambientes com `LC_ALL=C`, o `iconv` apaga caracteres acentuados (`João` → `joo`) em vez de os converter! Por isso forçamos **`LC_ALL=C.UTF-8 iconv ...`**, garantindo `João` → `joao` e `Gonçalves` → `goncalves`.

### 3.6 e 3.7 Reconhecimento de contas e colisões (`load_existing_users` + `resolve_usernames`)
- **Reconhecimento pelo GECOS (`1.7`):**
  - Lê `getent passwd` e procura contas cujo campo GECOS termine em `(<employee_id>)` (ex.: `Ana Silva (E1001)`).
  - Se a pessoa já tiver conta no Linux, **mantém o username atual** mesmo que mude de nome (o comment será atualizado na Fase 2).
- **Prevenção de colisões e não-reutilização (`1.6`):**
  - `USED_USERNAMES` junta: contas atuais do Linux (`/etc/passwd`) + histórico persistente (`/var/lib/provision/usernames.txt`) + usernames atribuídos nesta execução.
  - Se `status=left` e nunca teve conta, não gera nem reserva username (Passo 3.1).
  - Para novos utilizadores `active`, percorre `EMP_IDS` pela ordem do CSV e tenta `base`, `base2`, `base3`, … até encontrar um livre.

---

## 4. Sintaxe Bash para Explicar na Defesa (Resumo Rápido)

| Expressão Bash | Significado | Equivalente em TS / C# |
| :--- | :--- | :--- |
| `declare -A DIC` | Cria um dicionário (array associativo) | `Record<string, string>` / `Dictionary<string, string>` |
| `"${ARR[@]}"` | Todos os elementos do array, cada um entre aspas | `...ARR` (spread) |
| `"${#ARR[@]}"` | Tamanho do array | `ARR.length` / `ARR.Count` |
| `${DIC[$k]:-}` | Lê a chave `k` (devolve vazio se não existir, sem erro do `set -u`) | `DIC[k] ?? ""` |
| `${s:0:1}` | 1.º caráter da string `s` | `s.slice(0, 1)` / `s.Substring(0, 1)` |
| `${p%/}` | Remove `/` do fim da string `p` | `p.replace(/\/$/, "")` |
| `while IFS= read -r line` | Lê uma linha exata sem partir espaços nem interpretar `\` | `readLine()` |
| `[[ "$g" =~ \(([^()]+)\)$ ]]` | Regex; captura o texto dentro de `(...)` para `${BASH_REMATCH[1]}` | `match[1]` |

---

## 5. Pontos Fortes para o `.pptx` (Parte 1 — até agora)
- **Segurança & Robustez:** `set -euo pipefail`, limpeza de BOM/CRLF sem alterar ficheiros originais, `LC_ALL=C.UTF-8` no `iconv`, separação clara entre erro fatal (`exit 1`) e rejeição de linha (`exit 2`).
- **Zero Hard-coding:** departamentos extraídos dinamicamente da política (`access-policy.csv` como fonte única de verdade).
- **Rastreabilidade de identidade:** ligação imutável por `employee_id` no campo GECOS + histórico persistente de usernames para impedir reutilização após *offboarding*.

---

## Fase 2 — Contas de Utilizador e Grupos

### O que foi implementado e porquê
1. **Grupos dinâmicos e globais (`ensure_groups`):**
   - Junta `VALID_DEPARTMENTS` (vindos da política) com `GLOBAL_GROUPS=("employees" "managers")`, sem duplicados.
   - Verifica com `getent group "$grp"` antes de chamar `groupadd "$grp"`, garantindo idempotência e sem usar `sudo` dentro do script (o script já corre como `root`).
2. **Contas de utilizador e GECOS (`ensure_users`):**
   - Processa apenas `status = active`.
   - Para contas existentes (identificadas por `employee_id` no GECOS), compara o GECOS atual com `First Last (ID)` e só corre `usermod -c` se o nome tiver mudado.
   - Para contas novas, cria com `useradd -m -d "/home/$username" -s /bin/bash -c "$expected_gecos" "$username"`, aplica `chmod 0700` à pasta home e regista o username em `/var/lib/provision/usernames.txt`.
3. **Passwords iniciais seguras (`generate_password`, `save_initial_password`):**
   - Lê 256 bytes de `/dev/urandom`, filtra para caracteres seguros (sem `:`) e usa `cut -c1-16` (evitando `head -c 16`, que causaria `SIGPIPE` em `tr` com `set -o pipefail`).
   - Aplica via `printf '%s:%s\n' ... | chpasswd` (sem expor a password nos argumentos do processo), força troca no 1.º login com `chage -d 0` e guarda em `/root/initial-passwords.txt` com `chmod 0600`.
4. **Política de expiração de password e de conta (`ensure_password_policy`, `ensure_account_expiry`):**
   - `chage -M 180 -W 14` para todos os utilizadores ativos. Para contas existentes, consulta `LC_ALL=C chage -l` (de forma segura, sem falhar em `--dry-run` sem `root`) para só alterar quando houver diferença real.
   - Para `intern`, aplica `chage -E <end_date>`; se deixar de ser `intern`, remove a expiração com `chage -E -1`. Como `LC_ALL=C chage -l` imprime a data em formato legível (ex.: `Dec 31, 2026`), converte-se com `date -d ... '+%Y-%m-%d'` para comparar com o CSV.
5. **Sincronização de grupos e regra `sudo` (`ensure_user_groups`, `ensure_sudo_access`):**
   - Garante que cada utilizador ativo pertence exatamente a `<dept>`, `employees` e `managers` (só se `role == manager`), adicionando os em falta (`usermod -aG`) e removendo grupos geridos antigos (`gpasswd -d`).
   - Em `sudo`, adiciona apenas `active` não-`intern` do departamento `it` e remove qualquer utilizador gerido que tenha deixado de cumprir essa condição (sem tocar em contas de administração do próprio sistema).

### Sintaxe Bash para recordar na defesa
- `${EXISTING_EMP_USER["$emp_id"]:-}`: o `:-` devolve string vazia se a chave não existir no dicionário, evitando erro com `set -u`.
- `LC_ALL=C chage -l "$username"`: força o output em inglês independentemente do idioma do sistema operativo.
- `IFS=',' read -r -a arr <<< "$csv"`: divide uma string separada por vírgulas diretamente para um array Bash.

---

## Fase 3 — Offboarding e Desaparecimentos

### O que foi implementado e porquê
1. **`status = left` sem conta existente (`offboard_users` — Passo 3.1):**
   - Se um colaborador aparece no CSV com `status = left`, mas `EXISTING_EMP_USER["$emp_id"]` está vazio (ou `id "$username"` não existe), o script faz `continue` silenciosamente: não cria conta, não reserva username e não regista alterações.
2. **`status = left` com conta existente (`offboard_users` — Passo 3.2, explicado em detalhe):**
   - A ordem das operações é crítica para segurança e integridade dos dados:
     1. **Bloquear conta e terminar sessões:** `usermod -L "$username"` bloqueia a password, mas por si só não impede logins por chave SSH; por isso aplica-se também `chage -E 0 "$username"` (expira a conta de imediato). De seguida, `pkill -TERM -u "$username"` e, após `sleep 1`, `pkill -KILL -u "$username"` terminam processos ativos (com `2>/dev/null || true`, porque `pkill` devolve exit code `1` quando não há processos e `set -e` abortaria o script).
     2. **Arquivar a pasta home e validar integridade:** descobre-se a home real com `getent passwd "$username" | cut -d: -f6`. Garante-se `/srv/archive` com permissões `0700` (`root:root`) e cria-se `/srv/archive/<username>_<emp_id>_<YYYY-MM-DD>.tar.gz` com `tar -czf "$archive_path" -C "$(dirname "$home_dir")" "$(basename "$home_dir")"` (usando `-C` para guardar caminhos relativos, sem `/home/...` absoluto) e `chmod 0600`. Antes de apagar qualquer ficheiro, valida-se o arquivo com `gzip -t "$archive_path"` e `tar -tzf "$archive_path" >/dev/null` — se falhar, `fatal` aborta o offboarding desse utilizador para evitar perda de dados.
     3. **Transferir propriedade em `/srv/company`:** `find "$COMPANY_DIR" -user "$username" -exec chown -h root {} +` muda apenas o dono para `root`, **preservando o grupo original** (ao omitir `:grupo` no `chown`), evitando ficheiros com UID órfão sem quebrar o acesso da equipa. O `-h` impede seguir symlinks.
     4. **Histórico, crontab e remoção:** chama-se `record_used_username "$username"` para garantir que o username nunca é reutilizado; remove-se a crontab com `crontab -r -u "$username" 2>/dev/null || true` (para não falhar se não existir crontab); e remove-se a conta/home com `userdel -r "$username" 2>/dev/null || userdel "$username"`.
3. **Desaparecimento do CSV sem `status = left` (`warn_missing_users` — Passo 3.3):**
   - Percorre as chaves de `EXISTING_EMP_USER` (todas as contas Linux geridas com `(E...)` no GECOS) e verifica se falta entrada em `EMP_STATUS["$emp_id"]`.
   - Se faltar, imprime apenas um `Warning:` para `stderr` — **nunca** remove nem bloqueia a conta, e não altera `CHANGES_MADE` nem `HAS_REJECTED`.

### Sintaxe Bash para recordar na defesa
- `chown -h root ficheiro`: altera apenas o *owner* para `root`, mantendo o *group* intacto; `-h` atua no próprio symlink em vez do alvo.
- `tar -czf destino.tar.gz -C /pai pasta`: muda para `/pai` antes de comprimir `pasta`, evitando caminhos absolutos dentro do `.tar.gz`.
- `gzip -t arquivo.tar.gz && tar -tzf arquivo.tar.gz >/dev/null`: testa a integridade da compressão e da estrutura `tar` antes de apagar a home original.
- `comando || true`: impede que `set -e` aborte o script quando um comando auxiliar (como `pkill` sem processos ou `crontab -r` sem crontab) devolve código diferente de `0`.
- `for emp_id in "${!EXISTING_EMP_USER[@]}"`: o `!` antes do nome do array associativo itera sobre as **chaves** (neste caso os `employee_id`), e não sobre os valores.

---

## Fase 4 — Pastas Partilhadas e ACLs

### O que foi implementado e porquê
1. **Criação e configuração base das pastas (`get_folder_group_owner`, `ensure_shared_folders` — Passo 4.1):**
   - Garante que `/srv/company` existe com dono `root:root` e permissões `0711` (`rwx--x--x`) quando não está listado diretamente em `access-policy.csv`: assim os utilizadores conseguem atravessar `/srv/company` até às pastas dos seus departamentos, sem conseguirem listar o conteúdo da raiz.
   - Para cada pasta única em `POLICY_FOLDERS`, `get_folder_group_owner` percorre `POLICY_RULES["$folder"]` pela ordem do CSV e escolhe o **primeiro grupo com `rwx`** (com *fallback* para `root` caso a pasta só tenha regras `r-x`, evitando dar escrita implícita via grupo).
   - Cria a pasta com `mkdir -p`, define `chown root:<grupo>` e `chmod 2770`:
     - O bit `2` (*setgid*, `g+s`) faz com que novos ficheiros/subpastas herdem o grupo da pasta em vez do grupo primário do utilizador.
     - O `0` final (`others = ---`) bloqueia qualquer acesso fora dos grupos/ACLs autorizados.
   - Para pastas já existentes, usa `stat -c '%U'`, `stat -c '%G'` e `stat -c '%a'` para só aplicar `chown`/`chmod` quando há diferença real (e *antes* das ACLs, porque `chmod` altera a `mask` das ACLs).

2. **ACLs exatas e *default ACLs* (`sync_directory_acl` — Passo 4.2):**
   - Constrói a lista exata de permissões de acesso (`u::rwx`, `g::rwx`, `o::---`, `m::rwx` e cada `g:<grupo>:<perms>` da política) e a lista equivalente de *default ACLs* (`setfacl -d -m ...`) para que novos ficheiros e subpastas herdem automaticamente a política.
   - A `mask` (`m::rwx`) é obrigatória: em ACLs POSIX, a máscara limita a permissão máxima efetiva de qualquer grupo nomeado ou utilizador nomeado (`u:<user>:`, `g:<grp>:`). Sem `m::rwx`, uma entrada `rwx` poderia ficar reduzida.
   - Antes de aplicar, corre `setfacl -b` para apagar quaisquer ACLs residuais antigas (por exemplo, de um grupo que saiu da política), garantindo que a ACL final reflete **exatamente** o `access-policy.csv`.

3. **Travessia mínima `--x` em pastas-pai (`get_traversal_groups_for_folder` — Passo 4.3):**
   - Se uma pasta `sub` é descendente estrita de `parent_folder` (`[[ "$sub" == "$parent_folder/"* ]]`), qualquer grupo presente em `sub` que **não** tenha regra explícita em `parent_folder` recebe apenas `g:<grupo>:--x` na ACL de acesso de `parent_folder` (ex.: `finance` tem `r-x` em `/srv/company/hr/payroll`, logo recebe `g:finance:--x` em `/srv/company/hr`).
   - Nota importante: esta entrada `--x` vai apenas para a **ACL de acesso** da pasta-pai e **não** para as *default ACLs*, para que o grupo consiga atravessar a pasta-pai sem herdar acesso a outras subpastas novas lá criadas.

4. **Exceção de estagiários (`get_folder_interns` — Passo 4.4):**
   - Percorre `EMP_IDS` à procura de utilizadores `active` com `role == intern` cujo departamento tenha `rwx` nessa pasta (`" ${dept}:rwx "`).
   - Adiciona `u:<username>:r-x` à ACL de acesso e `d:u:<username>:r-x` à *default ACL*.
   - Funciona mesmo o estagiário pertencendo ao grupo do departamento (`g:<dept>:rwx`) porque, na avaliação de ACLs POSIX, a entrada de **utilizador nomeado (`u:<user>:`) tem prioridade sobre as entradas de grupo (`g:<dept>:`)**, restringindo o estagiário a leitura/travessia (`r-x`).

5. **Conteúdo já existente e proteção de subpastas com política própria (`ensure_folder_acls`, `sync_file_acl`, `is_under_other_policy_folder` — Passo 4.5):**
   - Quando a pasta já existe no disco, `find "$folder" -mindepth 1 -print0` percorre subpastas e ficheiros já existentes.
   - `is_under_other_policy_folder` ignora qualquer caminho que pertença a uma pasta mais específica da política (ex.: ao sincronizar `/srv/company/hr`, nunca toca em `/srv/company/hr/payroll`), evitando sobrescrever políticas mais específicas e quebrar a idempotência.
   - Em **ficheiros regulares** (`sync_file_acl`), não se aplicam *default ACLs* (inválido em ficheiros) e preserva-se o bit `x` apenas se o ficheiro já for executável (`[[ -x "$target" ]]`), equivalendo ao `rX`/`rwX` do `setfacl` (não dá permissão de execução indevida a documentos).

6. **Idempotência nas pastas e ACLs (`normalize_getfacl` — Passo 4.6):**
   - Para cada pasta ou ficheiro existente, `normalize_getfacl` lê `getfacl -p --omit-header`, remove comentários (`#...`) e linhas em branco, e ordena as linhas.
   - O script constrói a lista canónica esperada (também ordenada) e compara as duas strings: **só chama `setfacl` e `log_change` quando existe diferença real**. Assim, uma segunda execução com os mesmos ficheiros devolve `No changes needed (already up to date).`.

### Sintaxe Bash para recordar na defesa
- `stat -c '%U'` / `'%G'` / `'%a'`: lê respetivamente o dono, o grupo e o modo octal atual (ex.: `2770`) de um ficheiro/pasta.
- `setfacl -b <alvo>`: remove todas as ACLs estendidas e *default ACLs* existentes antes de reaplicar a política limpa.
- `setfacl -m <spec> <alvo>` e `setfacl -d -m <spec> <alvo>`: aplica ACLs de acesso e *default ACLs* (herança para novos itens), respetivamente.
- `getfacl -p --omit-header <alvo>`: mostra as ACLs sem cabeçalho `# file:` e preservando o caminho completo (`-p`), ideal para comparação automática.
- `find "$folder" -mindepth 1 -print0` com `while IFS= read -r -d '' item`: percorre ficheiros/pastas de forma segura mesmo que tenham espaços no nome (`-print0` + `-d ''` usa NUL como separador).
- `(IFS=','; echo "${arr[*]}")`: junta os elementos de um array com vírgulas dentro de uma *subshell* `( ... )` para não alterar o `IFS` global do script.

---

## Fase 5 — Testes e Validação

### O que foi validado e porquê
1. **Bateria automatizada em `tests/part1/` (90 testes em `--dry-run` e unitários):**
   - `test_phase0.sh` (**14/14**): CLI (`-h`/`--help`), rejeição de argumentos inválidos (`exit 1`), exigência de `root` fora de `--dry-run`, cabeçalhos trocados/vazios e `exit 2` nos CSVs reais (`employees.csv` e `employees_v2.csv`) por conterem linhas inválidas intencionais.
   - `test_phase1.sh` (**17/17**): limpeza de UTF-8 BOM + CRLF + espaços, descoberta dinâmica de departamentos, rejeição de linhas (`exit 2`), normalização de acentos/apóstrofos (`LC_ALL=C.UTF-8 iconv`) e colisões por ordem do CSV (`jsilva,jsilva2,jsilva3`).
   - `test_phase2.sh` (**22/22**): criação de grupos, exclusão de `public` como grupo, `generate_password` (16 chars), `chage -M 180 -W 14`, expiração `chage -E` apenas em `intern`, pertença a `managers` e `sudo` exclusivo a `it` ativo não-`intern`.
   - `test_phase3.sh` (**8/8**): `left` sem conta ignorado, `left` com conta bloqueado/arquivado/removido e utilizador gerido ausente do CSV a gerar apenas aviso sem remoção.
   - `test_phase4.sh` (**14/14**): criação de `/srv/company` (`0711`) e pastas `2770`, *fallback* para `root` sem `rwx`, travessia `--x` na pasta-pai, exceção `r-x` de `intern`, exclusão de subpastas com política própria e idempotência.
   - `test_phase5_synthetic.sh` (**15/15**): 2.º conjunto sintético (`synth_mkt`, `synth_ops`, `synth_rnd`) para comprovar zero *hard-coding* de departamentos, pastas ou regras.

2. **Validação real na VM (Ubuntu Server 26.04 LTS, após snapshot):**
   - **1.ª execução (`employees.csv`):** `EXIT_CODE=2` (4 linhas rejeitadas: 34, 35, 36, 40), `/root/initial-passwords.txt` criado com `0600` (`root:root`) e **33 linhas**, `/var/lib/provision/usernames.txt` com `0600`, `/var/log/provision.log` registado, `sudo` apenas com `hcosteira,jpereira,tmartins,hferreira`, `chage -l` validado (`dmoreira` expira em `Jan 31, 2027`, `jpereira` em `never`, ambos `180/14` e troca obrigatória no 1.º login).
   - **ACLs reais (`getfacl`):** `/srv/company/hr` (`root:hr`, `flags: -s-`, `user:fmarques:r-x`, `group:finance:--x` só na ACL de acesso e fora das *default ACLs*, `other::---`) e `/srv/company/hr/payroll` (`root:hr`, `flags: -s-`, `group:finance:r-x`, `user:fmarques:r-x`). Um utilizador sem permissão (`hcosteira`) recebeu `Permission denied` ao tentar aceder a `payroll`.
   - **Idempotência real:** 2.ª execução com `employees.csv` devolveu `No changes needed (already up to date).` e `EXIT_CODE=2`.
   - **Atualização (`employees_v2.csv`):** `tmartins` (`E1004`) movido de `it` para `engineering` e removido de `sudo`; `mlopes` (`E1008`) manteve username e atualizou GECOS; `crocha` (`E1013`) entrou em `managers`; `dmoreira` (`E1017`) passou a `Account expires: never` e perdeu a restrição de estagiário em `sales`; `slima` (`E1011`) e `pramos` (`E1012`) foram arquivados em `/srv/archive/*.tar.gz` (`0600` dentro de `/srv/archive` `0700`) e removidos; `tcoelho` (`E1030`) gerou aviso e manteve a conta ativa; novos colaboradores (`asilva4`, `bnunes`, `cmendes2`) criados corretamente.
   - **Integração com Parte 2 (`part2/audit.sh --full`):** devolveu `EXIT_CODE=0` com **zero desvios de política/ACLs** nas pastas, travessia `--x`, estagiários ou contas geridas (reportou apenas `[SUDO] hcosteira`, `[PWDEXP]` pela troca obrigatória inicial `chage -d 0` das contas recém-criadas e `[ACCTEXP] hcardoso` a 6 dias, correspondente ao estágio até `2026-11-27`).

### Comandos rápidos para a defesa
- Correr toda a bateria de testes da Parte 1:
  ```bash
  for t in tests/part1/test_phase*.sh; do bash "$t"; done
  ```
- Testar `--dry-run` nos ficheiros reais (deve devolver `exit 2` pelas linhas rejeitadas):
  ```bash
  ./part1/provision.sh --dry-run /caminho/employees.csv /caminho/access-policy.csv
  ```
