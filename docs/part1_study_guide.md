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
