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
- **Log ingestion, decompression & chronological sorting:** ...
- **Ficheiro temporário seguro:** os eventos preparados ficam num ficheiro temporário criado com `mktemp` e não num caminho fixo como `/tmp/analyze_auth.txt`. Razões:
  - o nome é único e aleatório, e o ficheiro é criado de forma atómica, o que evita ataques por symlink e colisões entre execuções em paralelo;
  - as permissões são `600`, por isso os usernames e IPs dos logs não ficam legíveis por outros utilizadores;
  - respeita a variável `$TMPDIR`.

  O ficheiro é apagado com `trap ... EXIT`, mesmo quando o script termina com erro ou é interrompido.
- **Detection logic (brute force, password spray, success after failures, top active):** ...
- **Performance (<30s on VM):** ...
- **Known limitations:** ...

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
| Brute force & password spray | ... | ... | ... |
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
