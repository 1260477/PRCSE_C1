# PRCSE — Challenge 1 Report (Group 6)

> **Limite:** Máximo 20 páginas + anexos (exportar para `report.pdf` na raiz do `.zip`).

---

## 1. Team

| Name | Student Number | Responsibilities |
| :--- | :--- | :--- |
| Hugo Filipe Correia Costeira | *(Número)* | Part 1 (`provision.sh`), Part 1 tests, Approach & Test Scenarios (Part 1), AI Case 1 |
| José Paulo Ferreira De Sousa | *(Número)* | Part 2 (`audit.sh`, `audit.cron`), Part 2 tests, Approach & Test Scenarios (Part 2), AI Case 2 |
| José Luis Figueiredo De Freitas | *(Número)* | Part 3 (`analyze_auth.sh`, `output.txt`), Part 3 tests, Incident Report, AI Case 3 |

---

## 2. Approach

*(Sem dumps de código: explicar como funciona, principais decisões + porquê, e limitações conhecidas. Mostrar apenas as linhas essenciais.)*

### 2.1 Part 1 — Provisioning (`provision.sh`)
- **Input parsing & validation:** ...
- **Username generation & collision handling:** ...
- **Accounts, passwords, expiry & `sudo`:** ...
- **Shared folders, ACLs, setgid, interns & parent-folder traversal:** *(explicar explicitamente a permissão mínima para alcançar subpastas sem listar o pai)*
- **Idempotency, `--dry-run` & offboarding:** ...
- **Known limitations:** ...

### 2.2 Part 2 — Daily Security Audit (`audit.sh` & `audit.cron`)
- **Checks implemented (UID 0, sudoers, empty passwords, expiring accounts/passwords, world-writable, policy/ACL compliance):** ...
- **State persistence, finding normalization (`NEW`/`RESOLVED`) & locking:** ...
- **Cron minimal environment & permissions:** ...
- **Known limitations:** ...

### 2.3 Part 3 — Auth Log Analysis (`analyze_auth.sh`)
- **Assumptions (o enunciado não define critérios de validade para os ficheiros de log):**
  1. **Todos os ficheiros recebidos são lidos, seja qual for o nome ou a extensão.** Um ficheiro está comprimido ou não conforme o seu conteúdo e não conforme a extensão, por isso um `.gz` renomeado continua a ser lido corretamente. O script só exige que cada ficheiro exista e seja legível.
  2. **Assume-se que todas as linhas dos ficheiros são válidas**, ou seja, começam com um timestamp ISO 8601 no formato do Ubuntu 26.04 (`2026-10-30T21:54:15.984758+00:00`), sempre com o mesmo fuso horário. A ordenação cronológica depende disto: o `sort` ordena a linha inteira alfabeticamente. Linhas que não interessam à análise (por exemplo, mensagens PAM sem relevância) simplesmente não correspondem a nenhum padrão de deteção. *(Limitação conhecida: uma linha sem timestamp válido não é detetada nem reportada e pode ficar fora de ordem.)*
  3. **Um ficheiro `.gz` corrompido é ignorado e o utilizador é alertado.** A análise continua com os restantes ficheiros, e a mensagem de aviso indica qual o ficheiro que não foi lido.
  4. **Assume-se que os ficheiros comprimidos contêm um único log.** Arquivos com vários ficheiros (por exemplo `.tar.gz` ou `.zip`) não são suportados, porque a rotação de logs produz sempre um `.gz` por ficheiro (`auth.log.2.gz`, `auth.log.3.gz`...). Se for dado um `.tar.gz`, o resultado da análise não é fiável.
  5. **Linhas exatamente iguais são tratadas como duplicadas e contadas uma só vez.** A linha inteira tem de ser igual: timestamp, host, processo, PID e mensagem. Isto evita contar eventos a dobrar quando os ficheiros se sobrepõem (por exemplo, o mesmo ficheiro dado duas vezes, ou `auth.log.1` e `auth.log.1.gz`). Dois eventos diferentes no mesmo instante são ambos mantidos, porque são frequentes no auth.log (por exemplo, várias tentativas SSH em paralelo). O resultado também não depende da ordem dos argumentos.
  6. **Um username vazio é mostrado como `<empty>`.** O log tem linhas como `Failed password for invalid user  from 192.0.2.236` (dois espaços, sem username). Como o awk junta espaços seguidos num só separador, o campo vazio desaparece e o campo antes de `from` passa a ser a palavra `user` do texto da mensagem. Para não se confundir com um username real chamado `user` (`invalid user user from`), o script reconhece o caso quando as duas palavras antes de `from` são `invalid user`. O marcador não tem espaços, por isso as colunas mantêm-se, e não pode ser um username real, porque `<` e `>` não são válidos em nomes de utilizador Linux.
  7. **No brute force mostram-se os 3 usernames mais tentados por IP, com o número de tentativas de cada um** (por exemplo, `root(362) admin(72) ubuntu(58)`). O enunciado pede "most tried usernames" sem dizer quantos. O 3 é uma escolha de apresentação e não um limiar de deteção, por isso não altera que IPs são detetados. Também não usa o `-t`, que o enunciado define para os tops da secção 3.5. Em caso de empate, a ordem entre usernames com a mesma contagem não é garantida.
