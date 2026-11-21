# Registo de Erros da IA e Verificação (Obrigatório no Relatório)

Regra do enunciado:
> Pelo menos **3 casos concretos**: o que pediram, o que a IA produziu (excerto curto), porque estava errado/inseguro/incompleto, como descobriram (teste, `man`, documentação), e o que alteraram.

*(Cada membro do grupo deve registar aqui pelo menos 1 caso real durante o desenvolvimento.)*

---

## Caso 1 — [Parte X] Título curto do problema
- **Ferramenta de IA usada:** *(ex: Antigravity / ChatGPT / etc.)*
- **O que foi pedido:** 
- **Excerto do que a IA produziu:**
  ```bash
  # colar aqui apenas as linhas relevantes
  ```
- **Porque estava errado / inseguro / incompleto:** 
- **Como descobrimos (teste, `man`, docs):** 
- **O que alterámos:** 

---

## Caso 2 — Parte 2 · Escrita individual omitida na auditoria de ACL

**Ferramenta e pedido.** Usámos o ChatGPT para desenvolver a verificação das ACL das pastas, incluindo a exceção de leitura dos estagiários.

**Excerto proposto.** O ciclo de deteção de entradas adicionais só atribuía significado às entradas nomeadas de grupo:
```bash
if [[ "$line" =~ ^(default:)?group:[^:]+:[rwx-]{3}$ ]]; then
```

**Falha e verificação.** Numa pasta temporária com máscara rwx, o teste atribuiu user:nobody:rwx. Esperávamos um alerta POLICY, mas a função produziu saída vazia. O diff identificou a linha em falta e a bateria devolveu 1, apesar de os 36 testes anteriores passarem (fig. 28).

**Correção e resultado.** Acrescentámos uma verificação de escrita para entradas individuais nomeadas, tanto de acesso como por omissão. Repetimos o teste original, acrescentámos o caso por omissão e um controlo com ambas as permissões em r-x. Os 39 testes passaram com código 0 (fig. 29).

---

## Caso 3 — [Parte X] Título curto do problema
- **Ferramenta de IA usada:** 
- **O que foi pedido:** 
- **Excerto do que a IA produziu:**
  ```bash
  ```
- **Porque estava errado / inseguro / incompleto:** 
- **Como descobrimos (teste, `man`, docs):** 
- **O que alterámos:** 
