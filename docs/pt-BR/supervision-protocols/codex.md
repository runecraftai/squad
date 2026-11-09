<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

Modo: checkpoint em primeiro plano do Codex.

Quando esta sessão é dona da supervisão e o modo ausente não está ativo:
1. Drene primeiro com `bin/sq-stand-to-drain.sh`.
2. Primeiro ciclo: rode um checkpoint de sentinela em primeiro plano com `bin/sq-sentry-checkpoint.sh --seconds "${SQUAD_CODEX_WATCH_CHECKPOINT:-180}"`.
3. Acordo comum: se o comando imprimir `signal:`, `stale:`, `check:` ou `heartbeat`, drene os acordos na fila, trate aquele acordo e inicie o próximo checkpoint.
4. Se o comando imprimir `checkpoint:` ou sair com código 124 sem acordo, drene os acordos na fila mesmo assim, processe qualquer mensagem do usuário na fila agora visível ao Codex, e inicie o próximo checkpoint.
5. Nunca use shell `&` ou tarefas em segundo plano do Codex para a supervisão de sentinela do Squad.
6. Não rode `bin/sq-sentry-arm.sh` como comando normal de supervisão do Codex.
   Se por acaso for executado via shell, um anti-padrão em segundo plano, com pipe ou empacotado é negado automaticamente pelo cinto PreToolUse (`bin/sq-arm-pretool-check.sh`) registrado no `.codex/hooks.json`.
7. Apenas em caso de falha ou ciclo ausente: drene os acordos na fila, inspecione a falha e inicie um novo checkpoint em primeiro plano.

O Codex não consegue raciocinar enquanto uma chamada de ferramenta em primeiro plano está rodando.
O checkpoint limitado devolve o controle regularmente para que mensagens do usuário e acordos na fila possam ser tratados sem depender da semântica de acordar de tarefas em segundo plano.
