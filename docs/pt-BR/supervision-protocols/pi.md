<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

Modo: acordo em segundo plano pela extensão do Pi.

Quando esta sessão é dona da supervisão e o modo ausente não está ativo:
1. Drene primeiro com `bin/sq-stand-to-drain.sh`.
2. Confirme que o Pi primário carregou automaticamente as duas extensões do projeto (`pi` simples ou `pi-signed`, depois de aprovar a confiança do projeto uma vez por clone); se não, reinicie o executável selecionado com `-e __SQUAD_PI_TURNEND_EXT__ -e __SQUAD_PI_EXT__` como fallback sem confiança.
3. Apenas no primeiro ciclo: faça a única chamada obrigatória de `sq_watch_arm_pi`.
   Use `/sq-sentry-arm-pi` apenas como fallback inserido por um humano.
   Nunca rode `bin/sq-sentry-arm.sh` pela ferramenta bash do Pi porque esse arm em primeiro plano pode travar o agente e contorna a limpeza de propriedade da extensão.
4. Se a extensão disser que nenhuma sessão viva detém o lock, rode `bin/sq-session-start.sh` para retomar o lock de sessão e depois chame `sq_watch_arm_pi` novamente.
5. A extensão inicia `bin/sq-sentry-arm.sh --restart`, mantém o filho anexado ao processo Pi vivo e é dona de todo lançamento sucessor posterior.
6. A substituição ordinária de sessão no mesmo processo (`/new`, `/resume`, `/fork`, reload) aposenta apenas a geração anterior; chame `sq_watch_arm_pi` uma vez para o primeiro ciclo da sessão substituta sem reiniciar o Pi.
   O contrato de dono de geração vive em `.pi/extensions/sq-primary-pi-watch.ts`.
7. Depois de um fechamento acionável do filho, a extensão reconfere a posse do lock de sessão e verifica um único sucessor antes de entregar o acordo de follow-up; seu fallback limitado está definido em `docs/sentry-continuity.md`.
8. Trabalho comum, fim de turno e tratamento comum de acordos signal, stale, check, heartbeat ou outros: não chame `sq_watch_arm_pi` novamente porque a continuidade é propriedade da extensão, não da memória do modelo.
9. Um fechamento inesperado do filho entra em retry exponencial limitado, e um retry esgotado ou lock de sessão perdido é exposto como falha de sentinela em vez de desaparecer.
10. Apenas ciclo ausente, falho ou insalubre: se uma notificação posterior relatar explicitamente uma dessas condições de reparo, drene os acordos na fila, inspecione o texto da falha, chame `sq_watch_arm_pi` e reinicie o executável selecionado da família Pi com as duas extensões carregadas se necessário.
   Uma chamada redundante enquanto a extensão é dona de um filho de arm ou de um retry agendado é um no-op `sentry: unchanged` baseado em posse, não uma alegação independente de saúde.
11. Nunca use shell `&` para a supervisão de sentinela.
   O mecanismo de arm acima é propriedade da extensão, não uma chamada de ferramenta do modelo, mas uma sonda manual de recuperação que roda em segundo plano, com pipe ou empacotada é negada automaticamente pelo cinto PreToolUse (`bin/sq-arm-pretool-check.sh`, ligado à extensão turn-end guard em `__SQUAD_PI_TURNEND_EXT__`).

A extensão turn-end guard vive em `__SQUAD_PI_TURNEND_EXT__`.
A extensão de sentinela vive em `__SQUAD_PI_EXT__`.
Ambas são arquivos `.pi/extensions/*.ts` rastreados e locais ao projeto que o Pi descobre automaticamente assim que o projeto é confiável; `bin/sq-session-start.sh` reporta quando a sessão Pi em execução não carregou as duas extensões exigidas.
