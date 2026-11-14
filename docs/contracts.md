# Contrato Técnico entre Partes (Group 6)

Este ficheiro alinha as decisões partilhadas entre quem faz a Parte 1, Parte 2 e Parte 3, para que funcionem em conjunto e também passem no segundo conjunto de ficheiros da avaliação.

---

## 1. Parte 1 ↔ Parte 2 (Política, ACLs e Exceções Legítimas)

1. **Fonte única de verdade:**
   - Ambas as partes leem o **mesmo** ficheiro `access-policy.csv` passado por argumento. Nada pode estar hard-coded.
   - Departamentos válidos: toda a pasta de topo `/srv/company/<nome>` presente na política que tenha um grupo com o mesmo `<nome>` (excluindo `public`).
2. **Dono, Grupo e Permissões base das pastas:**
   - Owner: `root`.
   - Group owner: **primeiro grupo** com `rwx` para essa pasta na política.
   - `setgid` ativo nas pastas (`chmod g+s` / `2xxx`) para novos ficheiros herdarem o grupo.
   - Permissão de `others`: `---` (`0`), sem acesso fora das ACLs.
3. **Exceções legítimas que a Parte 1 cria e a Parte 2 NÃO pode marcar como violação:**
   - **Estagiários (`intern`):** quando o seu departamento tem `rwx`, o estagiário recebe ACL individual `u:<username>:r-x` (e default ACL se aplicável) para poder ler mas nunca escrever.
   - **Travessia de pastas-pai:** se um grupo tem acesso a uma subpasta (ex: `/srv/company/a/b`) mas não ao pai (`/srv/company/a`), o pai recebe apenas a permissão mínima de travessia (`--x`) para esse grupo (sem permissão de leitura/listagem `r`).
4. **Regra de `sudo`:**
   - Apenas membros ativos, **não-estagiários**, do departamento `it` podem estar no grupo `sudo`.
   - Parte 2 reporta qualquer membro de `sudo` que não pertença ao grupo `it`.

---

## 2. Parte 2 ↔ Parte 3 (Ligação ao Incidente)

- O que `analyze_auth.sh` (Parte 3) descobrir nos logs de `26–30 Outubro 2026` (ex: contas criadas, alterações de passwords, usos de `sudo`, sessões suspeitas, alterações a ficheiros/permissões) tem de bater certo com o que `audit.sh` (Parte 2) reportaria na manhã seguinte às `06:00`.
- Preencher após a inspeção dos logs (Passo 6).

---

## 3. Notas dos Ficheiros de Entrada (verificado em `C1_files/`)

- **Formato de `employees.csv` e `employees_v2.csv`:**
  - Codificação **UTF-8 com BOM** (`\xef\xbb\xbf` no início da 1.ª linha) e quebras de linha **CRLF (`\r\n`)**. O parser da Parte 1 **tem** de remover BOM e `\r`.
  - Casos de teste reais já presentes nos CSVs: linha em branco, espaços à volta dos campos (` Jorge `, `Staff `), maiúsculas/minúsculas mistas (`Sales`), departamento desconhecido (`logistics`), `employee_id` duplicado (`E1015`), `role` em falta (`E1034`), `intern` sem `end_date` (`E1037`), e em `v2`: mudança de nome (`E1008`), mudança de departamento (`E1004`), mudança de role (`E1013`, `E1017` intern→staff), offboarding (`E1011`, `E1012`), e desaparecimento do CSV sem `left` (`E1030`).
- **Formato de `access-policy.csv`:**
  - ASCII `LF`, 17 linhas (cabeçalho `folder,group,access` + 16 regras).
  - Inclui subpasta `/srv/company/hr/payroll` (onde `finance` tem `r-x`, mas `finance` **não** tem acesso a `/srv/company/hr` — caso de travessia mínima!) e pasta partilhada `/srv/company/public` (não é departamento).
- **Formato de `logs/auth.log*`:**
  - 5 ficheiros (`auth.log`, `auth.log.1`, `auth.log.2.gz` a `auth.log.4.gz`, total ~236 KB).
  - Timestamps ISO 8601 com microssegundos e timezone (ex: `2026-10-30T00:17:01.765742+00:00`), hostname `srv-files01`.
  - Serviços presentes: `CRON`, `passwd`, `sshd`, `sudo`, `systemd-logind`, `useradd`.
