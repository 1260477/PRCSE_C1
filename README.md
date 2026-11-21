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

From the repository root, set `policy` to the supplied CSV (the example uses the VM home directory). Install the audit script, policy and daily 06:00 root cron job:

```bash
policy="$HOME/access-policy.csv"
sudo install -o root -g root -m 0755 part2/audit.sh /usr/local/sbin/audit.sh
sudo mkdir -p /etc/srv-files01
sudo install -o root -g root -m 0644 "$policy" /etc/srv-files01/access-policy.csv
sudo install -o root -g root -m 0644 part2/audit.cron /etc/cron.d/audit
```

Run the tests as a normal user on Ubuntu with the acl tools installed. Run the installed audit as root:

```bash
bash tests/part2/test_audit_checks.sh
sudo /usr/local/sbin/audit.sh --policy /etc/srv-files01/access-policy.csv
```

Daily reports are stored in `/var/log/audit/YYYY-MM-DD.txt` and state in `/var/lib/audit/state`. Override the directories with `--report-dir DIR` and `--state-dir DIR`. Use `--full` to print all current findings. Exit codes are 0 for a successful run without new findings (or a successful full listing), 1 for an error and 2 for new findings. Consult errors with `sudo journalctl -t prcse-audit`. The scripts use Bash, GNU userland, getfacl/setfacl (acl), flock/logger (util-linux) and cron for scheduling.

### Part 3 — Auth Log Analysis
```bash
./part3/analyze_auth.sh [-b N] [-w MIN] [-s N] [-f N] [-t N] <auth.log...>
```
