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

## 3. Notas dos Ficheiros de Entrada (preencher no Passo 6)

- Formato de `employees.csv` / `employees_v2.csv`: *(a preencher)*
- Formato de `access-policy.csv`: *(a preencher)*
- Formato dos timestamps e linhas de `logs/auth.log*`: *(a preencher)*