- **Log ingestion, decompression & chronological sorting:** ...
- **Ficheiro temporário seguro:** os eventos preparados ficam num ficheiro temporário criado com `mktemp` e não num caminho fixo como `/tmp/analyze_auth.txt`. Razões:
  - o nome é único e aleatório, e o ficheiro é criado de forma atómica, o que evita ataques por symlink e colisões entre execuções em paralelo;
  - as permissões são `600`, por isso os usernames e IPs dos logs não ficam legíveis por outros utilizadores;
  - respeita a variável `$TMPDIR`.

  O ficheiro é apagado com `trap ... EXIT`, mesmo quando o script termina com erro ou é interrompido.
- **Brute force (3.2):** o enunciado define brute force como N falhas "inside **any** window of MIN minutes", por isso usa-se uma **janela deslizante** e não janelas fixas. Com janelas fixas (por exemplo, recomeçar a contagem quando a janela expira), um ataque que caia entre o fim de uma janela e o início da seguinte fica dividido e não é detetado. A deteção é um pipeline de três passos:
  1. **awk** — das linhas `Failed password` extrai `IP timestamp username`. O IP é o campo a seguir a `from` e o username o campo antes, porque a coluna muda entre `for root from …` e `for invalid user X from …`.
  2. **`LC_ALL=C sort -s -k1,1`** — agrupa as falhas por IP. Como o ficheiro de eventos já está por ordem cronológica, o `-s` (ordenação estável) mantém essa ordem dentro de cada IP.
  3. **awk** — trata um IP de cada vez. Numera as falhas desse IP (`k`) e guarda o tempo de cada uma em segundos. O bloco de N falhas que termina na falha `k` começa na falha `k − N + 1`, por isso, a partir de `k ≥ N`, basta uma comparação:

     ```
     if (k >= n && t[k] - t[k - n + 1] <= window) detected = 1
     ```

  Decisões:
  - **Agrupar por IP com o `sort` simplifica as estruturas de dados:** o awk só guarda o estado do IP atual, em variáveis simples e num array indexado pelo número da falha, sem precisar de arrays por IP. Quando o IP muda, o anterior é reportado (se foi detetado) e o estado é reiniciado. O último IP é reportado no bloco `END`.
  - **Conversão do tempo:** `mktime` do awk, executado com `TZ=UTC`, para o resultado não depender do fuso horário da máquina nem de mudanças de hora.
  - **Limite da janela inclusivo (`<=`):** N falhas que ocupem exatamente MIN minutos contam como brute force.
  - **Primeira e última tentativa e total de falhas são de toda a atividade do IP** em todo o período, e não só do bloco que disparou a deteção.
  - **Resultados guardados e não impressos diretamente:** a função guarda uma linha CSV por IP (`ip,first,last,failures,top_usernames`) no array global `BRUTE_RESULTS`, preenchido com `mapfile`. O relatório é impresso no fim por `print_report`, o que permite à secção 3.6 (timeline) reutilizar os resultados sem os recalcular. A vírgula foi escolhida como separador porque não aparece em timestamps nem em usernames Linux. Se não houver deteções, o relatório diz explicitamente "No brute force attacks detected."
- **Detection logic (password spray, success after failures, top active):** ...
- **Performance (<30s on VM):** ...
- **Known limitations:**
  - **Brute force — `mktime` não é POSIX:** existe no `gawk` e no `mawk` 1.3.4 (o `awk` por omissão no Ubuntu), e o script foi testado com os dois, com o mesmo resultado. Pode não existir noutras implementações de awk.
  - **Brute force — erros no pipeline não são detetados:** o pipeline corre dentro de `mapfile … < <( … )`, e o `set -e`/`pipefail` não apanham falhas de comandos numa *process substitution*. Se o awk falhar, o resultado é igual a "nenhum brute force detetado".
  - **Brute force — ordem do output:** os IPs aparecem por ordem alfabética (a do `sort`), não por ordem cronológica do ataque.

---

## 3. Test Scenarios

*(Incluir casos que **não** devem ser detetados / falsos positivos.)*

### 3.1 Part 1 Test Scenarios
| Scenario | Setup | Expected Result | Observed Result (with evidence) |
| :--- | :--- | :--- | :--- |
| Valid provisioning + idempotency | ... | ... | ... |
| Invalid CSV rows (rejected) | ... | ... | ... |
| Offboarding (`left` vs missing from CSV) | ... | ... | ... |

