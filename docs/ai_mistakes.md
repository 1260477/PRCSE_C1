# Registo de Erros da IA e Verificação (Obrigatório no Relatório)

Regra do enunciado:
> Pelo menos **3 casos concretos**: o que pediram, o que a IA produziu (excerto curto), porque estava errado/inseguro/incompleto, como descobriram (teste, `man`, documentação), e o que alteraram.

*(Cada membro do grupo deve registar aqui pelo menos 1 caso real durante o desenvolvimento.)*

---

## Caso 1 — [Parte 3] Top usernames do brute force muda com a implementação de awk
- **Ferramenta de IA usada:** Claude Code (Claude Opus 5.5)
- **O que foi pedido:** mostrar, para cada IP com brute force (3.2), os 3 usernames mais tentados com o número de tentativas (pressuposto 7, por exemplo `root(362) admin(72) ubuntu(58)`). O script tem de dar o mesmo resultado com `gawk` e com `mawk` (o awk por omissão no Ubuntu).
- **Excerto do que a IA produziu** (`detect_brute_force`, commit `4a9f529`):
  ```awk
  for (u in users)
      if (best == "" || users[u] > users[best])
          best = u
  ```
- **Porque estava errado / inseguro / incompleto:** a ordem de `for (u in users)` não está definida em awk (POSIX deixa-a à implementação), e o `>` estrito fica com o **primeiro** username que encontra com o valor máximo. Quando há empates, o username escolhido depende da ordem interna do array, que é diferente em `gawk` e em `mawk`. O resultado deixa de ser determinístico: o mesmo log dá tops diferentes conforme a máquina. A própria IA tinha tratado este problema na 3.5 (os tops ordenam com `sort` e desempatam pelo IP/username, "para o resultado ser sempre o mesmo em qualquer awk"), mas não o aplicou aqui.
- **Como descobrimos (teste, `man`, docs):** ao implementar a timeline (3.6), comparámos o output do `gawk` com o do `mawk` para cada ficheiro de teste, em vez de comparar só a versão antiga com a nova no mesmo awk, como nas regressões anteriores. Em `tests/part3/data/spray_test.txt` o top do IP `192.0.2.20` (5 usernames com 4 falhas cada) deu `u4(4) u5(4) u1(4)` no `gawk` e `u2(4) u3(4) u4(4)` no `mawk`. No IP `192.0.2.40` aconteceu o mesmo (`d1 d2 d3` vs `d3 d4 d2`). Confirmámos com o commit anterior que o problema já existia antes da timeline. Nos logs fornecidos não aparece, porque lá não há empates no top 3 — por isso os testes "resultado igual com `gawk` e `mawk`" com esses logs não o apanharam.
- **O que alterámos:** desempatar pelo username (ordem alfabética), para a escolha não depender da ordem do array:
  ```awk
  if (best == "" || users[u] > users[best] || (users[u] == users[best] && u < best))
  ```
  Depois da correção, o top dos dois IPs passou a ser `u1(4) u2(4) u3(4)` e `d1(3) d2(3) d3(3)` nos dois awk, e o output de 10 cenários (todos os ficheiros de teste e os logs fornecidos com várias opções, incluindo `-b 1 -w 60`, com muitos empates) ficou igual entre `gawk` e `mawk`. As regressões passaram a incluir esta comparação entre os dois awk. O pressuposto 7 do relatório, que dizia que a ordem nos empates "não é garantida", foi atualizado.

---

## Caso 2 — [Parte X] Título curto do problema
- **Ferramenta de IA usada:** 
- **O que foi pedido:** 
- **Excerto do que a IA produziu:**
  ```bash
  ```
- **Porque estava errado / inseguro / incompleto:** 
- **Como descobrimos (teste, `man`, docs):** 
- **O que alterámos:** 

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
