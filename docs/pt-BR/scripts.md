<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# O cinto de ferramentas de bin/

O sargento de armas comanda estes; os entrypoints interativos também funcionam à mão, enquanto arquivos `*-lib.sh` são helpers carregados via source.
Cada linha é apenas uma cláusula de propósito: o comentário de cabeçalho do próprio script é a descrição autoritativa do comportamento, flags e contratos dele, então leia o cabeçalho antes do primeiro uso.
Se você saiu da base do Squad em um shell interativo, invoque esses scripts por caminho absoluto pelo diretório `bin/` do repo; os scripts se autolocalizam internamente depois de iniciar.
A recusa compartilhada do gate drill para entrypoints do ciclo de vida da unidade está resumida em [architecture.md](architecture.md#fronteira-de-autoridade-do-gate-drill), enquanto `docs/sessionstart-nudge.md` cobre o uso silencioso do hook nativo de abertura de sessão; o cabeçalho do `sq-gate-refuse-lib.sh` é dono do contrato exato dele.

| Script                   | Propósito                                                                             |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `sq-session-start.sh`    | Compor lock, bootstrap e drain de acordos no único digest ordenado de início de sessão |
| `sq-sessionstart-nudge.sh` | Imprimir o nudge do hook nativo de início de sessão quando o primário ainda não rodou o digest |
| `sq-sessionstart-run.sh` | Roteamento um hook nativo de abertura de sessão para o digest completo, uma re-emissão de contexto ou o nudge |
| `sq-operational-input.sh` | Construir e parsear o protocolo canônico cross-language de input operacional |
| `sq-bootstrap.sh`        | Detectar problemas de toolchain e unidade, rodar as varreduras travadas de início de sessão e instalar ferramentas aprovadas |
| `sq-startup-network.sh`  | Rodar as checagens de rede do início de sessão fora do caminho bloqueante dele num worker detached limitado, e publicar o resultado inline ou como acordo |
| `sq-unit-sync.sh`       | Atualizar clones de projeto com fast-forwards seguros, self-heals, relatórios `STUCK:`, poda de branches e recuperação limitada de um `.git/packed-refs.lock` órfão |
| `sq-unit-snapshot.sh`   | Imprimir o JSON estruturado somente leitura do snapshot da unidade (schema `sq-unit-snapshot.v1`)   |
| `sq-unit-view.sh`       | Renderizar o snapshot da unidade como uma view Markdown humana                                   |
| `sq-web-view.sh`        | Servir ou renderizar o dashboard web somente leitura sobre o estado dos operadores de uma base (docs/web-view.md) |
| `sq-sitrep-snapshot.sh` | Projetar o snapshot da unidade na view TOON compacta do sitrep; local-only exceto com `--include-prs` |
| `sq-update.sh`           | Self-update do Squad e das bases XO locais ou remotas somente-fast-forward       |
| `sq-on.sh`               | Executar um comando rastreado do Squad numa base XO remota configurada, usando seu job worker exceto para o bootstrap doctor |
| `sq-remote-job-lib.sh`   | Fila compartilhada limitada de jobs remotos, prontidão de worker, contrato LaunchAgent e PATH composto por filesystem |
| `sq-remote-job-worker.sh` | Worker remoto de longa duração para comandos rastreados `sq-*.sh` no runtime da conta |
| `sq-remote-job-reap-orphans.sh` | Parar workers de jobs remotos deixados por uma raiz de código podada, nunca um cujo checkout ainda existe |
| `sq-remote-doctor.sh`    | Conferir e, com `--fix`, reparar a prontidão de segundo-imediato de uma conta remota (worker de jobs remotos, Herdr, launch agents Aqua, PATH e ferramentas exigidas) |
| `sq-ask.sh`              | Picker interativo de cartões de decisão: lê um JSON de cartão no stdin e renderiza um picker de terminal | 
| `sq-backlog-handoff.sh`  | Validar e delegar movimentos enfileirados de itens de backlog para uma base XO               |
| `sq-backlog-receive.sh`  | Ingerir idempotentemente um outbox confinado de handoff remoto através do sq-tasks             |
| `sq-decision-hold.sh`    | Criar, verificar, completar e resolver decisões duráveis retidas pelo comandante                 |
| `sq-learn.sh`            | Capturar uma lição operacional durável em `data/learnings.md`                         |
| `sq-brief.sh`            | Estruturar briefs ship (`--mode` explícito), recon, charter de XO e Herdr-lab   |
| `sq-herdr-lab.sh`        | Provisionar e operar protegidamente uma sessão de lab Herdr isolada, nunca padrão         |
| `sq-install-herdr.sh`    | Instalar o pin exato de versão do Herdr usado pelo CI com URL oficial de asset, SHA-256 e checagens de protocolo |
| `sq-install-fob.sh`| Compilar e instalar o packages/fob vendado da fonte para E2E real-Herdr que precise de worktrees de spawn |
| `sq-herdr-ci-cleanup.sh` | Snapshotar e derrubar apenas sessões `sq-lab-*` de propriedade do job na lane CI do Herdr       |
| `sq-test-run.sh`         | Runner de testes de comportamento: seleção, lanes portáteis, `--jobs` provadamente isolados, guard de cobertura, timing/JSON |
| `sq-test-isolation-proof.sh` | Prova de isolamento concorrente e dono do conjunto candidato provadamente isolado |
| `sq-ensure-agents-md.sh` | Garantir o `AGENTS.md` real de um projeto, o symlink `CLAUDE.md` dele e a seção canônica de autogovernança |
| `sq-guard.sh`            | Avisar sobre tangles no checkout primário, acordos pendentes na fila e supervisão insalubre    |
| `sq-primary-scope-lib.sh` | Predicado compartilhado marcador-ou-checkout-simples de base primária para hooks rastreados             |
| `sq-session-lock-lib.sh` | Identidade compartilhada do harness no lock de sessão (caminhada de ancestralidade e vitalidade do detentor) para sq-lock.sh e o auto-arm do Stop do Claude |
| `sq-claude-stop-autoarm.sh` | Hook `asyncRewake` do Stop do Claude dono da continuidade sem tokens da sentinela com rewake exit-2 single-flight (docs/sentry-continuity.md) |
| `sq-turnend-guard.sh`    | Predicado compartilhado do turn-end guard primário para que nenhum turno termine às cegas (docs/turnend-guard.md) |
| `sq-turnend-guard-grok.sh` | Adaptador de Stop-hook do Grok para o turn-end guard primário                              |
| `sq-kimi-turnend-hook.sh` | Instalar ou remover cirurgicamente o hook global protegido de fim de turno de crew do Kimi                |
| `sq-arm-pretool-check.sh` | Transporte PreToolUse estável para a política do comando sentry-arm (docs/arm-pretool-check.md) |
| `sq-arm-command-policy.mjs` | Dono semântico da política PreToolUse do sentry-arm (docs/arm-pretool-check.md)   |
| `sq-subagent-pretool-check.sh` | Guard PreToolUse do formato de delegação na base primária (docs/subagent-guard.md) |
| `sq-supervision-instructions.sh` | Renderizar o bloco de supervisão por harness primário do início de sessão ou a instrução de reparo de uma linha |
| `sq-home-seed.sh`        | Provisionar transacionalmente uma base XO local e manter `data/XOs.md` |
| `sq-remote-home-seed.sh` | Registrar e provisionar uma base XO inteira num host alcançável por SSH              |
| `sq-remote-readiness-lib.sh` | Gate compartilhado de prontidão de segundo-imediato remoto: conferir e, quando necessário, reparar e re-conferir via `sq-remote-doctor.sh` |
| [`sq-project-origin-lib.sh`](../../bin/sq-project-origin-lib.sh) | Dono dos formatos de origem aceitos compartilhado pelas duas fronteiras de provisionamento remoto |
| `sq-spawn.sh`            | Spawnar operadores, scouts, lotes `id=repo` e XOs no harness e backend de runtime resolvidos |
| `sq-backend.sh`          | Seleção de backend de runtime, helpers de meta, resolução de seletores e despacho de operações |
| `sq-backend-hometag-lib.sh` | Derivação compartilhada de base-tag por instalação para títulos de aba zellij e workspace cmux |
| `sq-composer-lib.sh`     | Único dono unitário da classificação de conteúdo de composer para todos os backends          |
| `backends/tmux.sh`       | Adaptador verificado de provedor de sessão tmux                                               |
| `backends/herdr.sh`      | Adaptador experimental de provedor de sessão herdr                                          |
| `backends/zellij.sh`     | Adaptador experimental de provedor de sessão zellij                                     |
| `backends/orca.sh`       | Adaptador experimental de backend Orca dono tanto do worktree quanto do terminal                  |
| `backends/cmux.sh`       | Adaptador experimental de provedor de sessão cmux                                           |
| `sq-config-push.sh`      | Empurrar material herdado local declarado para XOs locais ou remotos vivos e enviar a releitura de config específica do posicionamento quando mudar |
| `sq-project-mode.sh`     | Resolver a postura de entrega registrada de um projeto a partir de `data/projects.md` para unit sync e seeding de bases |
| `sq-merge-local.sh`      | Fast-forward da branch default local de um projeto `local-only` após aprovação            |
| `sq-review-diff.sh`      | Revisar uma branch de operador ou head de PR resolvido contra a base autoritativa          |
| `sq-marker-lib.sh`       | Ponto de entrada de compatibilidade para o carrier from-squad de propriedade de `sq-operational-input.sh` |
| `sq-pending-reply-lib.sh` | Expectativas de resposta pendente de XO de propriedade do pai, recovery e ciclo de vida de escalação chaveada |
| `sq-xo-report.sh` | Helper opcional para appendar um status correlacionado ao pai ou relatório de ponteiro de documento       |
| `sq-procevent-remote-reply.sh` | Relay do stream de status do XO remoto através de deltas não destrutivos de process-event |
| `sq-gate-refuse-lib.sh`  | Recusa compartilhada de contexto gate drill para entrypoints do ciclo de vida da unidade               |
| `sq-sentry-arm.sh`        | Wrapper verificado de arm de sentinela com escopo de base, fins de ciclo ruidosos e ledger limitado de ciclo de vida |
| `sq-sentry-checkpoint.sh` | Rodar um checkpoint limitado de sentinela em primeiro plano para supervisão estilo Codex            |
| `sq-sentry.sh`            | Sentinela always-on segura contra duplicatas: absorve acordos benignos, enfileira e sai nos acionáveis |
| `sq-afk-start.sh`        | Rodar o entrypoint comum sourceável do daemon de modo ausente em primeiro plano                      |
| `sq-afk-launch.sh`       | Controlar entrada, saída, rollback do modo ausente e qualquer ciclo de vida de terminal do backend                 |
| `sq-afk-return.sh`       | Controlar shutdown determinístico de retorno, evidência de catch-up e o gate de bloqueador acionável pelo Squad |
| `sq-supervisor-target-lib.sh` | Resolver o alvo e backend compartilhados do supervisor para o daemon e launcher       |
| `sq-supervise-daemon.sh` | Sub-supervisor do modo ausente controlado por presença: auto-trata acordos rotineiros, protege a injeção pelo harness primário detectado, escala digests em lote, alerta sobre entrega falha |
| `sq-crew-state.sh`       | Imprimir uma linha determinística de estado atual para um operador                                |
| `sq-breaker.sh`        | Avaliar os sinais de circuit-breaker de uma tarefa num veredito healthy/steering/constrained/stopped com ação e motivos |
| `sq-breaker-lib.sh`    | Política compartilhada de escada de circuit-breaker sem efeitos colaterais usada por `sq-breaker.sh` |
| `sq-cost.sh`           | Precificar transcripts reais de operadores por modelo e imprimir custo por tarefa, recuando para estimativa por modelo quando não há transcript |
| `sq-cost-lib.sh`       | Parsing compartilhado de transcript, normalização de modelo e tabela de preços por modelo usada por `sq-cost.sh` |
| `sq-drill-run-lib.sh`       | Atribuição compartilhada de identidade de branch-e-código para execuções drill                    |
| `sq-tangle-lib.sh`       | Resolução compartilhada de branch default e classificação de tangle de checkout primário          |
| `sq-timeout-lib.sh`      | Único dono da execução de comandos com limite rígido e seu watchdog fallback |
| `sq-timing-lib.sh`       | Único dono dos registros de tempo decorrido por passo do estágio de rede diferido, inerte a menos que uma execução os peça |
| `sq-supervision-lib.sh`  | Predicado compartilhado de trabalho-em-andamento-sem-beacon-fresco-de-sentinela                         |
| `sq-ff-lib.sh`           | Helper compartilhado protegido de fast-forward para pulls de origem e syncs de XO locais       |
| `sq-lock-lib.sh`         | Prova compartilhada "este lock git está provadamente abandonado?" usada pelo teardown e unit-sync   |
| `sq-config-inherit-lib.sh` | Propagação compartilhada primário-para-XO de material herdado local e entrega de releitura de config |
| `sq-tasks-lib.sh`    | Seletor compartilhado de backlog-backend e sonda de compatibilidade do `sq-tasks`                  |
| `sq-quota-lib.sh`    | Piso compartilhado de compatibilidade do `sq-quota` para o diagnóstico de bootstrap                  |
| `sq-vendor-auth-probe.sh`| Rodar uma sonda de autenticação limitada e não destrutiva de uma CLI vendor nomeada e reportar o fato |
| `sq-stand-to-drain.sh`       | Drenar atomicamente acordos de sentinela na fila, emitir anotações best-effort limitadas de evento de status, seções OPEN DECISIONS e TEARDOWN PENDING unitárias, então afirmar saúde da supervisão |
| `sq-stand-to-lib.sh`         | Fila durável stand-to compartilhada, locks portáteis e helpers de identidade/saúde da sentinela       |
| `sq-handoff-request.sh`      | Registrar, resolver e listar requests duráveis de handoff de nova sessão em fechamentos de marco (docs/handoff-request.md) |
| `sq-handoff-surface.sh`      | Marcar requests de handoff pendentes como expostos exatamente uma vez e imprimir o cartão de handoff (docs/handoff-request.md) |
| `sq-classify-lib.sh`     | Vocabulário compartilhado de classificação de acordos e folds e scans duráveis de decisões chaveadas     |
| `sq-send.sh`             | Enviar uma linha literal verificada ou tecla suportada pelo backend registrado do alvo |
| `sq-busy-lib.sh`         | Único dono do contrato semântico de busy-state: vereditos, atribuição de fonte e fontes por harness |
| `sq-busy-event.sh`       | O único escritor do registro semântico de busy-state de uma tarefa; arma uma encarnação e aplica eventos de ciclo de vida |
| `sq-tmux-lib.sh`         | Primitivas compartilhadas de pane tmux para captura de composer, submit verificado e checagem de ocupação no submit |
| `sq-peek.sh`             | Imprimir uma cauda limitada de um endpoint de operador                                          |
| `sq-check-register.sh`   | Vincular uma checagem customizada intencional de sentinela aos bytes atuais dela                       |
| `sq-check-lib.sh`        | Validar registros de checagem customizada e preparar snapshots privados de execução          |
| `sq-pr-lib.sh`           | Ser dono da validação canônica de tarefa e PR mais publicação atômica privada de PR-poll e aposentadoria ligada a identidade |
| `sq-pr-poll.sh`          | Fornecer o programa byte-estático de sentinela para sidecars validados de poll de PR/MR           |
| `sq-pr-check-migrate.sh` | Quarentenair polls de tarefa antigos sem execução e reconstruir apenas polls canônicos       |
| `sq-pr-check.sh`         | Registrar valores validados de `pr=` e `pr_head=`, então armar atomicamente um poll estático de merge |
| `sq-pr-merge.sh`         | Registrar metadados do PR, então mesclar a URL completa canônica GitHub do PR da tarefa                    |
| `sq-promote.sh`          | Promover uma tarefa recon in-place a uma tarefa strike protegida com modo de entrega explícito |
| `sq-teardown.sh`         | Teardown fail-closed: devolver worktrees ship landadas, exigir entregáveis completos de recon, aposentar bases XO |
| `sq-harness.sh`          | Detectar o harness em execução e resolver crew ou XO harness, modelo e esforço |
| `sq-lock.sh`             | Lock de sessão Squad por base                                                      |
| `sq-x-lib.sh`            | Helpers compartilhados de config Relay, relay e threading de replies                              |
| `sq-x-poll.sh`           | Um poll limitado de Relay: guarda menções recentemente oferecidas e emite o acordo delas uma única vez   |
| `sq-x-reply.sh`          | Postar ou pré-visualizar dry-run uma reply ou follow-up composto de Relay                          |
| `sq-x-dismiss.sh`        | Dispensar uma menção Relay pulgada no relay sem responder                        |
| `sq-x-link.sh`           | Ligar uma tarefa spawnada à menção Relay originária dela no meta da tarefa                    |
| `sq-x-followup.sh`       | Detectar, postar e limitar follow-ups de conclusão para uma tarefa ligada ao Relay                  |
| `sq-public-followup-lib.sh` | Gate compartilhado de ativação relay, checagens de presença O(1) e caminhos privados de transporte para replies públicas prometidas |
| `sq-public-followup.sh`  | Reconciliar resultados terminais tipados de trabalho num comprometimento público e entregar sua reply final uma vez |
| `sq-public-followup-emit.sh` | Reportar um resultado terminal tipado de trabalho para a base que deve a reply pública    |
