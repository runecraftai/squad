<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Guard de supervisão de fim de turno do primário

Este é o contrato atual autoritativo para o backstop primário "nenhum turno termina às cegas" referenciado da seção 8 do AGENTS.md.
O predicado vive em `bin/sq-turnend-guard.sh`.
O escopo primário vive em `bin/sq-primary-scope-lib.sh`, compartilhado com os adaptadores nativos de início de sessão em [`sessionstart-nudge.md`](../sessionstart-nudge.md).
Os arquivos de hook de cada harness adaptam o mecanismo de fim de turno daquela integração primária habilitada a esse predicado compartilhado.

Guards PreToolUse relacionados negam comandos inseguros antes da execução em vez de detectar um fim de turno às cegas depois.
Seus donos separados são [`arm-pretool-check.md`](../arm-pretool-check.md), [`cd-guard.md`](../cd-guard.md) e [`subagent-guard.md`](../subagent-guard.md).
Não infira o escopo, segurança de loop ou tradeoffs de compatibilidade deste guard para aqueles.

## Invariante atual

`bin/sq-guard.sh` é um warning pull-based que roda apenas quando outro comando de supervisão o invoca.
O turn-end guard fecha a lacuna restante na própria fronteira de turno do primário.
Quando trabalho, uma fonte process-event ou polling do Relay precisam de supervisão nessa fronteira e nenhuma sentinela com identidade correspondente tem beacon fresco, a integração do harness precisa ou bloquear o fim do turno ou forçar um follow-up limitado que usa a instrução de recuperação do protocolo emitido no início da sessão.
O warning pull no meio do turno usa o veredito de supervisão ciente-do-modelo descrito abaixo, enquanto o turn-end guard mantém o predicado PID-strict de sentinela.
O guard permanece um backstop; [`sentry-continuity.md`](../sentry-continuity.md) é dona da continuidade normal.

## Predicados do guard

O guard primeiro chama o escopo primário compartilhado.
Uma base XO roda sua própria sessão Squad primária, então um marcador genuíno `.sq-xo-home` a inclui tanto se a base é linked worktree quanto clone simples.
O marcador precisa ser um arquivo regular sem symlink cuja primeira linha, sem espaços, é um identificador não vazio contendo apenas letras, dígitos, pontos, underscores e traços.
Um checkout sem marca ou marcador inválido recai na checagem do git dir.
Essa checagem mantém os worktrees linkados de operador e recon inertes porque seu git dir difere do git common dir deles.
Ela também exige `AGENTS.md`, `bin/` e o diretório de estado efetivo.

Para um primário em escopo, o guard conta trabalho em andamento a partir de `state/*.meta`.
Registros `state/procevent/*.source` registrados também exigem supervisão mesmo sem metadados de tarefa.
O modo cross-harness padrão sai silenciosamente sem necessidade de supervisão.
Todo modo trata `state/x-sentry.check.sh` como necessidade de supervisão, então o polling do Relay permanece protegido sem tarefa em andamento.
Caso contrário ele chama `fm_sentry_healthy <state-dir> <watch-path> [grace-seconds] [home]` de `bin/sq-stand-to-lib.sh`, a mesma checagem PID-strict de lock com identidade correspondente e beacon fresco usada por `bin/sq-sentry-arm.sh`: um beacon obsoleto bloqueia mesmo quando um pid de sentinela está vivo, e um beacon fresco residual bloqueia quando o lock está ausente, morto ou com identidade divergente.
O turn-end guard precisa dessa checagem estrita porque dispara na fronteira do turno, onde o auto-arm está trazendo uma sentinela fresca para o período ocioso que vem, e coopera com aquele arm em vez de confiar num beacon deixado pelo ciclo que acabou de terminar.
`bin/sq-guard.sh`, o warning pull, usa em vez disso o `fm_sentry_supervision_verdict` ciente-do-modelo da mesma biblioteca, porque dispara no meio do turno quando sob o modelo auto-arm nenhuma sentinela roda de forma alguma.
Sob o modelo auto-arm do Stop do Claude um beacon fresco dentro da graça é saudável mesmo sem processo vivo de sentinela, e apenas um beacon obsoleto além da graça (ou ausente) alarme.
Sob todo harness de sentinela persistente uma sentinela viva com identidade correspondente e beacon fresco ainda é exigida, então o guard pull mantém as mesmas semânticas estritas ali.
O banner dele nomeia a condição real falha, seja processo vivo de sentinela ausente seja beacon genuinamente obsoleto com sua idade real, e chaveia o dedup uma-por-episódio nessa condição em vez do mtime do beacon.

