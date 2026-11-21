# PRCSE — Challenge 1 Report (Group 6)

> **Limite:** Máximo 20 páginas + anexos (exportar para `report.pdf` na raiz do `.zip`).

---

## 1. Team

| Name | Student Number | Responsibilities |
| :--- | :--- | :--- |
| Hugo Filipe Correia Costeira | 1260477 | Part 1 (`provision.sh`), Part 1 tests, Approach & Test Scenarios (Part 1), AI Case 1 |
| José Paulo Ferreira De Sousa | 1241915 | Part 2 (`audit.sh`, `audit.cron`), Part 2 tests, Approach & Test Scenarios (Part 2), AI Case 2 |
| José Luis Figueiredo De Freitas | 1261886 | Part 3 (`analyze_auth.sh`, `output.txt`), Part 3 tests, Incident Report, AI Case 3 |

---

## 2. Approach

*(Sem dumps de código: explicar como funciona, principais decisões + porquê, e limitações conhecidas. Mostrar apenas as linhas essenciais.)*

### 2.1 Part 1 — Provisioning (`provision.sh`)
- **Input parsing & validation:** `provision.sh` segue um modelo *fail-fast* na estrutura e resiliente nos registos de RH. Valida privilégios de `root` (dispensados em `--dry-run`), existência/legibilidade dos CSVs e cabeçalhos exatos após remoção em memória de UTF-8 BOM (`\xef\xbb\xbf`) e quebras CRLF (`\r\n`). Erros estruturais ou regras inválidas em `access-policy.csv` abortam com `exit 1` antes de alterar o sistema; linhas individuais inválidas em `employees.csv` (campo em falta, departamento desconhecido, `role`/`status` inválidos, `employee_id` duplicado ou `intern` sem `end_date` válido) são rejeitadas com aviso (n.º da linha e motivo), continuando o processamento e terminando com `exit 2`. Os departamentos válidos são extraídos dinamicamente das pastas de topo `/srv/company/<nome>` presentes na política (excluindo `public`), sem qualquer lista *hard-coded*.
- **Username generation & collision handling:** O username base junta a 1.ª letra do `first_name` à última palavra do `last_name`, em minúsculas e apenas `a-z`, usando `LC_ALL=C.UTF-8 iconv -f UTF-8 -t ASCII//TRANSLIT` para transliterar acentos de forma independente do *locale*. Contas já geridas são reconhecidas pelo `employee_id` no campo GECOS (`First Last (E1001)`), preservando o username mesmo se o nome mudar. Colisões são resolvidas por ordem do CSV (`2`, `3`, …) face a `/etc/passwd` e ao histórico persistente `/var/lib/provision/usernames.txt`, garantindo que um username nunca é reutilizado após offboarding.
- **Accounts, passwords, expiry & `sudo`:** Cria os grupos em falta (departamentos + `employees` + `managers`). Novas contas recebem home `/home/<username>` (`0700`), shell `/bin/bash`, password aleatória de 16 caracteres (via `/dev/urandom`, guardada apenas em `/root/initial-passwords.txt` com permissões `0600` e nunca registada em logs/ecrã) e troca obrigatória no 1.º login (`chage -d 0`). Todas as contas têm expiração de password de 180 dias com aviso 14 dias antes (`chage -M 180 -W 14`). Contas `intern` recebem expiração de conta em `<end_date>` (`chage -E`), removida (`chage -E -1`) se passarem a `staff`/`manager`. A pertença aos grupos e a `sudo` (exclusiva a membros `active` não-`intern` de `it`) é sincronizada de forma exata, adicionando e removendo membros conforme necessário.
- **Shared folders, ACLs, setgid, interns & parent-folder traversal:** Cada pasta da política é criada com dono `root`, grupo igual ao primeiro grupo com `rwx` na política (ou `root` se não houver), bit `setgid` ativo (`2770`) e `others` sem acesso (`---`). São aplicadas ACLs exatas de acesso e *default ACLs* para herança, propagando também aos ficheiros e subpastas existentes (excluindo subpastas que tenham regra própria na política). Quando um grupo tem acesso a uma subpasta (ex.: `/srv/company/hr/payroll` para `finance`) sem ter acesso à pasta-pai (`/srv/company/hr`), a pasta-pai recebe apenas travessia mínima (`g:<grupo>:--x`), impedindo a listagem do diretório pai. Para `intern`, quando o seu departamento tem `rwx` numa pasta, é aplicada uma ACL individual `u:<username>:r-x` (e *default ACL* `r-x`) para restringir a escrita sem bloquear a leitura.
- **Idempotency, `--dry-run` & offboarding:** Todas as operações comparam o estado atual antes de aplicar alterações, registando uma linha por alteração em `/var/log/provision.log` (ou imprimindo `[DRY-RUN] ...` sem tocar no sistema). No offboarding (`status=left` com conta existente), a conta é bloqueada/expirada e sessões ativas são terminadas, a home é arquivada em `/srv/archive/<username>_<id>_<YYYY-MM-DD>.tar.gz` (`0600` só `root`) com verificação de integridade (`tar -tzf`) antes de apagar ficheiros, os ficheiros do utilizador em `/srv/company` passam para dono `root` (mantendo o grupo), e a crontab, conta e home são removidas. Utilizadores geridos que desaparecem do CSV sem `status=left` não são removidos, gerando apenas um aviso.
- **Known limitations:** A verificação completa de `chage` e do ficheiro `/root/initial-passwords.txt` exige execução como `root` (em `--dry-run` sem `root`, alterações a `chage` são simuladas por falta de leitura de `/etc/shadow`). Além disso, o script assume que os nomes das pastas de departamento em `/srv/company/<nome>` coincidem com o nome do grupo correspondente na política, conforme o contrato acordado com a Parte 2.

