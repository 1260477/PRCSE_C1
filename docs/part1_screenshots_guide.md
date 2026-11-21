# Guia Rápido para Tirar os Prints da Parte 1 (na VM)

Este guia tem os comandos exatos, por ordem, para voltares ao snapshot limpo amanhã e tirares todos os *screenshots* necessários para o relatório (`report.pdf`) e apresentação (`presentation.pptx`).

---

## 0. Preparação (antes de correr qualquer comando)

1. No VirtualBox, garante que a VM está **desligada** (ou fecha-a guardando o estado), vai a **Instantâneos** (*Snapshots*), seleciona o snapshot limpo que tiraste antes da Parte 1 e clica em **Restaurar** (*Restore*).
2. Inicia a VM e abre o terminal na pasta do projeto:
   ```bash
   cd /home/hcosteira/Documents/C1/Resolucao
   ```
   *(Se restauraste um snapshot anterior aos últimos commits, faz `git pull` primeiro para teres os testes e ficheiros atualizados.)*

---

## Print 1 — Bateria de Testes Automatizados (`tests/part1/`)

Mostra que os 90 testes unitários / `--dry-run` (incluindo o 2.º conjunto sintético) passam todos:

```bash
for t in tests/part1/test_phase*.sh; do echo "=== $(basename "$t") ==="; bash "$t" | tail -n 3; done
```

**O que apanhar no print:** o resumo final de cada fase (`Passou: ... | Falhou: 0`).

---

## Print 2 — 1.ª Execução Real (`employees.csv`) e Ficheiros Gerados

Corre o script com `employees.csv` e `access-policy.csv`:

```bash
sudo ./part1/provision.sh /home/hcosteira/Documents/C1/C1_files/employees.csv /home/hcosteira/Documents/C1/C1_files/access-policy.csv
echo "EXIT_CODE=$?"
```

**O que apanhar no print:**
- As 4 linhas rejeitadas (`Warning: Line 34/35/36/40 ...`) + criação de grupos/contas/pastas + `EXIT_CODE=2` no fim.

De seguida, corre as verificações de segurança e contas:

```bash
sudo ls -la /root/initial-passwords.txt /var/log/provision.log /var/lib/provision/usernames.txt
sudo wc -l /root/initial-passwords.txt
getent group sudo
sudo chage -l dmoreira
sudo chage -l jpereira
```

**O que apanhar no print:**
- Permissões `0600` (`-rw-------`) de `/root/initial-passwords.txt` (33 linhas) e `usernames.txt`.
- Grupo `sudo` apenas com `hcosteira,jpereira,tmartins,hferreira`.
- `chage -l` de `dmoreira` (`Account expires: Jan 31, 2027`, max `180`, warn `14`) e `jpereira` (`never`).

---

## Print 3 — ACLs, `setgid`, Travessia `--x` e Exceção de `intern`

```bash
sudo getfacl /srv/company/hr /srv/company/hr/payroll
```

**O que apanhar no print:**
- Em `hr`: `flags: -s-`, `user:fmarques:r-x` (acesso e default), `group:finance:--x` (apenas na ACL de acesso, **não** na default) e `other::---`.
- Em `hr/payroll`: `group:hr:rwx`, `group:finance:r-x`, `user:fmarques:r-x` e `other::---`.

---

## Print 4 — Idempotência Real (2.ª Execução com `employees.csv`)

```bash
sudo ./part1/provision.sh /home/hcosteira/Documents/C1/C1_files/employees.csv /home/hcosteira/Documents/C1/C1_files/access-policy.csv
echo "EXIT_CODE=$?"
```

**O que apanhar no print:** os 4 avisos de linhas rejeitadas seguidos de **`No changes needed (already up to date).`** e `EXIT_CODE=2`.

---

## Print 5 — Atualização e Offboarding (`employees_v2.csv`)

```bash
sudo ./part1/provision.sh /home/hcosteira/Documents/C1/C1_files/employees_v2.csv /home/hcosteira/Documents/C1/C1_files/access-policy.csv
echo "EXIT_CODE=$?"
```

Logo a seguir, corre:

```bash
getent passwd mlopes tcoelho slima pramos
getent group sudo managers
sudo chage -l dmoreira | grep "Account expires"
sudo ls -la /srv/archive/
```

**O que apanhar no print:**
- Atualização de GECOS (`mlopes`), mudança de departamento e remoção de `sudo` (`tmartins`), promoção a `managers` (`crocha`), remoção de expiração (`dmoreira`), offboarding (`slima` e `pramos` removidos de `passwd` com `.tar.gz` `0600` em `/srv/archive/`) e aviso de `tcoelho` (`E1030`, mantido em `passwd`).

---

## Print 6 — Integração com a Parte 2 (`audit.sh`)

```bash
sudo ./part2/audit.sh --policy /home/hcosteira/Documents/C1/C1_files/access-policy.csv --report-dir /tmp/audit_check --state-dir /tmp/audit_state --full
echo "EXIT_CODE=$?"
```

**O que apanhar no print:** `EXIT_CODE=0` sem nenhum alerta `[POLICY]` nas pastas/ACLs criadas pela Parte 1.

---

## Limpeza final na VM (opcional)

```bash
sudo rm -rf /tmp/audit_check /tmp/audit_state
```