`SQUAD_STATE_OVERRIDE` vence sobre `SQUAD_BASE/state`, e `SQUAD_BASE` vence sobre o `state/` da raiz do repositório.
`SQUAD_GUARD_GRACE` controla a frescor do beacon e tem padrão de 300 segundos.
Se `jq` está ausente ou o stdin do hook está vazio, o guard sai 0 porque não consegue ler com segurança os campos loop-guard.

## Integrações por harness

- O Claude registra dois hooks `Stop` no `.claude/settings.json`, ambos ancorados via `CLAUDE_PROJECT_DIR`: `bin/sq-turnend-guard.sh --claude`, e `bin/sq-claude-stop-autoarm.sh` com `asyncRewake: true` e `timeout: 28800`.
- O Codex registra um hook `Stop` no `.codex/hooks.json`, ancora o executável ao diretório de trabalho do processo do hook, verifica uma raiz em formato Squad portadora do hook, e passa o payload original ao guard compartilhado.
- O OpenCode escuta `session.idle` em `.opencode/plugins/sq-primary-turnend-guard.js`, deixa o coordenador de sentinela agir primeiro, e chama `client.session.promptAsync` uma vez quando o guard retorna 2.
- O Pi escuta `agent_settled` em `.pi/extensions/sq-primary-turnend-guard.ts`, roda uma vez por execução lógica do agente, e chama `pi.sendUserMessage(..., { deliverAs: "followUp" })` uma vez quando o guard retorna 2.
- O Grok registra um hook `Stop` em `.grok/hooks/sq-primary-turnend-guard.json` e delega a seleção de capacidade ao `bin/sq-turnend-guard-grok.sh`.
  As entradas rastreadas do Stop do Claude ficam inertes quando `GROK_AGENT` ou `GROK_HOOK_EVENT` está presente, então o carregamento de settings compatível com Claude do Grok não pode criar um segundo caminho de continuação.
  Ambos os marcadores são exigidos porque o Grok não injeta as mesmas variáveis em todos os tipos de processo: grok 0.2.73 definia `GROK_AGENT` para processos filhos e de ferramenta, enquanto os processos de hook do grok 1.0.0 carregam `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID` e `GROK_WORKSPACE_ROOT` mas nenhum `GROK_AGENT`.
  Um guard chaveado só em `GROK_AGENT` portanto parou de disparar no grok 1.0.0, e o auto-arm resultante exclusivo do Claude rodava sincronamente sob o Grok - o Grok não tem `asyncRewake`, então esperou pela sentinela trazida a primeiro plano pelo timeout declarado de 28800 segundos e o turno do Grok nunca terminava.
  NÃO alargue este guard para `GROK_SESSION_ID`: o Grok injeta isso em todo processo filho, então pode sobreviver numa sessão Claude lançada pelo Grok e desabilitaria silenciosamente a própria continuidade do Claude.
  O mesmo guard de marcadores carrega toda entrada rastreada do `.claude/settings.json` cujo evento o Grok já cobre pelo próprio registro dele em `.grok/hooks/`, que são ambas as entradas `Stop`, a entrada `SessionStart` e as duas entradas Bash `PreToolUse`; `bin/sq-subagent-pretool-check.sh` é a única exceção deliberada sem guarda porque nenhum registro do Grok cobre o evento de spawn de subagente, registrado em [`subagent-guard.md`](../subagent-guard.md) "Known residual gap".
  `tests/sq-turnend-guard.test.sh` fixa esse inventário para que nem o conjunto protegido nem a exceção possam mudar silenciosamente.

Claude e Codex conseguem bloquear um Stop diretamente com status de saída 2 e stderr.
Ambos os payloads carregam `stop_hook_active`.
No modo padrão do Codex, valor true permite que o segundo stop termine depois de uma continuação forçada.

