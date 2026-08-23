<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Mecanismo de ciclo de vida de decision hold

A política normativa é de propriedade de `.agents/skills/decision-hold-lifecycle/SKILL.md` e não é repetida aqui.
Este documento registra o mecanismo determinístico, superfícies estruturadas e evidência de regressão segura para privacidade.

## Mecanismo

`bin/sq-decision-hold.sh` é o único comando de ciclo de vida para as decisões do comandante não resolvidas de uma investigação ou revisão visual.
O comando roda sq-tasks no `SQUAD_BASE` ativo, então o backlog existente continua sendo o único banco de dados durável de trabalho e uma decisão de propriedade do XO fica na base XO.
Ele nunca lê corpos de relatório, artefatos de revisão, saída de terminal ou chat.

O subcomando `hold` mapeia um id de trabalho de origem e chave estável de decisão para `<origin-id>-decision-<decision-key>`.
Ele cria um item de backlog kind `commander` quando ausente e invoca `sq-tasks hold <id> --reason <motivo> --kind commander` em toda nova tentativa.
Ele rejeita colisão de identidade, título alterado e tentativas de reabrir uma identidade já resolvida.

O subcomando `complete` une as chaves revisadas em `decision_keys=` e appenda `decisions_reviewed=1` enquanto os metadados da tarefa de origem estão vivos.
Uma revisão visual pós-teardown pode completar contra o relatório sobrevivente e holds duráveis sem recriar metadados voláteis de tarefa.
Ele aceita `--none` como resultado explícito semântico de inventário, não como ausência inferida.
Ele verifica cada identidade listada contra o sq-tasks antes de registrar a conclusão.
Para uma decisão aberta chaveada de status, ele appenda um evento de transferência `commander-held [key=<chave>]: ...` apenas depois que o hold correspondente no backlog é durável.
`bin/sq-classify-lib.sh` reconhece aquela transferência como fechamento da cópia viva de status sem afirmar que o comandante já respondeu.

O teardown de recon chama o subcomando read-only `verify` do script depois de conferir o relatório e antes de remover qualquer estado fonte.
O caminho `--force` permanece a válvula de escape explícita de descarte aprovada pelo comandante.

O subcomando `resolve` exige um arquivo de decisão e pelo menos uma tarefa dependente existente cuja aresta estruturada `blocked-by` aponte para o hold.
Ele registra o digest da decisão e as identidades das tarefas roteadas como identidade de retry no corpo do hold, limpa cada aresta de dependência via sq-tasks, e marca o hold Done apenas depois que essas escritas têm sucesso.
Um retry exato pode terminar uma operação parcial de roteamento, enquanto uma decisão ou conjunto de tarefas roteadas alterado é rejeitado.
Um passo intermediário falho deixa o hold aberto.

## Superfícies estruturadas de leitura

`bin/sq-unit-snapshot.sh` parseia metadados canônicos `(hold: ...)` e `(hold-kind: commander)` do sq-tasks junto dos campos existentes do backlog.
Ele resolve toda aresta repetida `blocked-by:` contra registros estruturados Done, mantém blockers ausentes não resolvidos, e classifica como acionável apenas um hold commander desbloqueado.
Seu sumário de base XO classifica um hold commander acionável como `commander_decision` e preserva holds commander bloqueados como trabalho enfileirado na base dona.

`bin/sq-sitrep-snapshot.sh` projeta holds commander acionáveis em `decisions_open` e deixa holds commander bloqueados nos gates ordinários de fila.
Ele exclui registros kind `commander` completados de Recently Landed.
A projeção permanece read-only e não inspeciona prosa histórica.

## Registro de verificação

Data de verificação: 2026-07-14.
Data adicional de verificação da regressão de `blocked_by` citado: 2026-07-17.
Datas de verificação de plural blocker-readiness e projeção mixed-base: 2026-07-22.

A regressão end-to-end focada usa apenas identidades sintéticas `sample` e texto de decisão sintético.
Ela começa com uma investigação e revisão visual completadas cuja escolha genuinamente não resolvida existe apenas no relatório.
O snapshot Sitrep inicial corretamente não tem decisão aberta, e o novo gate de teardown recusa apagar a fonte.
Uma regressão posterior cobre a saída multi-entrada citada `blocked_by` do sq-tasks para que `resolve` case com os ids primeiro, meio e último e rejeite um id genuinamente ausente.

Os comandos finais de verificação e seus outputs resumidos exatos seguem.

```text
$ bash tests/sq-decision-hold-lifecycle.test.sh
ok - report-only unresolved decision is reproduced and completion refuses before loss
ok - non-forced recon teardown always requires durable inventory verification
ok - commander holds are idempotent, distinct, teardown-safe, Sitrep-visible, and durably routed before close
ok - completion and verification validate origins before constructing paths
ok - ended visual review follows the same decision-hold completion owner
ok - resolved findings and decision-like prose do not create false holds
ok - terminal single-owner stale status decisions do not block empty inventory
ok - main-home and XO-home commander holds remain correctly routed
ok - resolve matches first/middle/last in quoted blocked_by and rejects a genuinely absent id

$ bash tests/sq-unit-snapshot-view.test.sh
ok - backlog normalization preserves strict roles and resolves every blocker compatibly
ok - durable commander-held transfer closes the duplicate live status decision
ok - snapshot parses sq-tasks rows and respects operational overrides

$ bash tests/sq-sitrep-snapshot.test.sh
ok - a completed recon with decision-like report prose is a pointer, not pending
ok - action-free items (working/done/queued/landed) do not leak into Commander's Call
ok - mixed XO roles, partial state, and commander readiness project independently
ok - main and XO commander actionability use the same blocker readiness

$ bash tests/sq-brief.test.sh
ok - sq-brief.sh: investigation and visual-review completions load the shared decision policy

$ bash tests/sq-teardown.test.sh
all teardown safety cases passed

$ bin/sq-lint.sh
sq-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ git diff --check
(no output)

$ for test_script in tests/*.test.sh; do bash "$test_script"; done
ALL 71 TEST SCRIPTS PASSED
```
