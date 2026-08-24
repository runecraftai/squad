<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Revisão de PR de strike (pr-review mantido)

O Squad mantém o `@runecraft/pr-review` (0.1.0) em `packages/pr-review` e o
liga ao fluxo de strike entre a criação do PR e a decisão de merge do
comandante (seção 7 do AGENTS.md).

## Superfície

- `.pi/extensions/sq-pr-review.ts` — bootstrapper nomeado pelo Squad que registra
  a extensão do pacote mantido na sessão Pi (`/pr-review <n>`, visualizador de
  foco, tabela de findings). O próprio manifesto `pi` do pacote também habilita
  a descoberta automática pelo workspace raiz.
- `bin/sq-pr-review.sh [<número-do-pr>]` — wrapper fino para CI/scripting. Ele
  valida, com mensagens claras de falha (REQ-M3-02 AC3):
  1. `gh` e `git` estão no PATH;
  2. o comando roda dentro de um checkout git;
  3. o PR resolve (número explícito, ou da branch atual) e existe como um PR
     OPEN legível pelo `gh`;
  4. `gh` está autenticado.
  Ele nunca inicia uma revisão por conta própria — a revisão roda na sessão Pi —
  e imprime o comando in-session a ser executado.

## Proteções

- A publicação é somente-COMMENT (padrão do pacote; auto-aprovação desativada).
- A revisão nunca faz merge e nunca aprova; só o comandante decide merges.
  A postura `+yolo` não permite que a revisão se auto-aprove.
- Os findings alimentam a decisão do comandante; são uma entrega de revisão,
  não um override de autoridade.

## Validação

- Os caminhos de proteção do wrapper têm checagem unitária em
  `tests/sq-pr-review-guard.test.sh`
  (sem repo / sem PR / sem auth gh / PR fechado → falhas claras, exit 1).
- Uma execução documentada ao vivo contra um repo de rascunho é a A-08
  (manual, não é gate de CI): rode `/pr-review <n>` em uma sessão Pi em um PR
  de teste e confirme a tabela de findings somente-COMMENT.