### 3.2 Part 2 Test Scenarios
| Scenario | Setup | Expected Result | Observed Result (with evidence) |
| :--- | :--- | :--- | :--- |
| First run vs unchanged run | ... | ... | ... |
| Legitimate intern ACL / parent traversal (must NOT trigger) | ... | ... | ... |
| Policy violation & resolution (`NEW` -> `RESOLVED`) | ... | ... | ... |

### 3.3 Part 3 Test Scenarios
| Scenario | Setup | Expected Result | Observed Result (with evidence) |
| :--- | :--- | :--- | :--- |
| Brute force — janela deslizante | `tests/part3/data/bf_sliding_window.txt`: IP `192.0.2.1` com falhas aos 0, 50, 55, 61 e 62s. `./part3/analyze_auth.sh -b 4 -w 1 tests/part3/data/bf_sliding_window.txt` | Detetado: as falhas dos 50 aos 62s são 4 em 12s, embora atravessem o fim da janela que começa aos 0s | `IP: 192.0.2.1`, `Failures: 5` |
| Brute force — falhas espaçadas (must NOT trigger) | Mesmo ficheiro: IP `192.0.2.2` com uma falha a cada 50s (5 falhas) | Não detetado: cada intervalo é < 60s, mas nunca há 4 falhas dentro de 60s | `192.0.2.2` não aparece no output |
| Brute force — menos de N falhas (must NOT trigger) | Mesmo ficheiro: IP `192.0.2.4` com 3 falhas em 2s | Não detetado | `192.0.2.4` não aparece no output |
| Brute force — limite da janela | Mesmo ficheiro: IP `192.0.2.3` com 4 falhas que ocupam exatamente 60s | Detetado (limite inclusivo, `<=`) | `IP: 192.0.2.3`, `Failures: 4` |
| Brute force — `invalid user` intercalado com outro IP | Mesmo ficheiro: IP `198.51.100.9` (`Failed password for invalid user admin`), com falhas no mesmo minuto que as de `192.0.2.1` | Detetado, sem misturar as falhas dos dois IPs | `IP: 198.51.100.9`, `Top usernames: admin(4)` |
| Brute force — atravessa a meia-noite | Mesmo ficheiro: IP `203.0.113.7` com falhas das 23:59:50 às 00:00:10 do dia seguinte | Detetado | `IP: 203.0.113.7`, `Failures: 4` |
| Brute force — logs fornecidos | `./part3/analyze_auth.sh tests/part3/data/auth.log*` (valores por omissão: `-b 10 -w 5`) | IPs com ≥ 10 falhas em 5 min | `203.0.113.118` (70 falhas, `admin(30) git(22) jenkins(14)`) e `203.0.113.45` (587 falhas, `root(362) admin(72) ubuntu(58)`). Resultado igual com `gawk` e `mawk` |
| Brute force — nenhuma deteção | `./part3/analyze_auth.sh -b 1000 tests/part3/data/auth.log*` | Mensagem explícita, sem lista vazia | `No brute force attacks detected.` |
| Username vazio | Logs fornecidos: `Failed password for invalid user  from 192.0.2.236` (dois espaços). `./part3/analyze_auth.sh -b 3 -w 1 tests/part3/data/auth.log*` | Contado como `<empty>`, separado do username real `user` | `192.0.2.236` com `Top usernames: <empty>(3) git(2)` |
| Password spray | ... | ... | ... |
| Normal typo from usual IP (must NOT trigger) | ... | ... | ... |
| Out-of-order `.gz` + plain logs | ... | ... | ... |
| Corrupted `.gz` among valid files | `tests/part3/data/`: `random.txt` (texto aleatório), `valid.gz` (gzip válido), `corrupt.gz` (`valid.gz` cortado a meio). `./part3/analyze_auth.sh tests/part3/data/random.txt tests/part3/data/valid.gz tests/part3/data/corrupt.gz` | `corrupt.gz` ignorado com aviso; os outros dois aceites e a análise continua | `Warning: compressed file is corrupted, skipping: tests/part3/data/corrupt.gz`; a execução continua com os outros dois ficheiros (análise ainda por implementar) |
| Valid text + valid `.gz` (must NOT warn) | Os mesmos `random.txt` e `valid.gz`. `./part3/analyze_auth.sh tests/part3/data/random.txt tests/part3/data/valid.gz` | Nenhum aviso; os dois ficheiros aceites | Nenhum aviso; a execução continua com os dois ficheiros (análise ainda por implementar) |

---

## 4. Incident Report (Part 3)

*(1 a 2 páginas: o que aconteceu e quando, o que o atacante fez, que contas e dados foram afetados, o que o `audit.sh` da Parte 2 teria reportado na manhã seguinte, o que deve ser feito agora e o que o teria prevenido.)*

---

## 5. Where the AI Was Wrong and How We Verified (Mandatory)

*(Explicar que ferramentas de IA foram usadas e para quê, pelo menos **3 casos concretos** de `docs/ai_mistakes.md`, e como verificaram código que não escreveram manualmente.)*
