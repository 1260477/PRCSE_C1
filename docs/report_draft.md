# PRCSE — Challenge 1 Report (Group 6)

> **Limite:** Máximo 20 páginas + anexos (exportar para `report.pdf` na raiz do `.zip`).

---

## 1. Team

| Name | Student Number | Responsibilities |
| :--- | :--- | :--- |
| Hugo Filipe Correia Costeira | *(Número)* | Part 1 (`provision.sh`), Part 1 tests, Approach & Test Scenarios (Part 1), AI Case 1 |
| José Paulo Ferreira De Sousa | 1241915 | Part 2 (`audit.sh`, `audit.cron`), Part 2 tests, Approach & Test Scenarios (Part 2), AI Case 2 |
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
| Valid provisioning + idempotency | ... | ... | ... |
| Invalid CSV rows (rejected) | ... | ... | ... |
| Offboarding (`left` vs missing from CSV) | ... | ... | ... |

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
