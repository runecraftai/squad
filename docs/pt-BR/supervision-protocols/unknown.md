<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

Modo: fallback para harness desconhecido.

Este harness primário não tem um adaptador verificado de acordo de sentinela.
Siga o contrato genérico de supervisão no `AGENTS.md`.
Primeiro ciclo: drene os acordos na fila e depois escolha uma espera de supervisão da qual o harness consiga realmente acordar.
Acordo comum: drene e trate o acordo, depois repita aquela espera verificada enquanto a supervisão ainda for necessária.
Use `bin/sq-sentry-arm.sh` apenas quando o harness tiver um mecanismo rastreado em segundo plano que sobreviva à chamada da ferramenta e notifique o modelo na saída do processo.
Use uma espera limitada em primeiro plano sobre `bin/sq-sentry.sh` quando esse mecanismo de acordar não for verificado.
Nunca use shell `&` para a supervisão de sentinela.
Apenas falha ou ciclo ausente: inspecione a falha e restaure a mesma forma verificada de espera.

Registre nova evidência de verificação antes de promover um harness desconhecido a um snippet nomeado.