### 2.2 Part 2 — Daily Security Audit (`audit.sh` & `audit.cron`)

A auditoria diária compara o estado do servidor com o ficheiro de política usado pelo provisionamento. Consulta as contas com UID 0, os membros de sudo fora de it, os campos de palavra-passe vazios e os prazos de expiração. Na pesquisa de escrita pública exclui ligações simbólicas e as árvores /proc, /sys, /dev e /run. Uma pasta com sticky bit é excluída deste alerta; os ficheiros no seu interior continuam a ser verificados.

Nas pastas da política, o auditor verifica o proprietário, o primeiro grupo com rwx, o bit setgid, o acesso de outros e as ACL de acesso e por omissão. Um grupo com acesso apenas a uma subpasta pode atravessar a pasta-mãe com --x. A leitura adicional no pai constitui um desvio. Nos ficheiros, a máscara determina as permissões efetivas. Uma subpasta com regras próprias é avaliada segundo essas regras.

O estado guarda as ocorrências da última execução. Para as expirações, a chave combina categoria e conta, permitindo que a contagem de dias mude sem gerar um novo alerta. Um histórico ausente ou com soma SHA-256 inválida inicia uma nova comparação. O relatório diário apresenta NEW e RESOLVED, ou uma linha quando nada mudou. O modo --full mostra todas as ocorrências atuais. Os ficheiros de estado e relatório são privados de root. O cron agenda o script às 06:00, flock impede sobreposição e logger regista erros com o identificador prcse-audit.

**Âmbito da validação.** Os testes foram executados em Ubuntu Server 24.04.3 LTS com dados controlados e com o auditor instalado. A integração com o provisionamento do grupo em 26.04 e o disparo real às 06:00 ficam por confirmar. A política identifica grupos e permissões; a auditoria reconhece ACL individuais de leitura compatíveis com a exceção de estagiário, mas não autentica o estatuto de cada titular. Duas execuções no mesmo dia publicam no mesmo relatório datado.

### 2.3 Part 3 — Auth Log Analysis (`analyze_auth.sh`)
- **Log ingestion, decompression & chronological sorting:** ...
- **Detection logic (brute force, password spray, success after failures, top active):** ...
- **Performance (<30s on VM):** ...
- **Known limitations:** ...

