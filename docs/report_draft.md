# PRCSE — Challenge 1 Report (Group 6)

> **Limite:** Máximo 20 páginas + anexos (exportar para `report.pdf` na raiz do `.zip`).

---

## 1. Team

| Name | Student Number | Responsibilities |
| :--- | :--- | :--- |
| *(Nome 1)* | *(Número)* | Part 1 (`provision.sh`), Part 1 tests, ... |
| *(Nome 2)* | *(Número)* | Part 2 (`audit.sh`, `audit.cron`), Part 2 tests, ... |
| *(Nome 3)* | *(Número)* | Part 3 (`analyze_auth.sh`), Incident Report, Part 3 tests, ... |

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

---

## 4. Incident Report (Part 3)

*(1 a 2 páginas: o que aconteceu e quando, o que o atacante fez, que contas e dados foram afetados, o que o `audit.sh` da Parte 2 teria reportado na manhã seguinte, o que deve ser feito agora e o que o teria prevenido.)*

---

## 5. Where the AI Was Wrong and How We Verified (Mandatory)

*(Explicar que ferramentas de IA foram usadas e para quê, pelo menos **3 casos concretos** de `docs/ai_mistakes.md`, e como verificaram código que não escreveram manualmente.)*