O Claude roda o guard com `--claude`, que ignora `stop_hook_active` e coopera com o auto-arm de propriedade do Stop.
O Claude Code define `stop_hook_active=true` em todo stop depois de qualquer continuação de stop-hook, incluindo rewakes `asyncRewake`, que reabriram a janela às cegas de 2026-07-21 sob o comportamento one-shot padrão.
O modo Claude espera até `SQUAD_CLAUDE_AUTOARM_SYNC_WAIT_MS` (padrão 800 milissegundos) e permite o stop quando a sentinela está saudável, `state/.claude-autoarm.lock` tem um dono vivo de papel `autoarm` cuja eventual falha deve sair 2, ou `state/.claude-autoarm-epoch` contém um rewake acionável fresco de propriedade desta epoch de evento.
Resultados frescos `failed` e `failed-suppressed` entram ou avançam a progressão de falha em vez de agirem como prova incondicional de recuperação.
O auto-arm em si reconferencia o predicado de sentinela saudável e tenta um número limitado de vezes antes de reportar falha genuína.
A primeira epoch fresca de falha esgotada preserva seu handoff sem consumir contagem de stop bloqueado, enquanto epochs frescas posteriores de falha avançam a mesma progressão monótonica em vez de resetá-la.
Quando nenhuma dessas provas aparece, ele re-bloqueia até `SQUAD_CLAUDE_TURNEND_BLOCK_BUDGET` vezes (padrão 3, abaixo do override de 8 blocos do Claude).
No modo Claude, recuperação positiva da sentinela limpa o orçamento de blocos, o aviso de falha e o alarme assistido juntos sob o lock existente de orçamento antes que qualquer hook reporte recuperação ordinária.
O único fail-open assistido ruidoso fica disponível apenas quando o auto-arm registrou uma falha esgotada, seu único aviso já foi consumido, o orçamento de blocos se esgotou, e uma checagem final não encontra nem sentinela saudável nem continuação automática.
Cada identidade de epoch é contabilizada no máximo uma vez sob o lock de orçamento.
Sempre que ambos os locks de coordenação forem necessários, a recuperação positiva do auto-arm e a checagem terminal adquirem o lock do dono do auto-arm antes do lock de orçamento.
Depois desse alarme, o auto-arm do Stop suprime continuações exit-2 adicionais até recuperação positiva da sentinela, para que o fail-open final permaneça alcançável.
O alarme não pode repetir durante aquele episódio de falha, e um stop posterior insalubre bloqueia novamente.
Uma sentinela positivamente verificada como saudável limpa o aviso de falha, o alarme e o orçamento de blocos para um futuro episódio independente.
Um aviso de falha do Claude descreve o mecanismo automático como quebrado e não direciona um arm manual rotineiro em segundo plano.

OpenCode, Pi e pi-signed expõem callbacks passivos para esse propósito.
Seus adaptadores fail-open na fronteira do hook para proteger a sessão do usuário mas agendam um follow-up limitado quando o predicado bloqueia.
Os prompts gerados usam o kind canônico `turn-end-guard` após o prefixo U+2063 `SQUAD_OP: `, então o Reporting não os trata como mensagens do comandante.
Cada adaptador passivo é dono de um latch de loop.
O Pi mantém o latch através dos turnos internos de ferramenta e o limpa apenas quando o follow-up gerado se estabiliza ou a entrega falha.
O follow-up forçado do OpenCode é suportado para sessões persistentes de TUI e permanece fail-open em `opencode run` headless.

O Grok faz exatamente uma decisão tipada de capacidade de cada payload Stop em execução.
Um booleano `stopHookActive` seleciona bloqueio nativo, incluindo false no stop inicial e true na continuação limitada.
O campo camel-case tem precedência quando ambas as grafias aparecem; quando está ausente, um booleano `stop_hook_active` seleciona o mesmo caminho nativo por compatibilidade.
O caminho nativo devolve o status e stderr do guard compartilhado ao mesmo processo Grok e nunca inicia `grok --resume`.
Quando ambas as grafias de capacidade estão ausentes, o adaptador preserva um fallback pré-nativo `grok --resume` protegido por `GROK_TURNEND_GUARD_ACTIVE` e intencionalmente omite `--permission-mode`.
JSON malformado, um campo selecionado com tipo não booleano, `jq` ausente, pré-requisitos do hook faltando ou um guard legado já ativo permitem o stop sem iniciar qualquer caminho de continuação.
O hook de projeto do Grok exige que o checkout seja confiável com `/hooks-trust` ou `--trust` no lançamento; builds genuinamente pré-nativos podem rodar o mesmo hook rastreado a partir de um diretório global isolado de hooks.

