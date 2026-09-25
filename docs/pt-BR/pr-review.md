# Revisão solicitada de PR e diff

O Squad usa a superfície de revisão standalone somente-leitura do Drill para revisões solicitadas de PR/diff e revisões apenas de conhecimento.
Execute `bin/sq-pr-review.sh <pr-number>` para resolver um PR aberto, buscar seus commits base e head exatos e chamar `drill review`.
Para refs locais, use `drill review --base <base> --head <head> [--intent <intent>]` diretamente.
Esta é uma auditoria que retorna findings nativos locais — não é um gate de delivery, aprovação ou caminho de publicação no GitHub.
O delivery continua pelo pipeline completo `git push drill`.

`packages/pr-review` permanece até a tarefa separada de aposentadoria R7.

## Superfície

- `drill review --base <base> --head <head> [--intent <intent>]` revisa refs locais de forma não interativa com o snapshot, lentes de especialistas e consolidador do Drill.
- `bin/sq-pr-review.sh <pr-number>` valida um PR aberto e a autenticação, busca refs imutáveis base/head, invoca o Drill e então verifica que o head remoto permanece inalterado antes de liberar o resultado.
- `drill review --format json` emite identidade do repositório, SHAs revisados e findings nativos; a saída de texto inclui o mesmo resultado estruturado.

## Proteções

- A revisão standalone nunca executa etapas de fix ou delivery e não realiza escritas no GitHub.
- Uma auditoria standalone não pode satisfazer `Require drill` ou aprovar um delivery HEAD.
- Findings são deliverables de revisão locais; publicação externa e merge continuam sendo ações humanas.

## Validação

- Guard do wrapper, verificação de head obsoleto e side-effects rodam em `tests/sq-pr-review-guard.test.sh`.
- Verificações da CLI e do engine compartilhado do Drill estão em `packages/drill/internal/cli` e `packages/drill/internal/pipeline/steps`.