---

## 3. Test Scenarios

*(Incluir casos que **não** devem ser detetados / falsos positivos.)*

### 3.1 Part 1 Test Scenarios
| Scenario | Setup | Expected Result | Observed Result (with evidence) |
| :--- | :--- | :--- | :--- |
| CLI, BOM/CRLF & CSV validation (`test_phase0.sh`, `test_phase1.sh`) | CSVs com UTF-8 BOM, CRLF, espaços, cabeçalhos trocados, campos em falta, `role`/`status`/departamento inválidos, IDs duplicados, `intern` sem data válida e `employees.csv` real | Erros estruturais devolvem `exit 1`; linhas individuais inválidas são rejeitadas com aviso e `exit 2`; usernames tratam acentos/colisões por ordem | 14/14 testes da Fase 0 e 17/17 da Fase 1 aprovados; na VM com `employees.csv` devolveu `exit 2` com exatamente 4 linhas rejeitadas (34, 35, 36, 40) |
| Accounts, groups, `chage`, `sudo` & idempotency (`test_phase2.sh`, VM) | Execução real (`sudo`) com `employees.csv` seguida de 2.ª execução idêntica em Ubuntu 26.04 LTS | 33 contas criadas com `/root/initial-passwords.txt` (`0600`), `chage` (180/14 e `-E` em `intern`), `sudo` só para `it` ativo não-`intern`; 2.ª execução com 0 alterações | 22/22 testes da Fase 2 aprovados; na VM, 33 linhas em `/root/initial-passwords.txt` (`0600`), `sudo` apenas com `hcosteira,jpereira,tmartins,hferreira`, `dmoreira` com `Jan 31, 2027`, e 2.ª execução devolveu `No changes needed (already up to date).` (`exit 2`) |
| Shared folders, ACLs, traversal & Parte 2 (`test_phase4.sh`, `test_phase5_synthetic.sh`, VM) | `/srv/company/hr` e `hr/payroll`, 2.º conjunto sintético (`synth_mkt`, `synth_ops`, `synth_rnd`) e execução de `part2/audit.sh --full` após provisionamento | `root:<1.º rwx>` e `2770`; travessia `--x` na pasta-pai sem default ACL; exceção `r-x` para `intern`; 0 falsos positivos no `audit.sh` | 14/14 (Fase 4) e 15/15 (sintético) aprovados; na VM, `getfacl` confirmou `flags: -s-`, `group:finance:--x` em `hr` e `user:fmarques:r-x`; `audit.sh --full` devolveu `exit 0` com **0 alertas de política/ACLs** (apenas `SUDO` de `hcosteira`, `PWDEXP` da troca obrigatória inicial e `ACCTEXP` de `hcardoso` a 6 dias) |
| Updates & Offboarding (`employees_v2.csv`, `test_phase3.sh`, VM) | Execução real com `employees_v2.csv` após `employees.csv` | `E1008` atualiza GECOS mantendo `mlopes`; `E1004` sai de `it`/`sudo` para `engineering`; `E1013` entra em `managers`; `E1017` remove expiração; `E1011`/`E1012` arquivados e removidos; `E1030` apenas avisa | 8/8 testes da Fase 3 aprovados; na VM, `mlopes` e `tcoelho` mantidos em `passwd`, `slima`/`pramos` removidos com `.tar.gz` (`0600`) em `/srv/archive/`, `dmoreira` com `Account expires: never` e `tmartins` removido de `sudo` |

### 3.2 Part 2 Test Scenarios