Se um adaptador passivo não consegue invocar seu SDK, ou o fallback legado do Grok não encontra `grok` ou um id de sessão, a próxima chamada pull-based de `sq-guard.sh` reporta o problema.
Esse warning usa `bin/sq-supervision-instructions.sh --repair-line`, então sempre aponta para o protocolo do harness ativo em vez de embutir outro comando de reparo.

## Limites de compatibilidade

- Worktrees filhos de operador e recon estão fora do escopo.
- Uma base XO válida está em escopo; um endpoint XO ocioso sem poll de Relay permanece saudável porque não tem necessidade de supervisão.
- A divisão entre bloqueio direto e follow-up passivo limitado é restrita às integrações primárias listadas acima.
- O modo headless do OpenCode e hooks de projeto do Grok não confiáveis permanecem fail-open na fronteira do host.
- Kimi Code CLI 0.29.1 expõe apenas configuração global `[[hooks]]` em `~/.kimi-code/config.toml`, incluindo um evento `Stop` com campos de payload snake_case `hook_event_name`, `session_id`, `cwd` e `stop_hook_active`.
- O Kimi não tem configuração de hook no nível do projeto e permanece fora das integrações primárias do guard acima.
- O suporte aprovado pelo comandante para acordos de crew do Kimi usa `bin/sq-kimi-turnend-hook.sh` para editar apenas uma região delimitada por marcadores do Squad naquele config global e instalar um hook silencioso sempre-zero.
- O hook permanece inerte a menos que o `cwd` do payload contenha um ponteiro de token por tarefa que resolva pelo registro privado do Squad até um marcador `state/<id>.turn-ended`.
- A instalação recusa antes de escrever a menos que `python3` com `tomllib` e `jq` estejam disponíveis.
- Se `jq` for removido depois da instalação, o hook permanece silencioso e sai 0, os acordos de fim de turno param, e operadores Kimi recuam para detecção de ociosidade.
- Input ilegível do hook permanece fail-open.
- Nenhum adaptador de harness usa ampersand de shell para fabricar supervisão.

## Cobertura de regressão

`tests/sq-turnend-guard.test.sh` cobre o predicado, escopo primário principal e XO, exclusão de worktree filho, precedência de `SQUAD_BASE` e `SQUAD_STATE_OVERRIDE`, o predicado do guard de lock-vivo e beacon-fresco, a espera cooperativa de claim `--claude`, progressão monótonica de epochs falhos, fail-open assistido limitado, supressão de continuação pós-alarme, reset positivo de recuperação, latching de execução lógica do Pi, comportamento sem `jq`, todos os cinco registros primários, seleção nativa e legada do Grok, precedência de campo tipado, input malformado e segurança exatamente-um-caminho.
`tests/sq-guard-stale-banner.test.sh` cobre o predicado do guard pull, incluindo o controle negativo de beacon-residual-fresco persistente-modelo, o caso do modelo auto-arm de beacon-fresco-sem-sentinela saudável e seu alarme de beacon-obsoleto, a redação verdadeira do banner de motivo, e o dedup de episódio chaveado por motivo sobrevivendo a mudança de mtime do beacon.
`tests/sq-kimi-harness.test.sh` cobre a preservação de formato do hook separado de crew do Kimi, idempotência, casos de recusa, guard de token, registro de spawn e limpeza de teardown.
`tests/sq-supervision-instructions.test.sh` cobre a posse das linhas de recuperação e a reutilização preservadora de identidade do protocolo do Pi pelo pi-signed.
`SQUAD_PI_LIVE_E2E=1 tests/sq-pi-primary-live-e2e.test.sh` é o caminho opt-in isolado do Pi.
[`verification/supervision.md`](../verification/supervision.md#turn-end-guard) registra a evidência empírica ativa cross-harness, incluindo a reverificação `asyncRewake` do Claude de 2026-07-24.
