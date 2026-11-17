# Plano de Implementação — Parte 1 (`provision.sh`)

> [!IMPORTANT]
> **Método de Trabalho Obrigatório (em cada passo):**
> 1. **Explicação do requisito:** O assistente explica o que o enunciado (`C1.pdf` + `contracts.md`) pede para este passo — **sem escrever código**.
> 2. **A tua explicação:** Tu explicas o que entendes que é preciso fazer.
> 3. **Análise crítica:** O assistente verifica criticamente a tua explicação (nunca assume que está tudo certo), valida o que está correto e aponta erros, omissões ou armadilhas.
> 4. **Desenvolvimento:** Tu tentas implementar o passo (ou pedes ajuda/código ao assistente quando quiseres). **Usar sempre sintaxe Bash simples e legível, com comentários claros no código** (evitar expansões crípticas, já que tens de conseguir explicar cada linha na defesa).
> 5. **Resumo e Enquadramento (`C1.pdf`):** O assistente explica o que foi feito no passo e verifica no `C1.pdf` se exige registo no `README.md`, `report.pdf` ou testes em `tests/part1/`.
> 6. **Fecho de Fase:** Sempre que uma fase termina, atualizar o [part1_study_guide.md](file:///home/hcosteira/Documents/C1/Resolucao/docs/part1_study_guide.md) com as decisões, soluções e sintaxe explicada, e criar/correr os respetivos testes automatizados em `tests/part1/`.

> [!NOTE]
> Este documento serve como **painel de estado vivo** da Parte 1. À medida que cada item for implementado e verificado, a respetiva caixa será marcada (`[x]`), permitindo-te consultar a qualquer momento o que já está feito e o que falta face ao enunciado (`C1.pdf`) e ao contrato (`docs/contracts.md`).

---

## Fase 0 — Estrutura Base, CLI e Segurança (Secções 3 e 1.4)
- [x] **0.1** Confirmar branch `feat/part1` e disponibilidade de ferramentas (`bash`, `awk`, `sed`, `iconv`, `chage`, `useradd`, `setfacl`, `getfacl`).
- [x] **0.2** Implementar parsing de argumentos: `-h`/`--help`, `--dry-run`, `<employees.csv>` e `<access-policy.csv>` (rejeitar argumentos inválidos com `exit 1`).
- [x] **0.3** Validar privilégios (`root`) quando necessário e existência/legibilidade dos ficheiros de entrada (`exit 1` sem alterar nada).
- [x] **0.4** Validar cabeçalhos exatos dos dois CSVs (após remover BOM/CRLF): `employee_id,first_name,last_name,department,role,status,end_date` e `folder,group,access` (`exit 1` se inválido).
- [x] **0.5** Implementar sistema de logging e `--dry-run`: cada alteração é impressa numa linha e registada com data/hora em `/var/log/provision.log` (em `--dry-run` apenas imprime o que faria).
- [x] **0.6** Garantir códigos de saída: `0` (tudo aplicado), `1` (erro fatal, nada alterado), `2` (terminou, mas houve linhas rejeitadas).

---

## Fase 1 — Leitura, Limpeza e Validação dos CSVs (Secção 1.1)
- [x] **1.1** Ler `access-policy.csv`, normalizar quebras de linha, ignorar linhas em branco, validar formato `folder,group,access` (`rwx` ou `r-x`).
- [x] **1.2** Extrair departamentos válidos dinamicamente da política: pastas de topo `/srv/company/<nome>` que tenham regra para o grupo `<nome>` (excluindo `public`).
- [x] **1.3** Ler `employees.csv`: remover UTF-8 BOM (`\xef\xbb\xbf`), converter CRLF (`\r\n`) para LF, ignorar linhas em branco, fazer trim aos campos e tratar `department`, `role` e `status` sem distinção entre maiúsculas/minúsculas.
- [x] **1.4** Validar cada linha e rejeitar (imprimindo nº de linha + motivo, continuando para a próxima e marcando `exit 2`):
  - [x] Campo obrigatório em falta (`employee_id`, `first_name`, `last_name`, `department`, `role`, `status`).
  - [x] `department` não pertence aos departamentos válidos da política.
  - [x] `role` inválido (apenas `staff`, `manager`, `intern`).
  - [x] `status` inválido (apenas `active`, `left`).
  - [x] `employee_id` duplicado numa linha anterior (manter o primeiro).
  - [x] `intern` sem `end_date` válido (`YYYY-MM-DD`).
- [x] **1.5** Gerar username: `1.ª letra de first_name` + `última palavra de last_name`, minúsculas, sem acentos (`iconv`), apenas `a-z`.
- [x] **1.6** Resolver colisões (`2`, `3`, …) por ordem do ficheiro contra contas do sistema e um registo persistente de usernames já atribuídos (nunca reutilizar um username mesmo após offboarding).
- [x] **1.7** Reconhecer utilizadores existentes pelo `employee_id` no campo GECOS/comment `First Last (E1001)` (se o nome mudar, atualiza o comment mas mantém o username).

---

## Fase 2 — Contas de Utilizador e Grupos (Secção 1.2)
- [x] **2.1** Criar grupos em falta: 1 por departamento + `employees` + `managers`.
- [x] **2.2** Criar novas contas com home `/home/<username>` (`0700`), shell `/bin/bash` e comment `First Last (ID)`.
- [x] **2.3** Gerar password aleatória (≥ 16 caracteres) para novas contas, guardar em `/root/initial-passwords.txt` (permissões `0600` só `root`), nunca imprimir no ecrã/log, e forçar troca no 1.º login (`chage -d 0`).
- [x] **2.4** Aplicar regra de expiração de password: 180 dias, aviso 14 dias antes (`chage -M 180 -W 14`).
- [x] **2.5** Aplicar expiração de conta para `intern` (`chage -E <end_date>`) e remover expiração se passar a `staff`/`manager` (`chage -E -1`).
- [x] **2.6** Sincronizar pertença exata a grupos (departamento atual + `employees` + `managers` se `manager`), adicionando novos e removendo antigos quando muda departamento/role.
- [x] **2.7** Aplicar regra `sudo`: apenas membros `active` não-intern do departamento `it` pertencem a `sudo` (remover qualquer outro).

---

## Fase 3 — Offboarding e Desaparecimentos (Secção 1.5)
- [x] **3.1** Para `status = left` sem conta Linux existente: não fazer nada.
- [x] **3.2** Para `status = left` com conta existente:
  - [x] Bloquear conta e terminar sessões/processos ativos do utilizador.
  - [x] Arquivar home em `/srv/archive/<username>_<employee_id>_<YYYY-MM-DD>.tar.gz` (só `root` lê) e verificar integridade do `.tar.gz` antes de apagar qualquer ficheiro.
  - [x] Mudar dono dos ficheiros do utilizador em `/srv/company` para `root` (mantendo o grupo).
  - [x] Remover crontab, conta e pasta home.
- [x] **3.3** Detetar utilizadores geridos (com `(E...)` no comment) que desapareceram do CSV sem `status = left`: **não remover**, apenas imprimir aviso.

---

## Fase 4 — Pastas Partilhadas e ACLs (Secção 1.3)
- [ ] **4.1** Criar todas as pastas definidas em `access-policy.csv` (owner `root`, group owner = primeiro grupo com `rwx`, `setgid` ativo `g+s`, `others` sem acesso `---`).
- [ ] **4.2** Aplicar ACLs exatas da política e *default ACLs* para herança de novos ficheiros/subpastas.
- [ ] **4.3** Aplicar travessia mínima (`--x`) em pastas-pai quando um grupo tem acesso a uma subpasta mas não ao pai (sem permitir listar o pai).
- [ ] **4.4** Aplicar exceção de estagiários (`intern`): onde o seu departamento tem `rwx`, atribuir ACL individual `r-x` (e default ACL `r-x`).
- [ ] **4.5** Garantir que ficheiros e subpastas **já existentes** dentro das pastas também seguem a política após a execução.
- [ ] **4.6** Garantir idempotência nas pastas/ACLs (só alterar e registar log quando houver diferença real).

---

## Fase 5 — Testes e Validação (em `tests/part1/`)
- [ ] **5.1** Criar testes unitários/automatizados em `tests/part1/` para parsing e validação (BOM, CRLF, espaços, acentos, colisões, duplicados, `intern` sem data, departamento desconhecido).
- [ ] **5.2** Testar `--dry-run` com `employees.csv` + `access-policy.csv` (confirmar exit code `2` e zero alterações no sistema).
- [ ] **5.3** *(Após confirmar snapshot da VM)* Testar execução real com `employees.csv` e verificar utilizadores, grupos, `chage`, `sudo`, passwords e ACLs.
- [ ] **5.4** Testar **idempotência**: correr 2.ª vez com `employees.csv` e confirmar zero alterações + mensagem respetiva.
- [ ] **5.5** Testar `employees_v2.csv`: mudança de nome (`E1008`), mudança de departamento (`E1004`), mudança de role (`E1013`, `E1017`), offboarding (`E1011`, `E1012`) e aviso de desaparecimento (`E1030`).
- [ ] **5.6** Testar com um **2.º conjunto sintético** de ficheiros (outros nomes, departamentos e pastas) para comprovar ausência de hard-coding.