| Cenário | Preparação | Resultado esperado | Resultado observado e evidência |
| --- | --- | --- | --- |
| Contas e expiração | Registos sintéticos com UID duplicado, contas bloqueadas e prazos de 7 e 8 dias | Sinalizar UID indevido, palavra-passe vazia e prazos dentro da janela | Comparações aprovadas, figs. 1–4 e 29 |
| Escrita pública | Pasta aberta, pasta com sticky bit, ficheiro aberto no interior e ligação simbólica | Alertar para a pasta aberta e o ficheiro | Os dois caminhos esperados apareceram, fig. 5 |
| Travessia e ACL individuais | Atribuir --x no pai, acrescentar leitura, testar escrita individual atual e por omissão e repor r-x | Aceitar travessia e r-x, detetar leitura excessiva do grupo e escrita individual | Desvios detetados e controlos aprovados, figs. 11–12 e 28–29 |
| Máscara e subpastas | Dar escrita a um grupo de leitura, restringir a máscara e testar política específica na subpasta | Alertar para escrita efetiva excessiva e aceitar as duas configurações válidas | Seis cenários de ficheiros aprovados, fig. 18 |
| Primeiro relatório e repetição | Correr duas vezes com a mesma política e o mesmo estado | Primeira execução com NEW e código 2, repetição sem alterações com código 0 | Ambas as execuções confirmadas, figs. 22–23 |
| Ocorrência resolvida e identidade estável | Trocar a ocorrência entre dois ficheiros de teste e fazer variar a contagem de dias da mesma conta | Emitir RESOLVED e NEW na troca; manter silêncio sobre o prazo já conhecido | Comparação automática aprovada, fig. 19. A deteção e correção de uma ACL foi testada separadamente, fig. 7b |
| Estado e modo completo | Truncar o histórico no teste e comparar o estado e o relatório antes e depois de --full na VM | Recuperar com aviso; permitir consulta completa sem modificar os ficheiros | Conteúdo, inode e data preservados na consulta, figs. 20 e 24 |
| Concorrência e instalação | Ocupar o bloqueio e executar o comando instalado em ambiente mínimo | Código 1 e erro no journal para sobreposição; relatório e estado privados no funcionamento normal | Bloqueio confirmado, cron configurado e ficheiros 600 root:root, figs. 25–27 |

### 3.3 Part 3 Test Scenarios
| Scenario | Setup | Expected Result | Observed Result (with evidence) |
| :--- | :--- | :--- | :--- |
| Brute force & password spray | ... | ... | ... |
| Normal typo from usual IP (must NOT trigger) | ... | ... | ... |
| Out-of-order `.gz` + plain logs | ... | ... | ... |

---

## 4. Incident Report (Part 3)

*(1 a 2 páginas: o que aconteceu e quando, o que o atacante fez, que contas e dados foram afetados, o que o `audit.sh` da Parte 2 teria reportado na manhã seguinte, o que deve ser feito agora e o que o teria prevenido.)*

---

## 5. Where the AI Was Wrong and How We Verified (Mandatory)

*(Explicar que ferramentas de IA foram usadas e para quê, pelo menos **3 casos concretos** de `docs/ai_mistakes.md`, e como verificaram código que não escreveram manualmente.)*

### Caso 2 — Parte 2 · ACL individual de escrita

**Ferramenta e pedido.** Usámos o ChatGPT para desenvolver a verificação das ACL das pastas, incluindo a exceção de leitura dos estagiários.

**Excerto proposto.** O ciclo de deteção de entradas adicionais só atribuía significado às entradas nomeadas de grupo:
```bash
if [[ "$line" =~ ^(default:)?group:[^:]+:[rwx-]{3}$ ]]; then
```

**Falha e verificação.** Numa pasta temporária com máscara rwx, o teste atribuiu user:nobody:rwx. Esperávamos um alerta POLICY, mas a função produziu saída vazia. O diff identificou a linha em falta e a bateria devolveu 1, apesar de os 36 testes anteriores passarem (fig. 28).

**Correção e resultado.** Acrescentámos uma verificação de escrita para entradas individuais nomeadas, tanto de acesso como por omissão. Repetimos o teste original, acrescentámos o caso por omissão e um controlo com ambas as permissões em r-x. Os 39 testes passaram com código 0 (fig. 29).
