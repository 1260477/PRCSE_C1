# PRCSE — Challenge 1 (Group 6)

Managing and Auditing a Company Linux Server (`srv-files01`).

## Environment & Prerequisites

- **OS:** Ubuntu Server 26.04 LTS
- **Shell:** Bash (standard Ubuntu tools)
- **Required packages:**
  ```bash
  sudo apt update
  sudo apt install -y acl
  ```
  *(Adicionar aqui quaisquer outros pacotes usados durante o desenvolvimento.)*

## Project Structure

- `part1/provision.sh` — User, group, shared folder, ACL provisioning, and offboarding.
- `part2/audit.sh` & `part2/audit.cron` — Daily security audit script and `/etc/cron.d/` job.
- `part3/analyze_auth.sh` & `part3/output.txt` — Authentication log analyzer and generated output.
- `pls/` — PL1 and PL2 deliverables.
- `tests/` — Test scripts and test data.

## Usage

### Part 1 — Provisioning
```bash
sudo ./part1/provision.sh [--dry-run] <employees.csv> <access-policy.csv>
```

### Part 2 — Daily Security Audit
Install the script, policy, and cron job:
```bash
sudo install -m 0700 part2/audit.sh /usr/local/sbin/audit.sh
sudo mkdir -p /etc/srv-files01
sudo cp <access-policy.csv> /etc/srv-files01/access-policy.csv
sudo install -m 0644 part2/audit.cron /etc/cron.d/audit
```
Run manually:
```bash
sudo ./part2/audit.sh --policy <access-policy.csv> [--full] [--state-dir DIR] [--report-dir DIR]
```

### Part 3 — Auth Log Analysis
```bash
./part3/analyze_auth.sh [-b N] [-w MIN] [-s N] [-f N] [-t N] <auth.log...>
```
