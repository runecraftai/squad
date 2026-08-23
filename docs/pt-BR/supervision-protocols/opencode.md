<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

Modo: acordo em segundo plano pelo plugin TUI do OpenCode.

Quando esta sessão é dona da supervisão e o modo ausente não está ativo:
1. Drene primeiro com `bin/sq-stand-to-drain.sh`.
2. Primeiro ciclo: deixe `.opencode/plugins/sq-primary-sentry-arm.js` armar a supervisão depois que a sessão OpenCode ficar ociosa.
3. O plugin escuta `session.idle`, lança `bin/sq-sentry-arm.sh --restart` sem esperar por ele no handler de idle, e é dono de todo lançamento sucessor posterior.
4. Depois de um fechamento acionável de processo filho, o plugin reconfere a posse do lock de sessão e verifica um único sucessor antes de chamar `client.session.promptAsync`; seu fallback limitado está definido em `docs/sentry-continuity.md`.
5. Acordo comum: não peça ao modelo para rearmar porque a continuidade é propriedade do plugin.
6. Um fechamento inesperado do filho entra em retry exponencial limitado, e um retry esgotado ou lock de sessão perdido é exposto como falha de sentinela em vez de desaparecer.
7. Apenas em caso de falha ou ciclo ausente: se o plugin reportar uma falha de sentinela, drene os acordos na fila, inspecione o texto da falha e use `bin/sq-sentry-arm.sh` manualmente apenas como uma sonda curta de recuperação.
8. Nunca use shell `&` para a supervisão da sentinela.
   O mecanismo de arm acima é propriedade do plugin, não uma chamada de ferramenta do modelo, mas uma sonda manual de recuperação que roda em segundo plano, com pipe ou empacotada é negada automaticamente pelo cinto PreToolUse (`.opencode/plugins/sq-primary-pretool-check.js`, `bin/sq-arm-pretool-check.sh`).
9. Não confie neste plugin em `opencode run` headless; a supervisão primária do Squad mira sessões persistentes da TUI do OpenCode.

O runtime persistente de plugin da TUI do OpenCode é o mecanismo de acordar.
O plugin se aplica no checkout principal primário e na própria base de um XO, e fica silencioso apenas nos worktrees filhos de operador e recon.
