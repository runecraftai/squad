<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

Modo: supervisão de propriedade do Stop-hook do Claude.

Quando esta sessão é dona da supervisão e o modo ausente não está ativo:
1. Drene primeiro com `bin/sq-stand-to-drain.sh`.
2. O arm e o re-arm rotineiros da sentinela são de propriedade do hook Stop `asyncRewake` (`bin/sq-claude-stop-autoarm.sh`), nunca seus.
   Todo fim de turno enquanto a supervisão for necessária lança ou anexa um ciclo de sentinela com escopo de base, sem comando do modelo e sem tokens do modelo.
   Um fechamento acionável acorda você pelo rewake exit-2 do hook, entregue como uma mensagem `Stop hook feedback`.
3. Em um acordo `Stop hook feedback` (`signal:`, `stale:`, `check:` ou `heartbeat`), rode `bin/sq-stand-to-drain.sh` primeiro e trate o acordo.
   Não rode `bin/sq-sentry-arm.sh` depois de um acordo comum; o próximo fim de turno rearma automaticamente quando a supervisão ainda for necessária.
   Não invente um acordo a partir de uma linha de status de attach sozinha; drene e aja apenas em registros reais de acordo, nas entradas `OPEN DECISIONS` do drain ou em uma linha real de motivo da sentinela.
4. No único aviso automático de falha de mecanismo via `Stop hook feedback` (`Squad sentry auto-arm FAILED ...`), drene, inspecione a falha do mecanismo automático, e não transforme o aviso em um loop manual repetitivo de arm.
5. Se o hook Stop não reivindicar a base ou reportar uma falha esgotada, inspecione seu registro e o caminho de inicialização da sentinela antes de terminar às cegas.
   Mantenha o mecanismo automático de propriedade do Stop como o único armador no Claude.
6. Trate `sentry: started ...` e `sentry: attached ...` dentro da saída do arm automático como prova de que existe um ciclo vivo.
   No attach, o arm segue sucessores verificados com identidade correspondente em vez de sair quando o primeiro ciclo termina.
7. A fila durável stand-to preserva eventos acionáveis entre um rewake e o próximo arm lançado pelo Stop, enquanto o turn-end guard limitado impede um Stop às cegas quando a recuperação não começou.
   Nenhum hook PreToolUse nega comandos de unidade com base no status da sentinela.
   [`sentry-continuity.md`](sentry-continuity.md) é dona da fronteira exata de recuperação do lock de sessão.
8. O turn-end guard (`bin/sq-turnend-guard.sh --claude`) permanece o backstop final.
   Ele exige o predicado PID-strict de sentinela viva e beacon fresco na fronteira do Stop, enquanto o guard de pull no meio do turno aceita um beacon fresco sem processo vivo sob o modelo auto-arm entre turnos do Claude.
   Ele permite o stop quando uma sentinela está saudável ou o auto-arm verificado por papel é dono da recuperação, enquanto epochs de falha frescos avançam a progressão limitada de fail-open assistido descrita em [`turnend-guard.md`](turnend-guard.md).
9. Esperar pelo ciclo de propriedade do hook é silencioso: não envie progresso ocioso enquanto a sentinela estiver estacionada.

A sentinela em si continua sendo `bin/sq-sentry.sh`, e `bin/sq-sentry-arm.sh` continua sendo o wrapper verificado de arm que o hook Stop traz para primeiro plano.
O re-arm anexa a um ciclo saudável existente quando já há um presente e segue sua cadeia verificada de sucessores.
Veja [`sentry-continuity.md`](sentry-continuity.md) para o contrato de sucessores da camada de arm e falha de fechamento limpo, e o modelo de posse no Claude.
