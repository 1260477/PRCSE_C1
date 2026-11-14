# Fluxo de Git para o Grupo 6 (3 pessoas)

## Branches
- `main`: código estável e testado.
- `feat/part1`: desenvolvimento da Parte 1 (`provision.sh` + `tests/part1/`).
- `feat/part2`: desenvolvimento da Parte 2 (`audit.sh`, `audit.cron` + `tests/part2/`).
- `feat/part3`: desenvolvimento da Parte 3 (`analyze_auth.sh` + `tests/part3/`).

## Comandos do dia a dia

1. **Começar a trabalhar na tua parte (1.ª vez):**
   ```bash
   git pull origin main
   git checkout -b feat/part1   # ou part2 / part3
   ```

2. **Guardar e enviar alterações:**
   ```bash
   git add part1/ tests/part1/
   git commit -m "part1: description of change"
   git push -u origin feat/part1
   ```

3. **Juntar à `main` (quando estiver funcional e testado):**
   ```bash
   git checkout main
   git pull origin main
   git merge feat/part1
   git push origin main
   ```
   *(Ou abrir um Pull Request no GitHub para os colegas reverem.)*

4. **Atualizar a tua branch com novidades da `main`:**
   ```bash
   git checkout feat/part2
   git pull origin main
   ```
