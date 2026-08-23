<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

Modo: supervisão com notificação em segundo plano do Grok.

Quando esta sessão é dona da supervisão e o modo ausente não está ativo:
1. Drene primeiro com `bin/sq-stand-to-drain.sh`.
2. Carregue (`source`) `__SQUAD_X_MODE_ENV__` primeiro quando o Relay estiver ativo.
3. Primeiro ciclo: arme com a ferramenta rastreada de segundo plano do Grok, como uma chamada própria:

   `run_terminal_command` com `background: true` sobre:
   `[ -f __SQUAD_X_MODE_ENV_SH__ ] && . __SQUAD_X_MODE_ENV_SH__; exec bin/sq-sentry-arm.sh`

4. Confie apenas na linha única de status do arm.
5. `sentry: started ...` ou `sentry: attached ...` significa que existe um ciclo vivo.
   No attach, a tarefa em segundo plano segue sucessores verificados com identidade correspondente em vez de sair quando o primeiro ciclo termina.
6. Apenas falha ou ciclo ausente: `sentry: FAILED ...` significa que a supervisão caiu; corrija e rearme.
7. Depois de um status bem-sucedido de start ou attach, termine o turno.
   O arm em segundo plano permanece a espera viva até devolver um acordo acionável ou uma falha.
8. Esperar é silencioso.
9. Nunca use shell `&` para a supervisão do Squad.
10. Nunca empacote o arm junto de outro comando.
    Um shell `&`, um pipe truncante ou empacotamento é negado automaticamente pelo cinto PreToolUse (`bin/sq-arm-pretool-check.sh`) sempre que os hooks Grok deste projeto forem confiáveis.

O Grok injeta uma mensagem sintética de usuário com `synthetic_reason: task_completed` quando o arm em segundo plano termina.
Ao ver um lembrete de sistema de tarefa-em-segundo-plano-concluída para o arm:
1. Rode `bin/sq-stand-to-drain.sh` primeiro.
2. Opcionalmente busque a saída do arm com `get_command_or_subagent_output(<task_id>)` para obter a linha de motivo.
3. Trate `signal`, `stale`, `check` ou `heartbeat` usando o contrato neutro ao harness no `AGENTS.md`.
4. Acordo comum: rearme o próximo ciclo com a mesma chamada em segundo plano de `bin/sq-sentry-arm.sh` se ainda houver trabalho em andamento ou se o Relay ainda precisar de polling.
5. Não invente um acordo a partir de uma linha de status de attach sozinha.
   Drene a fila e aja apenas em registros reais de acordo, nas entradas `OPEN DECISIONS` do drain ou em uma linha real de motivo da sentinela.
   O re-arm anexa a um ciclo saudável existente quando já há um presente e segue sua cadeia verificada de sucessores.
   Veja [`sentry-continuity.md`](../../sentry-continuity.md) para o contrato de sucessores da camada de arm e falha de fechamento limpo.

O hook Stop do projeto primário roda `bin/sq-turnend-guard-grok.sh` como backstop, não como caminho normal de acordo.
[`turnend-guard.md`](../../turnend-guard.md) é dona da seleção de capacidade de payload em execução entre bloqueio nativo no mesmo processo e o fallback limitado pré-nativo de resume.
Depois de qualquer continuação forçada, arme a sentinela com o protocolo em segundo plano acima.

Sessões primárias interativas de TUI são o host de supervisão suportado.
`grok -p` headless pode esperar pela saída de processo em segundo plano mas não expõe de forma confiável toda a saída do modelo de auto-acordar; não rode o Squad primário como processo headless one-shot.
