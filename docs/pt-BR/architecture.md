<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Arquitetura

Como o Squad funciona, em profundidade.

O [README](../../README.md) carrega o diagrama em alto nível e um curto sinopse.
Este documento expande cada parte dele.
O contrato operacional sempre carregado do Squad e o índice de roteamento para procedimentos condicionais é [`AGENTS.md`](../../AGENTS.md); este é o companheiro voltado para humanos.

## Supervisão orientada a eventos

Uma sentinela bash zero-token (`bin/sq-sentry.sh`) dorme sobre a unidade, classifica acordos detectados em bash, e acorda o sargento de armas apenas quando algo é acionável.
Acordos acionáveis incluem sinais de status relevantes ao comandante, sinais sem-verbo cuja crew não está provadamente trabalhando, saída autenticada de checagem como polling de merge de PR ou menção Relay, panes stale cuja crew não está provadamente trabalhando independentemente de seu log de status parecer terminal ou não-terminal, panes stale de tarefa finalizada absorvidos quando o estado atual já prova a tarefa done ou failed, panes provadamente-trabalhando mas stale que persistem além de `SQUAD_STALE_ESCALATE_SECS` sem drill run-step ativo, passos de pipeline em execução cuja atividade o Drill reporta como quiet (com a exclusão do monitor de CI abaixo), esperas externas declaradas que permanecem paused além de `SQUAD_PAUSE_RESURFACE_SECS`, evidência objetiva da era-da-pausa que sobrepõe uma pausa absorvida (um worktree sujo ocioso, uma pausa declarada mais velha que `SQUAD_PAUSE_MAX_SECS`, ou uma assinatura de painel travada), e hits de backstop de heartbeat.
Escalações repetidas de stale, provadamente-trabalhando ou busy expirado, no mesmo pane inalterado adicionam uma contagem de escalação ao motivo do acordo e, em `SQUAD_WEDGE_DEMAND_INSPECT_COUNT`, um marcador `demand-deep-inspection`.
Uma execução genuinamente terminal (sua projeção compartilhada de estado atual não mostra nenhuma run viva ou parada em gate sobre ela: um registro de despacho liberado, uma crew finalizada - incluindo uma run de drill terminal sobre um registro de despacho que nunca foi aposentado - ou apenas uma assinatura de painel busy ou progresso de status-log que nenhum agente naquele painel pode sustentar), cujo pane registrado não tem nenhum agente atribuível é excluída da classificação de stale: ela nunca entra no relógio de stale, portanto também nunca ressurgira a cadência limitada de pausa declarada e nunca inicia os relógios de worktree sujo ou de assinatura de painel; seus marcadores por janela, os marcadores de watcher por tarefa que o daemon do modo afk e a deduplicação de compactação possuem, e as assinaturas de sinal `.seen-<task>_status` e `.seen-<task>_turn-ended` do sentry são aposentados, mas um aviso relevante ao comandante `done:`/`failed:` cujo registro de entrega `.hb-surfaced-<task>` não corresponde ainda é apresentado uma vez antes dessa aposentadoria, e só depois disso esses sinais não são novos enquanto seus arquivos permanecerem. A varredura catch-all e a migração de pausa do modo afk aplicam o mesmo limite, enquanto uma run ativa ou parada em gate, uma espera declarada ou uma decisão aberta num registro que nunca foi liberado, e qualquer leitura ambígua de agente mantêm a supervisão ordinária, e a atribuição de agente é verificada de novo a cada poll, então um agente que retorna retoma a supervisão ordinária imediatamente. O próprio veredito terminal é memoizado por geração da tarefa e revalidado no máximo uma vez a cada `TERMINAL_PROBE_SECS` (300s), então uma run iniciada fora de banda que não altere nenhuma das entradas registradas da geração que a projeção consome pode permanecer invisível a essa exclusão por até esse limite.
Cada varredura de sinais, e a revalidação imediatamente antes do acordo depois da re-varredura de consolidação, descarta qualquer entrada `state/<id>.status` ou `state/<id>.turn-ended` cujo `state/<id>.meta` tenha sumido, junto com o marcador `.seen-*`, para que um toque tardio de turn-end após a liberação não acorde o Squad por uma tarefa que não existe mais.
Em cada passada de classificação de stale, a sentinela re-deriva cada alvo supervisionado a partir de metadados vivos de tarefa e descarta o hash do pane, o supressor de stale, o temporizador de wedge, a contagem de escalação e os marcadores de pausa e de passo quiet de qualquer chave de janela cujo `state/<id>.meta` tenha sumido, então uma janela liberada encerra a supervisão em vez de retomar um episódio que ela não possui mais.
Uma declaração de busy não comprova atividade por si só: o hash e temporizador existentes só expiram a declaração quando toda a saída renderizada, incluindo o indicador de custo/tokens, permanece inalterada por `SQUAD_STALE_ESCALATE_SECS`.
Mudanças na saída reiniciam o episódio e a contagem, independentemente da idade do turno; o motivo `busy expired without activity` preserva a gramática de escalação e inspeção profunda consumida pelo daemon.
No modo afk, o sentry transfere uma vez por hash estático, busy ou ocioso, e o daemon controla uma janela completa até a escalação; essa transferência interna antecipada não é um alarme ao comandante.
O temporizador existente carrega o instante de cada episódio; repetir a transferência não retrocede uma validação ou tentativa posterior, e o registro busy normal se distingue de uma transferência real ao daemon para que entrar no modo ausente não a suprima.
Os supressores busy são identificados no marcador stale existente, de modo que remover busy sem alterar a viewport mantém a apresentação imediata da transição ociosa inconclusiva.
Uma tarefa realmente done/failed limpa o temporizador de wedge sem rearmá-lo; consultar novamente o estado atual impede que um resultado finalizado antigo esconda uma validação nova.
Um run-step ativo atual prevalece sobre status terminal antigo e adia a expiração de pane nos dois modos, mas não pode suprimir o motivo independente de passo quiet abaixo.
Leituras da viewport completa são suportadas em tmux (`capture-pane` sem `-S`), zellij (`dump-screen` sem `--full`) e tuios (`capture-pane` sem `--scrollback`).
As flags de viewport do Herdr e Orca não foram verificadas, e o cmux não tem leitura completa verificada neste repositório: esses caminhos retornam cannot-evaluate, nunca comprovam estagnação por uma cauda e registram a limitação nominal do backend no episódio busy estático.
Uma viewport ilegível não comprova inatividade: o daemon mantém a tentativa no marcador existente, exclui o intervalo ilegível e inicia uma janela estática completa após recuperar a leitura.
Transferências ociosas seguem a mesma regra por episódio; a cadência das pausas declaradas permanece inalterada, enquanto o limite de envelhecimento de pausa abaixo é um relógio separado.
A escalação solicita apenas inspeção, nunca interrupção ou reinício automático.
Uma linha de status final declarando `paused:` ou um endpoint durável `commander-held` sobrepõe esse veredito de ocupado, então o indicador de ocupado sozinho deixa de forçar uma classificação working e o painel mantém a cadência delimitada de pausa em vez de iniciar o temporizador de wedge.
Três regras objetivas independentes da era-da-pausa delimitam essa tolerância, cada uma com seu próprio temporizador e marcador, para que uma espera externa declarada não possa esconder trabalho inacabado ou um endpoint travado.
(1) Worktree sujo: uma tarefa cujo `worktree=` registrado permanece sujo (leitura read-only de `git --no-optional-locks status --porcelain`, cobrindo arquivos modificados, staged e untracked) enquanto seu agente está ocioso escala após `SQUAD_STALE_ESCALATE_SECS` nomeando `operator idle with uncommitted work`, mesmo quando o último status é `paused:`; um painel ocupado, uma árvore limpa, um status terminal e um drill run-step ativo o reiniciam ou adiam, um worktree não registrado ou ausente nunca é medido, e uma leitura de Git que falha é registrada como cannot-evaluate, mantém seu relógio e nunca reivindica propriedade pause-era.
(2) Envelhecimento de pausa: uma pausa declarada suprime o alarme de wedge apenas por `SQUAD_PAUSE_MAX_SECS` (padrão 3600), após o qual uma escalação nomeia a pausa envelhecida e pede ao supervisor que a confirme ou limpe; o episódio de pausa é o ordinal do registro append-only de status da pausa ainda aberta, então uma declaração nova idêntica o renova e apenas um evento `resolved` que nomeia a chave daquela pausa, ou um registro de estado posterior não-pausado, o encerra, enquanto um `resolved:` vazio ou não relacionado não o faz, e a expiração one-shot suprime a rechecagem periódica legada; um painel ocupado ou um drill run-step ativo mantém o relógio contido, e appends posteriores não movem a idade semeada quando o episódio começou.
(3) Assinatura de painel: o painel renderizado completo da tarefa é a evidência, nunca o nome do agente - uma viewport byte-idêntica além de `SQUAD_STALE_ESCALATE_SECS` que continua mostrando uma assinatura travada (banner de compactação, turno cancelado/interrompido ou prompt y/n, diálogo de erro do provider, ou um `SQUAD_PANE_SIGNATURE_RE` fornecido pelo operador) escala nomeando o texto observado da assinatura e o hash de onde foi lido, mesmo sob uma pausa declarada ou uma alegação de ocupado; qualquer byte alterado, um drill run-step ativo ou um composer pendente num painel ocioso reinicia o relógio em vez de escalar, e um backend sem viewport completa legível é registrado como cannot-evaluate em vez de virar progresso ou um veredito travado inventado.
A assinatura embutida de diálogo de erro exige uma linha de erro do provider mais uma ação de retry ativa nas linhas inferiores da viewport, então prosa sobre rate limit no scrollback nunca conta como diálogo.
Como cada regra nomeia sua evidência no motivo `stale: <window> (...)`, o modo ausente escala essa mesma evidência através do digest do daemon (lote delimitado, uma transferência por episódio ou assinatura) em vez de reabsorvê-la como uma rechecagem de pausa rotineira.
Esses marcadores por-janela se aposentam com o restante do bookkeeping de janela no teardown de tarefa, no cleanup de órfãos e na exclusão terminal sem agente acima; [`configuration.md`](configuration.md) é dono do inventário de arquivos de estado.
Esses acordos acionáveis são escritos em uma fila local durável (`state/.stand-to-queue`) antes que o estado do detector avance, então um exit de processo perdido pode ser recuperado drenando a fila.
Quando um poll canônico validado de PR retorna exatamente `merged`, a sentinela appenda aquela notificação durável antes de publicar um recibo privado vinculado ao registro, bytes, identidades de arquivo, metadados, provider, URL e ID da tarefa do poll.
O recibo torna a aposentadoria seguramente retryável entre restarts: recovery de caminho fixo revalida a mesma evidência, remove a checagem executável primeiro, remove seu registro e sidecars de dados, remove o recibo por último, e preserva metadados da tarefa incluindo `pr=` e `pr_head=`.
Uma substituição concorrente permanece armada, toda observação não-merged ou inválida permanece inalterada, e a aposentadoria nunca executa cleanup de tarefa ou XO persistente.
`bin/sq-pr-lib.sh` é dono do formato de recibo e mecânica estrita de identidade, enquanto `bin/sq-sentry.sh` é dono da ordenação de-fila-antes-de-aposentadoria.
Acordos sem-verbo, como anotações `working:` e sinais puros turn-ended, são benignos apenas quando `bin/sq-crew-state.sh` reporta evidência positiva de que o operador ainda está trabalhando: um step de drill ativamente rodando atribuído ao código atual daquela crew, ou um veredito exato de busy do contrato semântico de busy-state.
Uma exceção sobrevive a esse veredito de busy: uma tarefa Pi jovem, que nunca reportou status, cujo registro de busy-state carrega `event=compaction` ainda assim superficia, delimitada a um wake por compactação distinta, para que a rajada de toques turn-ended de uma compactação de contexto não possa se esconder atrás da mesma checagem de evidência-positiva-de-busy que absorve a agitação comum (a exceção compaction-without-status de `bin/sq-classify-lib.sh`).
Uma crew que declara `paused:` para uma espera externa conhecida é absorvida separadamente e re-superficiada na cadência de pausa mais longa, em vez de ser tratada como possível wedge, exceto pela evidência objetiva da era-da-pausa acima; essa pausa declarada sobrepõe um painel meramente ocupado, enquanto um passo de drill genuinamente ativo ainda prevalece sobre a pausa.
Um painel ocioso sem linha de status também não é escalado como possível wedge baseado em painel enquanto o drill run-step da tarefa está ativo, como um gate em primeiro plano ou uma espera de CI; um painel busy com saída estática é adiado da mesma forma, porque os dois caminhos compartilham o temporizador de wedge, e o limite volta a se aplicar assim que nenhum passo estiver ativo.
Independentemente disso, a sentinela checa a atividade de passo vinculada à branch/código através de `bin/sq-crew-state.sh` na cadência existente `SQUAD_CHECK_INTERVAL`: `bin/sq-drill-run-lib.sh` consome o prefixo `quiet <duration> ago` de `active_steps.last_activity` do Drill, já delimitado pelo `step_quiet_warning` do próprio Drill, sem outro limiar de frescor.
Um passo em execução quiet levanta `stale: <window> (pipeline step <step> quiet for <duration>; inspect the step log)` uma vez por episódio contínuo de run/step quiet, mesmo com um painel busy ou em mudança ou uma pausa declarada antiga; o modo ausente escala essa mesma evidência nomeada sem outra espera de wedge.
O monitor `ci` em execução é excluído porque esperar merge/close de PR é deliberadamente silencioso; correções de CI em execução não são excluídas.
Passos de longa duração com atividade recente, gates estacionados, execuções terminais e atividade ausente ou desconhecida não fornecem evidência de stall por passo quiet.
Uma recuperação legível de run-step limpa o marcador do episódio; uma leitura ilegível ou que não venha de run-step o preserva, e a limpeza da tarefa o remove junto com os outros registros de janela.
`tests/sq-sentry-triage.test.sh` exercita esse caminho através do helper crew-state real com fixtures de status do Drill, enquanto `tests/sq-daemon.test.sh` fixa a escalação no modo ausente.
Para uma crew ordinária que parou, a sentinela de modo ordinário primeiro superficia um acordo stale, depois aplica aquela mesma cadência a um endpoint inalterado `paused:` ou `commander-held` durável, recuperando aquela classificação de pausa apenas quando o backend reporta confiadamente seu agente morto - a menos que a exclusão terminal sem agente acima se aplique.
Vitalidade viva ou inconclusiva permanece fail-open naquela superfície inicial, então um painel que um long poll em primeiro plano mantém mudando ainda recebe sua primeira rechecagem delimitada em vez de esperar por um hash estável.
Depois disso, conteúdo de rodapé de pane em mudança não pode transformar aquela confirmação em um acordo a cada poll subsequente: o marcador de cadência estável por-chave `paused-resurfaced` (baseado em mtime, independente do conteúdo do pane) absorve acordos stale repetidos dentro da mesma janela de cadência, então no máximo uma rechecagem delimitada por cadência é emitida independentemente de quão frequentemente o hash do pane muda.
A isenção de endpoint-XO-ocioso permanece inalterada.
Seu sinal de status inicial de modo ordinário ainda superficial pelo caminho sem-verbo, enquanto o modo ausente auto-trata aquele sinal rotineiro e é dono da reconferência posterior.
Panes stale frescos usam a mesma leitura de estado-atual antes de confiar no log de status, então uma tarefa finalizada, uma execução ativa ou um worker provadamente ocupado sobrepõe uma linha antiga de log de status relevante ao comandante deixada para trás antes da validação.
Heartbeats de sem-mudança também são benignos.
Acordos absorvidos avançam seus marcadores de supressão, logam em `state/.sentry-triage.log`, e mantêm a sentinela bloqueando sem registro de fila ou turno LLM.
Após cada drain, `sq-stand-to-drain.sh` roda o mesmo guard de vitalidade que os scripts de supervisão, então uma cadeia de sentinela encerrada superficial mesmo num turno que apenas drena e trata acordos enfileirados.
Polling ordinário de sentinela, no-ops de supervisão, tempo decorrido de espera e acordos benignos absorvidos ficam silenciosos.
Uma espera externa declarada troca esse silêncio por uma reconferência limitada por janela de pausa, então uma pausa esquecida não pode permanecer invisível indefinidamente.
Arquivos de status da crew são logs append-only de eventos de acordar, não campos de estado atual.
Por isso, uma leitura de apenas a última linha por acordo pode enterrar um `needs-decision`/`blocked` anterior ainda aberto sob appends não relacionados posteriores; `sq-stand-to-drain.sh` imprime uma seção separada e unit-wide de OPEN DECISIONS em cada drain (incluindo o caminho de fila-vazia que o session-start depende), construída através do scan incremental com cursor de `sq-classify-lib.sh` usando a semântica fold canônica `status_open_decisions` para que a decisão enterrada continue superficial até ser explicitamente resolvida enquanto cada drain lê apenas novos appends do log de status.
A resolução explícita é escrita pelo ator que responde, não pelo worker ocupado: `sq-send`'s `--resolve-key` appenda a linha finalizante `resolved` na cópia local do ledger no momento da resposta, o que cobre operadores, XOs locais e XOs remotos idênticamente porque as escalações de um mate remoto alcançam aquela cópia local através do ingest de parent-replies e apenas a própria mensagem de resposta cruza o transporte.
`sq-stand-to-drain.sh` também imprime uma seção limitada e unit-wide de TEARDOWN PENDING em cada drain (incluindo o caminho de fila-vazia) para qualquer tarefa cuja última linha do log de status verifique `done:`/`failed:` enquanto seu `state/<id>.meta` ainda está presente, excluindo tarefas `kind=xo` cuja aposentadoria é de propriedade de `xo-provisioning` em vez de `bin/sq-teardown.sh`; é um lembrete puro que nunca invoca teardown em si, deixando a checagem de segurança de landed-work de `bin/sq-teardown.sh` como a única autoridade sobre se o trabalho registrado é realmente seguro para limpar.
`bin/sq-crew-state.sh <id>` é a leitura barata de estado atual para uma revisão de heartbeat acionável: ele atribui uma execução de drill, ativa ou terminal, apenas quando ela combina com a branch e identidade de código atual do operador, depois mantém aquele run-step autoritativo mesmo se o pane tiver fechado.
O cabeçalho do script é dono das regras exatas de ancestralidade do run-head.
Durante a fase de monitoramento `ci` do drill, ele também lê o tail do log de step ci porque `axi status` reporta tanto "still waiting on checks" quanto "checks green, waiting on merge" como `ci,running`.
O marcador de log ci mais recente reconhecido ganha, então monitoramento de checks-green reporta done enquanto um rearmed posterior, check-falhado ou marcador de issue retorna o operador a working.
Apenas quando nenhuma execução correspondente existe ele consulta o estado busy semântico; busy exato reporta working, idle exato permite fallback para um evento de log de status cujo verbo mapeia para um run-state reconhecido, e unknown ou pane morto fica unknown em vez de confiar num log stale.
Eventos apenas-de-decisão como `resolved` nunca se tornam estado atual nem vazam sua prosa para o detalhe de estado-atual; um que nomeia uma pausa com chave ainda aberta limpa apenas aquela pausa, então o estado real que ela mascarava volta a ser reportado.
Naquele fallback de log de status, uma espera externa declarada reporta o estado distinto `paused` com seu motivo.
O branch semântico reporta working apenas em veredito busy exato e nomeia a fonte que o produziu; um veredito unknown nunca se torna working, nunca permite o fallback do log de status e nunca se torna idle silencioso.
Para revisão read-only da unidade inteira, `bin/sq-unit-snapshot.sh --json` emite o schema `sq-unit-snapshot.v1` a partir do backlog, metadados de tarefa, estado atual da crew, sondas de endpoint, ponteiros PR/report, relatórios de recon, sumários atuais limitados de bases XO registradas, e orientação de canal de retorno de XO.
Um ponteiro PR registra se veio de metadados de tarefa, um evento de status estruturado do drill, ou um evento de status órfão, e a view humana da unidade distingue essas fontes em vez de tratar um artefato de poll aposentado como evidência de monitoramento.
O detalhe de crew-state de uma execução finalizada também carrega `risk=<low|medium|high>` quando o Drill registrou um risco de revisão, lido read-only a partir dos findings do passo de review no banco de dados do Drill porque `axi status` expõe um risco apenas enquanto a execução está parada no gate de review, e o snapshot expõe esse nível como `pr.risk`.
Um nível ausente, `unknown` ou ilegível não adiciona token ao detalhe e deixa `pr.risk` como null, e nada faz gate, bloqueia, despacha ou escreve com base nele.
`bin/sq-unit-view.sh` renderiza aquele snapshot como Markdown para humanos, enquanto `bin/sq-sitrep-snapshot.sh` fornece a projeção limitada de sitrep, então ambas as views consomem um contrato estruturado em vez de reparsar arquivos brutos da unidade.
O cabeçalho do script é dono do JSON schema exato.

### Estado atual de XOs registrados

A base validada de um XO registrado é a autoridade para o estado atual de sitrep porque é dona do inventário de metadados do filho, do resultado de estado-atual de cada filho, observações de endpoint, holds e dependências de backlog, decisões não resolvidas chaveadas, e baseline recente de Done.
A projeção cross-base original em vez disso tratava o agente XO como uma tarefa pai ordinária, então o fallback `sq-crew-state` de um XO ocioso selecionava o evento de status append-only do pai mais recente mesmo quando o estado estruturado na base registrada o contradizia.
O contrato de status-pai também exigia resolução chaveada explícita para decisões e blockers mas não para uma fase material de `working`, então um evento start poderia permanecer não-substituído depois que o backlog da base correspondente tinha movido o trabalho para Done.
Charters XO gerados rejeitam recibo genérico ou acknowledgements de start, chaveiam apenas relatórios de fase material supervisor-actionable, e fecham uma fase aberta com um estado posterior de mesma chave ou evento `resolved`, enquanto a base estruturada permanece autoritativa mesmo se aquele fechamento estiver faltando.
Leituras cross-base validam a identidade semeada e as fronteiras de diretório operacional, usam limites de tempo e saída por base, e classificam estado estruturado indisponível, malformado ou inconsistente como unknown em vez de reviver um evento pai como trabalho atual.
Quando apenas a classificação atual de um filho de posse está indisponível, a classificação da base fica unknown enquanto decisões estruturadas independentemente confiáveis, holds, registros enfileirados e landados, identidades de endpoint, contagens e proveniência permanecem disponíveis; todo outro caminho inválido permanece estrito e não expõe nenhuma dessas superfícies derivadas de filho.
Uma cauda limitada de relato-direto pode ajudar a diagnosticar uma divergência mostrando que a redação histórica do pai ainda está visível, mas é evidência suplementar não confiável porque scrollback, prompts, saída copiada, shells ociosos e prosa de agente não são estado durável.
O snapshot remove sequências de controle, retém apenas metadados de captura e flags literais de corroboração de evento, e nunca permite que evidência de terminal sobrepuje uma classificação estruturada válida.
O caminho padrão permanece local-only; enriquecimento ao vivo GitHub existe apenas atrás do opt-in `--include-prs` do sitrep.
Relay opcional integra-se com a sentinela apenas após opt-in explícito; [configuration.md](configuration.md#relay-env) é dono de seus artefatos gerados e mecânica de despacho.

No início da sessão, `bin/sq-session-start.sh` emite exatamente um bloco de supervisão por harness primário renderizado por `bin/sq-supervision-instructions.sh` a partir de `docs/supervision-protocols/`.
Aquele bloco é dono da forma viva de espera para o harness primário em execução: o hook Stop `asyncRewake` do Claude é dono de ciclos de re-arm sem tokens, Grok usa ciclos de notificação em segundo plano, Codex usa checkpoints limitados em primeiro plano, Pi e pi-signed usam as duas extensões primárias rastreadas, e OpenCode usa seu plugin TUI.
`bin/sq-sentry-arm.sh` continua sendo o wrapper verificado de arm para protocolos que o chamam; ele faz fork da sentinela como filho rastreado, verifica que está genuinamente viva com um beacon fresco de vitalidade, e imprime um status honesto `started`, `attached` ou `FAILED` com código diferente de zero.
[`sentry-continuity.md`](sentry-continuity.md#contrato-de-ciclo-da-camada-de-arm) é dona do contrato de sucessores, entrega-terminal e clean-close tipado da camada de arm.
A camada de arm registra uma linha limitada de ciclo de vida por ciclo observado em `state/.watch-cycle-exits.log`; `state/.sentry-triage.log` permanece exclusivamente o log de debug de acordos absorvidos.
Pi e OpenCode verificam a posse do lock de sessão e lançam um único sucessor singleton de seus handlers de close-de-filho antes de entregar um prompt de acordo acionável, com retry exponencial limitado para restauração falhada.
O hook `bin/sq-claude-stop-autoarm.sh` do Claude dispara a cada Stop e, quando a base é elegível e ainda precisa de supervisão, reivindica um ciclo com escopo de base, traz o wrapper de arm para primeiro plano, e traduz closes acionáveis em rewakes exit-2.
Ele suprime closes com aparência de falha quando a mesma sentinela com identidade correspondente está saudável, retenta falhas genuínas dentro de um limite, e coordena episódios de falha esgotada com o turn-end guard do Claude conforme documentado em [`turnend-guard.md`](turnend-guard.md).
[`sentry-continuity.md`](sentry-continuity.md) é dona da cobertura residual de turn-ativo do Claude e da fronteira de gating por comando de status da sentinela.
O turn-end guard existente continua sendo o backstop final para todos os cinco protocolos de engine de harness, com pi-signed compartilhando o protocolo do Pi e o modo `--claude` cooperando com a reivindicação do auto-arm.
Seu modo `--restart` sinaliza apenas a sentinela registrada no `state/.sentry.lock` da base atual, então reiniciar uma base não pode matar sentinels de XOs irmãos.
Um guard pull-based (`bin/sq-guard.sh`) avisa através da saída de ferramentas de supervisão se o checkout primário está tangleado, se trabalho, fontes process-event ou polling de Relay tem um veredito de supervisão ciente-do-modelo insalubre, ou se acordos enfileirados estão esperando serem drenados.
O script de drain chama aquele guard depois de esvaziar a fila, o que evita repetir o warning de acordos enfileirados para registros que acabou de consumir enquanto ainda avisa sobre supervisão insalubre.
Ele lidera com um banner proeminente de tangle com borda, enquanto `bin/sq-guard.sh` é dono do banner sentry-down e da política de reminder para que comandos repetidos guardados permaneçam barulhentos sem reimprimir o banner completo no mesmo episódio.
Em todo harness primário verificado, integração rastreada de hook dá à sessão primária um backstop push-based: quando trabalho, uma fonte process-event ou polling de Relay precisa de supervisão e nenhum lock de sentinela com identidade correspondente com beacon fresco está vivo, hooks diretos Stop bloqueiam e hooks passivos de turn-end forçam um follow-up limitado.
O guard cobre o primário principal e bases XO genuinamente marcadas, isenta worktrees de filhos-operador/recon, é seguro por loop para cada harness, e é documentado em [turnend-guard.md](turnend-guard.md).

Um sub-supervisor controlado por presença (`bin/sq-supervise-daemon.sh`) estende isso para supervisão ao sair: a skill `/afk` o inicia através do helper em primeiro plano rastreado `bin/sq-afk-start.sh`, depois da qual a sentinela reverte para o modo one-shot gerenciado pelo daemon e o daemon auto-trata acordos rotineiros em bash.
A sentinela e o daemon compartilham `bin/sq-classify-lib.sh` para verbos de status relevantes ao comandante, vocabulário de espera-externa-declarada e primitivas de scan de status.
Verbos terminais permanecem relevantes ao comandante, enquanto um verbo de progresso não-terminal não pode se tornar terminal apenas porque sua prosa contém um token legado de texto livre como `merged`; linhas legadas puras de texto livre permanecem compatíveis.
A sentinela always-on também usa a classificação de absorção daquela biblioteca para sinais sem-verbo e panes stale de primeira observação antes que a terminalidade do log de status seja confiável, enquanto o daemon mantém cadências distintas de reconferência de wedge e pausa-declarada.
No modo ausente, dedupe de status visto não limpa aging de possivel-wedge para progresso não-terminal, então manutenção ainda re-escala um pane ocioso inalterado no limite configurado, exceto pela exclusão terminal sem agente acima.
O daemon escala eventos relevantes ao comandante, mais uma reconferência limitada para uma pausa declarada que permanece ociosa e a evidência nomeada da era-da-pausa e de passo quiet acima, como um digest em lote e de linha única usando o kind canônico `away-supervisor` de `bin/sq-operational-input.sh` para que o Squad possa distinguí-lo estruturalmente de mensagens reais.
Seu caminho de injeção de supervisor suporta panes tmux e herdr, além de panes TUIOS por meio de um handoff nativo do Pi, com `SQUAD_SUPERVISOR_BACKEND` e `SQUAD_SUPERVISOR_TARGET` resolvidos independentemente do backend de spawn da tarefa.
Um primário Orca é entregue pelo mesmo contrato nativo de requisição/reconhecimento neutro de backend e harness (`bin/sq-supervisor-native.sh` e o receptor Pi), selecionando automaticamente a identidade de terminal emitida pelo runtime ou um override explícito, enquanto qualquer outro harness Orca recusa pelo nome antes de mutar; [`orca-backend.md`](orca-backend.md#supervisão-de-away-mode) é dono dessa seleção.
Existência do pane, checagens de busy, checagens de composer, captura e submit verificado pelo backend roteiam por `bin/sq-backend.sh`: tmux mantém o mesmo core de submit usado pelo backend de envio tmux, enquanto herdr usa estado busy nativo, confirmação de submit por agent-state nativo em baselines idle, e seu classificador de composer estrutural ciente de ANSI para guards de pending-input e fallback de submit.
Um painel de supervisor TUIOS prefere o handoff nativo do Pi: `.pi/extensions/sq-primary-away-handoff.ts` publica uma solicitação durável e enfileira um follow-up do Pi via `sendUserMessage`, adiando enquanto o Pi está ocupado, o editor tem um rascunho, ou qualquer prompt do Pi está aberto, e reconhecendo o consumo pelo próprio prompt `before_agent_start` do Pi.
Só quando esse caminho recusa o resumo cai na fila de agente do próprio daemon, e apenas num composer positivamente lido como vazio e num painel ao qual o TUIOS atribui um agente vivo; [`tuios-backend.md`](../tuios-backend.md#away-mode-supervision) é dono desse contrato.
O core de submit tmux (compartilhado `fm_tmux_submit_enter_core`) trata um pane OpenCode-ocupado + retries-esgotados + composer-ainda-pendente como um Enter enfileirado (opencode 1.18.4 aceita Enter no meio do turno e o enfileira para depois), reportado como `empty` para que o daemon e `sq-send` não re-enviem; outros harnesses (ex. Pi) mantêm o veredito `pending` porque seus indicadores de busy não provam que o Enter foi enfileirado, e um pane ocioso também mantém `pending` como swallow genuíno. O mesmo caso de busy-queue do opencode é uma lacuna conhecida no adaptador herdr e está registrado em `docs/herdr-backend.md` em vez de ser patchado aqui.
Classificação de conteúdo de composer tem um único dono compartilhado, `bin/sq-composer-lib.sh`, usado por tmux, herdr, Orca, cmux e TUIOS depois que cada adaptador realiza sua própria captura e reconhecimento de linha de composer.
O daemon injeta apenas num composer positivamente `empty`, então tanto `pending` quanto `unknown` postponem e um puro prompt de shell morto não pode receber uma escalação; a fronteira atual está em [Segurança de composer e injeção](herdr-backend.md#segurança-de-composer-e-injeção).
Backends de supervisor não suportados recusam no startup do daemon.
Entrega de escalação travada escreve `state/.subsuper-inject-wedged` e tenta um alerta ativo configurado independente-de-backend após `SQUAD_MAX_DEFER_SECS` em vez de postergar silenciosamente para sempre.
Em retorno não marcado, `bin/sq-afk-return.sh` é dono de shutdown ordenado, evidência durável de catch-up e o gate fail-closed que mantém trabalho ordinário atrás de todo bloqueador acionável vivo pelo Squad.
`sq-send.sh` seleciona um pre-Enter popup-settle para comandos slash e para invocações de skill `$...` do codex usando valores `harness=` de target roteado por metadados, depois adiciona sua própria pausa `SQUAD_SEND_SETTLE` após envios de texto bem-sucedidos para que peeks imediatos peguem o turno receptor começando; o sub-supervisor usa apenas o core de submit compartilhado e não paga aquela pausa pós-submit.
Para um alvo local não-XO de Pi ou pi-signed roteado por metadados, `sq-send.sh` primeiro oferece o texto pelo dropbox privado `state/.pi-delivery` da extensão da tarefa, que invoca `sendUserMessage(..., { deliverAs: "followUp" })` sem depender do composer estacionado.
Um Pi ocioso relata `accepted` e um turno ativo relata `queued`, e ambos apenas provam que o Pi aceitou a mensagem, então `sq-send` relata o consumo como não confirmado em vez de alegar que o worker a pegou.
A extensão acompanha um follow-up enfileirado até que o próprio turno do Pi o liste entre as mensagens de usuário consumidas, então descarta o registro pendente exatamente uma vez.
Quando um turno interrompido deixa um follow-up rastreado não consumido, a extensão o separa do editor: remove exatamente o texto restaurado preservando qualquer rascunho independente, grava um recibo `cancelled` e acrescenta um aviso de status `signal:`; quando não consegue separar com segurança, deixa o editor intacto e acrescenta um aviso `blocked:` em vez disso.
Um turno interrompido após o consumo, ou uma substituição de sessão, limpa o estado pendente sem recibo e sem aviso.
Se a extensão estiver ausente ou indisponível, `sq-send.sh` recua para o submit do backend registrado, enquanto um timeout após criar o pedido falha em vez de arriscar uma entrega duplicada.
O teardown remove o marcador do dropbox e todos os arquivos de pedido, processamento, resposta ou temporários da tarefa retirada.

## Estado busy é semântico, por adaptador

`bin/sq-busy-lib.sh` é o único dono do significado de "este worker está ocupado", e `bin/sq-busy-event.sh` é o único escritor dos registros por tarefa que ele lê.
Toda classificação retorna um veredito de busy, idle, unknown ou dead junto com a fonte que o produziu, então um consumidor ou um diagnóstico nunca pode confundir estado semântico com fallback.

Cada adaptador convertido reporta seu próprio ciclo de vida de turno através de um contrato legível por máquina que o vendor já expõe, em vez de através de texto renderizado no footer: Pi e pi-signed através de `agent_start` e `agent_settled` da extensão de propriedade do Squad confirmados por `ctx.isIdle()`, mais um evento `session_before_compact` por compactação (nunca por limite de turno interno) para que uma compactação seja visível no mesmo registro em vez de parecer agitação busy comum, OpenCode através do status semântico `session.status` de seu plugin, e Claude através dos hooks de propriedade `UserPromptSubmit`, `Stop`, `StopFailure` e `SessionEnd`.
Kimi atrás do Pi herda o ciclo de vida do Pi.
Codex e Kimi standalone classificam unknown atrás de probes explícitos até que uma fonte semântica seja verificada ao vivo para eles, e Grok mantém um fallback isolado de cauda renderizada que só pode classificar uma tarefa Grok.

Estado semântico ausente, malformado, stale, não confiável ou não verificado é unknown, nunca idle, e unknown nunca é promovido a busy também.
Consumidores ordinários de estado de tarefa agem apenas em veredito busy exato, então um worker ilegível superficia para inspeção mais próxima em vez de ser absorvido como ainda-trabalhando ou descartado como terminado.
Morte de endpoint é a única override em nível de processo e cede dead; processos filhos, CPU, estado de sleep do processo e tempos de modificação de marcador não são sinais de estado.
Arquivos `state/<id>.turn-ended` permanecem notificações de acordar, não estado atual.

Cada registro é vinculado a um token de encarnação cunhado quando a fiação da tarefa é armada, então um evento de encarnação substituída é rejeitado em vez de aplicado, e um registro deixado para trás por uma classifica unknown.
Três leitores de texto renderizado deliberadamente permanecem fora deste contrato porque respondem perguntas de entrega: a confirmação de submit e o guard de busy de painel-do-supervisor do modo ausente em `bin/sq-tmux-lib.sh`, e a observação de confirmação de entrega XO em `bin/sq-pending-reply-lib.sh`.
Todos são com escopo de harness em vez de uma união global de padrões, e nenhum é uma fonte gravada de estado de worker.

## Backends de sessão de runtime

O backend de runtime é a camada de provedor de sessão abaixo dos scripts do Squad.
Ele é dono da criação de endpoint de tarefa, captura limitada, envios de texto/chave, leituras de caminho-atual para descoberta de worktree no momento de spawn quando o backend não cria o próprio worktree, fallback de lookup de janela-viva, sondas de vitalidade de processo-agente onde verificado, e teardown de endpoint.
`bin/sq-backend.sh` centraliza seleção de backend, helpers de `state/<id>.meta`, validação de identidade de cleanup apenas-meta, resolução de seletores e despacho de operação; `bin/backends/tmux.sh` é o adaptador de referência verificado ([`docs/tmux-backend.md`](tmux-backend.md)), e `bin/backends/herdr.sh` (P2), `bin/backends/zellij.sh` (P3), `bin/backends/orca.sh` (P4), `bin/backends/cmux.sh` (P5) e `bin/backends/tuios.sh` (P6) são adaptadores experimentais de spawn de tarefa.
[`configuration.md`](configuration.md#backend-de-runtime-configbackend--squad_backend) é dona da precedência e autorização de seleção de backend para novos spawns.
Auto-detecção de runtime é mais-interno-primeiro: `$TMUX` ganha sobre `HERDR_ENV=1`, que ganha sobre o marcador principal `CMUX_WORKSPACE_ID` e sinais documentados de fallback do cmux; herdr ou cmux auto-detectados imprimem um aviso one-time de opt-out, tmux auto-detectado fica silencioso, e zellij, orca e TUIOS nunca são auto-detectados (apenas seleção explícita).
Nomes de backend desconhecidos falham ruidosamente.
Por compatibilidade, tarefas tmux padrão não escrevem `backend=tmux`; todo leitor trata campo `backend=` ausente como `tmux`.

`sq-sentry.sh` decide o estado busy de cada janela através do contrato semântico acima em vez de fazendo polling do backend por texto renderizado.
O veredito nativo `agent.get` do Herdr ainda participa, mas apenas como evidência de atividade: um `busy` nativo é aceito quando a tarefa não tem registro próprio, enquanto um `idle` nativo não é, porque `agent.get` reporta estado de geração e lê idle enquanto um worker bloqueia em sua própria chamada de ferramenta longa em foreground.
tmux, zellij, orca e cmux não expõem nenhuma primitiva nativa de busy verificada, então uma tarefa nesses backends é classificada puramente a partir do registro de ciclo de vida próprio do adaptador.
O próprio relatório de agente do TUIOS participa: um `working` nativo é aceito como busy e um `needs_input` ou `errored` nativo como blocked quando a tarefa não tem registro próprio, então um operador TUIOS bloqueado nunca é lido como trabalho comum.
Aquele loop de polling ainda é a fonte de eventos padrão para backends sem push events nativos, então isso permanece uma extração da abstração em vez de uma reescrita da sentinela.
Para sessões Herdr capazes, a mesma sentinela substitui seu terminal sleep por uma espera limitada de evento nativo que imediatamente superficia `blocked`; [Push events e fallback de polling](herdr-backend.md#push-events-e-fallback-de-polling) é dona do mecanismo e gates de capacidade atuais, enquanto [verificação de backend de runtime](../verification/runtime-backends.md#native-blocked-event) é dona da evidência ativa.

### Matriz de capacidade: a escalada quando uma pessoa é necessária

A resposta de cada backend para "uma pessoa é necessária" fica em exatamente uma de três classes de capacidade, todas consumindo o MESMO registro de transição normalizado e a mesma tabela de política (`bin/sq-transition-lib.sh`); nenhum backend re-codifica o mapeamento status->ação por conta própria.

| Classe | Backends hoje | Mecanismo | Latência |
| --- | --- | --- | --- |
| Push-capable | Herdr; TUIOS quando o catálogo do daemon anuncia um `subscribe` verificado | Subscrição de evento nativo (`pane.agent_status_changed` no Herdr, o verbo catalogado no TUIOS); cada evento dispara uma leitura autoritativa do estado atual antes de a política rodar | Sub-segundo, ou limitada por `SQUAD_POLL` em versões do TUIOS sem o verbo |
| Apenas polling | TUIOS sem `subscribe` catalogado; Orca | Sem stream de eventos: `fm_backend_tuios_poll_transition` de `bin/backends/tuios.sh` reconcilia o nível do estado atual do daemon, e `fm_backend_orca_poll_transition` de `bin/backends/orca.sh` lê a observação `agentWait` do terminal exato do Orca, no mesmo registro, no poll ordinário por-janela da sentinela | Limitada por `SQUAD_POLL` |
| Não consegue reportar | tmux, zellij, cmux | Nenhum veredito nativo de blocked de qualquer tipo | Nunca dispara - nenhum palpite a partir de texto renderizado do pane |

`fm_backend_has_push` e `fm_backend_can_poll_transition` (`bin/sq-backend.sh`) são os dois predicados de capacidade que um consumidor checa; um backend que responde falso aos dois cai no poll ordinário de stale/wedge inalterado, que é o backstop fail-closed permanente para toda a matriz.
O dedupe do TUIOS é chaveado em mais que só a borda de status: ele hasheia o kind e a message do prompt (sua última linha quando o corpo da message é vazio) para que um pane que vai de um prompt `needs_input` direto para um diferente - sem leitura não-bloqueada intermediária - ainda re-escale, enquanto o prompt idêntico que permanece nunca repete um wake. Essa mesma checagem roda depois de eventos nativos e durante o polling de fallback.
Opções numeradas são deliberadamente excluídas daquela identidade, então um poll posterior que meramente superficie opções para o mesmo prompt não re-arma; o resumo renderizado (`fm_backend_prompt_summary`) é produzido apenas no momento do wake para a notificação.
Orca chaveia a mesma identidade no kind e no texto de mensagem do registro de espera, nunca no registro cru, então um campo volátil não verificado não pode transformar um prompt que permanece numa escalada repetida.
Quando o Orca não expõe nenhuma observação de espera legível, ele nunca é lido como clear: antes de qualquer escalada o terminal apenas segue com o poll ordinário abaixo, e um terminal já escalado mantém seus marcadores e é deliberadamente mantido fora da supervisão ordinária de stale/wedge até que uma leitura legível prove que a espera acabou.
O consumidor (`handle_push_transition` em `bin/sq-push-transition-lib.sh`) pede ao backend produtor aquele prompt no momento do wake em vez de alargar o registro compartilhado, já que a maioria dos produtores (herdr) não tem nenhum a oferecer; a razão que isso produz lê `stale: <window> (<backend>: agent blocked - <prompt> - waiting on human, escalated immediately, not via wedge timer)`, com o segmento `- <prompt>` presente apenas quando o backend forneceu um.
A sonda mais profunda de vitalidade de processo-agente no início da sessão é separada daquele poll de busy-state: tmux e Herdr têm classificadores verificados para recovery de XO, Zellij permanece não verificado, e Orca, cmux e TUIOS não suportam spawns de XO.
Herdr é experimental e pode ser selecionado explicitamente ou por auto-detecção de runtime: FOB continua sendo seu provedor de worktree, [`herdr-backend.md`](herdr-backend.md) é dona do setup e limites de segurança atuais, e [`verification/runtime-backends.md`](../verification/runtime-backends.md#herdr) é dona da evidência empírica ativa.
Herdr usa uma aba por tarefa; [Monitoramento e task containers](herdr-backend.md#monitoramento-e-task-containers) é dona do posicionamento de workspace vinculado ao launcher, o fallback apenas-de-rótulo e o escopo de recovery.
Sua projeção de apresentação default-on pode colocar uma tarefa nova e limpa num workspace descartável sem mudar autoridade de endpoint ou posse de ciclo de vida; [Presentation spaces](herdr-backend.md#presentation-spaces) é dona desse design condicional, do piso de versão Herdr que seu default não configurado está condicionado, e de sua limpeza estreita de shell-restaurado local-à-base no início de sessão travado.
Zellij é experimental e selecionado apenas explicitamente: FOB continua sendo seu provedor de worktree, [`zellij-backend.md`](zellij-backend.md) é dona do setup e limites atuais, e [`verification/runtime-backends.md`](../verification/runtime-backends.md#zellij) é dona da evidência empírica ativa.
O formato de container do Zellij é mais simples que o do herdr: uma sessão `Squad` compartilhada, uma aba por tarefa, sem divisão de workspace por base; títulos de aba visíveis são delimitados pelo rótulo da base ativa mais um hash curto do caminho `SQUAD_ROOT` resolvido.
Orca é experimental e selecionado apenas explicitamente: Orca é dono tanto do worktree quanto do ciclo de vida do terminal, registra o workspace hospedeiro em `orca_host_workspace_id=`, o worktree da missão em `orca_worktree_id=` e a aba da missão em `terminal=`, e remove worktrees através de `orca worktree rm` apenas após as checagens normais de teardown do Squad passarem.
[`orca-backend.md`](orca-backend.md) é dona do comportamento e limitações atuais, enquanto [`verification/runtime-backends.md`](../verification/runtime-backends.md#orca) é dona da evidência smoke ativa.
cmux é experimental, primeiro GUI, exclusivo de macOS, e pode ser selecionado explicitamente ou por auto-detecção de runtime a partir de seu marcador principal `CMUX_WORKSPACE_ID` mais sinais documentados de fallback: FOB continua sendo seu provedor de worktree, [`cmux-backend.md`](cmux-backend.md) é dona do setup e limites atuais, e [`verification/runtime-backends.md`](../verification/runtime-backends.md#cmux) é dona da fonte e evidência ao vivo ativas.
O formato de container do cmux é um workspace por tarefa com uma superfície, sem divisão de container por base; títulos de workspace são delimitados pelo rótulo da base ativa mais um hash curto do caminho `SQUAD_ROOT` resolvido, e spawns `--xo` são recusados, espelhando o Orca.
TUIOS é experimental e selecionado apenas explicitamente: usa uma sessão existente explicitamente configurada, adiciona janelas de tarefa sem focá-las, e grava ids opacos exatos de janela para roteamento e limpeza. FOB continua sendo seu provedor de worktree, e spawns `--xo` são recusados; [`tuios-backend.md`](../tuios-backend.md) é dona do setup, aquisição de worktree, entrega agent-aware, mapeamento de estado e prompt, recovery de restart e limites, enquanto [`verification/runtime-backends.md`](../verification/runtime-backends.md#tuios) é dona da evidência ao vivo e do que permanece não verificado.
Suporte ao Codex App está registrado em `docs/codex-app-backend.md`; não é selecionável como backend de runtime.

## Worktrees, não branches no seu checkout

Operadores nunca tocam intencionalmente seu clone de projeto; [fob](https://github.com/runecraftai/squad/tree/main/packages/fob) faz pool de worktrees limpos para tarefas tmux, herdr, zellij, cmux e TUIOS, enquanto Orca cria seus próprios worktrees para `backend=orca`.
Para trabalho ship e recon, `sq-spawn.sh` recusa lançar a menos que o caminho da tarefa resolvido seja uma raiz real de git worktree que seja distinta do checkout primário do projeto.

O repo do Squad tem uma exposição extra porque pode despachar operadores para trabalhar nele.
Seu checkout operacional (`SQUAD_ROOT`) e os worktrees descartáveis de operador são todos linked git worktrees do mesmo repositório, então o discriminador válido é estado de branch, não se o checkout é linked.
O checkout primário está saudável em sua branch default, e linked worktrees ou bases XO estão saudáveis com HEAD detached.
Apenas uma branch não-padrão nomeada checked-out em `SQUAD_ROOT` é um tangle de worktree.

`sq-tangle-lib.sh` resolve a branch default a partir de `origin/HEAD`, depois `main` ou `master` local, e classifica aquela branch primária não-padrão nomeada como o tangle.
`sq-guard.sh` imprime o comando de reparo na próxima mutação unitária, enquanto `bin/sq-session-start.sh` reporta a mesma condição através de bootstrap como uma linha `TANGLE:` no início da sessão.
Se outra sessão viva segura o lock da unidade, ambas as superfícies mantêm o alarme mas mudam para phrasing read-only sem comando de reparo.
Briefs de ship também dizem ao operador para verificar `pwd -P` e `git rev-parse --show-toplevel` antes de criar `sq/<id>`, depois parar com status bloqueado se pousou no checkout primário.

## Fronteira de autoridade do gate drill

O próprio gate drill do Squad roda agentes dentro de um checkout que também contém a identidade de unidade-comandante em `AGENTS.md`, então execução do gate precisa de uma fronteira de autoridade separada do isolamento ordinário de worktree de operador.
O `.drill.yaml` rastreado configura `disable_project_settings: true`; drill honra essa configuração apenas da cópia confiável da branch default, então uma branch pushada não pode habilitar suas próprias instruções de projeto durante validação.
Independentemente, `sq-spawn.sh`, `sq-send.sh`, `sq-teardown.sh` e `sq-retired-missions.sh` carregam `bin/sq-gate-refuse-lib.sh` e saem com status 3 antes de mutação da unidade quando o marcador de ambiente do gate está presente ou o checkout atual corresponde à topologia padrão de gate-drill do repo.
Um checkout primário normal ou worktree de operador não tem nenhum dos dois sinais e permanece inafetado.
O cabeçalho do helper é dono da detecção exata de sinais, limitação de base-relocada, bypass de test-harness e relação com o guard de HEAD-continuity do drill.

## Dois formatos de tarefa

Tarefas strike mudam projetos e ship por modo de projeto (`drill`, `direct-PR` ou `local-only`); tarefas recon deixam relatórios independentes de investigação em `data/<id>/report.md` e nunca push.
O contrato de intake e autoridade em `AGENTS.md` é dono de quando pesquisa separada de recon é justificada.

## Perfis de despacho

Despacho de operador e recon pode ficar no harness estático do operador resolvido por `config/crew-harness`, ou pode usar perfis de despacho locais em `config/crew-dispatch.json`.
O arquivo de despacho é intencionalmente baseado em julgamento: Squad lê as regras em linguagem natural no intake, escolhe a regra de melhor correspondência, resolve arrays de perfil por conta própria a partir da saída atual de quota sob o limite de intake da seção 4 do `AGENTS.md` e do procedimento de seleção `quota-array-dispatch`, e passa apenas os eixos concretos `--harness`, `--model` e `--effort` para `sq-spawn.sh`.
Os scripts shell validam o formato JSON, rejeitam esforços mistos para um harness dentro de um array de perfil, conferem combinações verificadas de harness/esforço, e conferem existência de id de modelo contra a própria listagem de modelos do harness, mas não parseiam intenção de tarefa, não casam regras em linguagem natural, e não são donos da seleção de array.
O passo de bootstrap de início da sessão mantém configuração de despacho válida silenciosa a menos que fatos verbose estejam habilitados e superficie uma linha concisa de config-inválida quando validação falha.
Quando o arquivo existe, `sq-spawn.sh` recusa launches de operador e recon sem harness explícito, então `config/crew-harness` é apenas automático quando nenhum arquivo de perfil de despacho está ativo.
Launches de XO são isentos porque resolvem o harness XO e qualquer token opcional de modelo ou esforço XO em vez disso.
Valores de esforço não suportados ainda são registrados em metadados de tarefa quando passados para `sq-spawn.sh`, mas o template de launch omite qualquer flag de esforço que o harness selecionado não aceita.
Isso mantém spawn launch compatível entre claude, codex, opencode, pi, pi-signed, grok, kimi e muse enquanto preserva o perfil solicitado para auditoria posterior.

## XOs opcionais

`data/XOs.md` registra XOs persistentes com escopos em linguagem natural, listas de clone de projeto e caminhos de base.
Uma rota local aponta diretamente para sua base, enquanto uma rota remota adiciona um alias SSH e raiz de código Squad remota para que a base inteira e todo seu trabalho filho fiquem naquele host.
Posicionamento remoto fixa o agente second-mate remoto no Herdr enquanto deixa a seleção de backend de worker da base remota independente, e todo comando `sq-on` não-doctor de primário-para-remoto roda através do job worker de propriedade da conta remota em vez do processo SSH ou um pane Herdr.
[`remote-XOs.md`](remote-XOs.md) é dona do setup, suprimento-de-origem, transporte, relay, falha e comportamento de aposentadoria atuais.
`sq-home-seed.sh` provisiona uma base isolada local, clona os projetos listados baseados em PR nela, inicializa projetos `drill` recém-clonados, copia o charter para `data/charter.md`, e `sq-spawn.sh --xo` o lança pelo mesmo caminho de provedor de sessão e arquivo de status que qualquer relato direto.
Para um domínio cujo assunto é o próprio repo do Squad, um seed deliberado `--no-projects` cria uma base sem projeto cujos operadores pegam worktrees em pool desse repo em vez de clones separados.
O sinal não pode ser misturado com nomes de projeto nem omitido acidentalmente, e uma base populada não pode ser convertida in-place; o contrato completo de seed está em [configuration.md](configuration.md#rotas-de-xo-dataxosmd).
Posicionamento de XO e filhos do Herdr segue o contrato de vinculação ao launcher em [Monitoramento e task containers](herdr-backend.md#monitoramento-e-task-containers).
Quando semeado com `-`, a base é um arrendamento durável do fob sob o id XO, então sobrevive sem nenhum processo vivo e não é reciclada por posteriores `fob get` ou poda.
Aposentadoria ou rollback de seed devolve a base arrendada; restart/recovery normal a mantém arrendada.
Se devolver o arrendamento falhar durante o teardown, Squad deixa a rota e base intactas em vez de esconder um arrendamento ainda segurado.
Seed é transacional: se validação, clonagem, inicialização ou atualização de registro falhar, briefs gerados, novas bases, novos clones de projeto e edições de registro são revertidos.
Projetos `local-only` ficam com o principal sargento de arm porque mergem no checkout principal local em vez de um caminho de PR com suporte remoto.
O mesmo projeto pode aparecer em múltiplas bases XO quando seus escopos diferem, como triagem de issues versus desenvolvimento de feature.
XOs são ociosos por padrão: depois que startup recovery reconcilia apenas trabalho já em sua própria base, uma fila vazia espera silenciosamente por tarefas roteadas, e eles nunca iniciam surveys ou auditorias por conta própria.
Quando chamado com `SQUAD_BASE=<esta-base-Squad>` ou quando `SQUAD_BASE` já está definido para a base Squad ativa, pedidos `sq-send.sh` roteados por metadados para um `kind=xo` vivo usam o carrier `from-squad` compatível-com-charter-vivo de propriedade de `bin/sq-operational-input.sh`, então o XO retorna respostas concisas através de linhas de status e respostas detalhadas através de docs mais ponteiros de status em vez de responder apenas em seu próprio chat.
O pai guarda cada pedido marcado contra um relatório correlacionado ausente sem ler a conversa do XO; `bin/sq-pending-reply-lib.sh` é dono do contrato de correlação, recovery, escalação e retenção.
Envios explícitos com target de backend e digitação direta humana permanecem sem marca, então intervenção do comandante num painel XO permanece conversacional.
Depois de semear um XO, `sq-backlog-handoff.sh` valida o handoff específico da unidade, depois delega atomicamente movimentos de itens enfileirados já julgados e em escopo para `sq-tasks mv` para que a fila do domínio comece no lugar certo.
Rotas remotas movem aquele conjunto com dependências fechadas para um outbox não-dispatchable de formato de backlog antes da transferência, depois usam receive remoto idempotente sob o próprio lock do backlog de destino.
O outbox é o registro completo de retry, então nenhum journal de duas fases ou retry em nível de transporte é necessário.
Um host remoto inalcançável é unknown em vez de morto, preserva sua rota e trabalho durável, e nunca é falhado-over ou relançado localmente.
Panes XO ociosos são saudáveis; teardown é explícito e recusa enquanto a base XO tem trabalho em andamento a menos que o comandante tenha aprovado descarte com `--force`.

Bases XO convergem conservadoramente para a versão e material herdado local declarado do primário no lançamento e durante o início de sessão travado.
A skill [`xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md) é dona do sync completo protegido, propagação, nudge e contrato de push de material local no meio da sessão.

Agentes XO podem rodar num harness verificado diferente dos operadores.
`config/xo-harness` controla o harness de lançamento XO do primário e pode também carregar tokens opcionais de modelo e esforço como `<harness> [<modelo>] [<esforço>]` na primeira linha não vazia e não-comentário.
Uma linha de harness pura continua sendo apenas-harness, então arquivos existentes `config/xo-harness` mantêm seu comportamento anterior.
Quando o token de harness não está definido ou é `default`, o lançamento recua para `config/crew-harness`, depois para o próprio harness do primário, e os tokens de modelo e esforço são ignorados.
Esses tokens opcionais são relidos em cada spawn ou respawn de XO e são sobrepostos por flags explícitas por-spawn de `--model` ou `--effort`.
Para uma rota local, um harness explícito por-spawn ou comando de lançamento bruto não herda tokens de modelo ou esforço de `config/xo-harness`.
Rotas remotas aceitam apenas adaptadores de harness verificados e rejeitam comandos de lançamento brutos.
`config/crew-harness` continua sendo o harness do operador e é herdado em bases XO.
`config/crew-dispatch.json` também é herdado; XOs usam os mesmos perfis de despacho em linguagem natural quando spawnam seus próprios operadores.
A skill [`xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md) é dona da allowlist completa de material herdado local e contrato de propagação.

O contrato de linha `data/XOs.md` é de propriedade da skill [`xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md#routing-table), e as variáveis de ambiente XO estão documentadas em [configuration.md](configuration.md).

## Modos de entrega são explícitos por tarefa

Tarefas `drill` rodam o pipeline completo de validação, tarefas `direct-PR` abrem PRs sem aquele pipeline, e tarefas `local-only` ficam locais até que o Squad execute uma aprovação de merge fast-forward.
Modo e postura `yolo` de cada tarefa são decisão do Squad no intake e são passados explicitamente para `bin/sq-brief.sh`, `bin/sq-spawn.sh` e `bin/sq-promote.sh`, que recusam uma tarefa strike que não os carrega.
Um brief de ship registra seu modo como uma linha fixa legível por máquina e o spawn recusa lançar num modo diferente, então as instruções do worker e a entrega registrada da tarefa não podem divergir.
`data/projects.md` registra a postura de pé de cada projeto e a flag opcional `+yolo` como default do comandante e como contexto para aquela decisão, incluindo a política condicional `drill-prod-only`; um spawn de ship que cai abaixo do rigor registrado imprime um aviso de desvio e continua.
`bin/sq-project-mode.sh` continua sendo o parser de registro para consumidores mecânicos que não têm tarefa em mãos: o skip `local-only` do unit sync, a recusa do base seeding e a inicialização do drill.
Quando um caminho de entrega selecionado requer um diff, `bin/sq-review-diff.sh` atualiza a base autoritativa e, quando metadados de tarefa registram `pr=`, sempre busca e compara contra `refs/pull/<n>/head` por padrão (`pr_head=` registrado é apenas um fallback offline) antes de recuar para a branch local com um warning.
Para repos de projeto-alvo entregues através de seu próprio pipeline de drill, commits sob `.drill/evidence/` são a evidência de validação visualizável no PR do pipeline e são esperados ficar na branch do operador até que o design de hospedagem de evidência mude.
O próprio repo do Squad é a exceção: seu diretório `.drill/` é estado local, fica gitignored, e é rejeitado pelo CI se rastreado.
Merge de tarefas baseadas em PR passa por `bin/sq-pr-merge.sh`, que compara um `pr_head=` registrado com o head fresco do forge quando presente e usa o head fresco como base de comparação quando não há registro e só registra `pr=` e o `pr_head=` confirmado através de `bin/sq-pr-check.sh` depois que `sq-gh pr merge` tem sucesso. Uma vez registrado aquele landing, derruba a tarefa landada com `bin/sq-teardown.sh`; uma recusa do teardown é reportada como warning e nunca muda o sucesso do merge, porque o landing já é autoritativo.
O helper requer uma URL completa `https://github.com/<dono>/<repo>/pull/<n>`, invoca `sq-gh pr merge <n> --repo <dono>/<repo>` com `--expected-head <sha-registrado>` apenas quando há um head registrado, usa `--squash` por padrão, preserva flags explícitas de merge-method, e rejeita URLs malformadas, `--auto` ou `--disable-auto`, ou flags de override de repo e de head antes de tocar no estado de merge; `sq-gh pr merge` relê o PR e recusa em head alterado, check falhando ou ilegível, ou PR que não esteja `MERGEABLE` antes de vincular o merge àquele SHA exato, e recusa ainda um check pendente a menos que um enfileiramento `--auto` standalone tenha sido pedido, caso em que apenas branch em conflito, check falhando ou dado de check ilegível ainda recusam, reporta como enfileirado um merge que o GitHub enfileirou em vez de concluir, e só registra como landado quando uma releitura fresca confirma `MERGED`, então uma recusa deixa os metadados da tarefa intactos. Uma URL de merge request GitLab bem formada (veja [docs/gitlab-merge-sentry.md](gitlab-merge-sentry.md)) também é recusada, explicitamente, em vez de ser enviada ao forge errado.
Teardown é fail-closed para worktrees de ship: worktrees sujos recusam, e trabalho commitado deve ser landado antes que o worktree seja devolvido.
O cabeçalho de [`bin/sq-teardown.sh`](../../bin/sq-teardown.sh) é dono das provas de landed-work, fallback de PR-discovery e procedimento de recovery de lock obsoleto.

## Relay opcional

Relay é presença opt-in para o bot compartilhado `@mySquad` em ambas as superfícies públicas que suporta, X e Discord.
Um usuário habilita colocando `SQX_PAIRING_TOKEN` no `.env` gitignored da base Squad; `SQX_RELAY_URL` é opcional e tem padrão `https://mySquad.io`.
Aquele token é autorização permanente para o Squad responder menções públicas e agir autonomamente sobre pedidos normais e reversíveis de menção.
Pedidos destrutivos, irreversíveis ou de segurança sensível são escalados para confirmação por canal confiável em vez de executados a partir de uma menção pública.
O relay usa roteamento dono-só: uma menção entregue a uma base é do dono daquela base, enquanto contexto de thread-pai pode ainda incluir outras contas públicas.
No passo de bootstrap de início de sessão travado, aquele token cria os artefatos de polling e cadência de sentinela descritos na [Referência de configuração do Relay](configuration.md#relay-env).
Sem o token, o passo de bootstrap de início de sessão travado remove aqueles artefatos no opt-out e de outra forma fica silencioso, então usuários não-Relay não veem mudança de comportamento.
Menções recentemente oferecidas são armazenadas como `state/x-inbox/<request_id>.json` e acordam o Squad uma vez por request ID retido; a [Referência de configuração do Relay](configuration.md#relay-env) é dona do offer-marker durável e contrato de re-offer.
A skill agent-only `relay-respond` drena aquele inbox, usa contexto de post-pai `in_reply_to` para continuidade conversacional, classifica cada menção como pedido acionável, pergunta, ou puro reconhecimento, e submete replies seguros-público através de `bin/sq-x-reply.sh`.
Quando uma reply tem um artefato visual real, `--image <path>` anexa um PNG, JPEG, GIF, WebP, BMP ou TIFF local ao objeto de imagem opcional `{media_type,data_base64}` do relay.
Pedidos reversíveis acionáveis rodam pelo intake normal, backlog, despacho, investigação ou ciclo de vida ship do Squad.
Trabalho que completa no turno de resposta ganha uma reply de resultado.
Trabalho que spawna uma tarefa de execução mais longa ganha uma reply de reconhecimento primeiro; `bin/sq-x-link.sh` registra `x_request=`, `x_request_ts=`, `x_followups=0` e contexto opcional de reply-platform no `state/<id>.meta` daquela tarefa, enquanto contexto por-request durável preserva a plataforma original e orçamento independentemente de links de tarefa e limpeza de inbox.
Acordeos de marcos posteriores usam `bin/sq-x-followup.sh` para postar até três follow-ups seguros-público através do endpoint `connector/followup` do relay, terminando com um `--final` para trabalho comum vinculado ao Relay. Uma commitment prometida-final tipada é dona de sua reply terminal através de `bin/sq-public-followup.sh`; depois que seu recibo é validado, `bin/sq-x-followup.sh --clear <task-id>` remove qualquer link legado sem postar outra reply.
A [Referência de configuração do Relay](configuration.md#relay-env) é dona do contrato exato de retenção de contexto, resolução de plataforma e postagem fail-safe.
Se recovery re-links o mesmo pedido de relay a uma tarefa sucessora, `sq-x-link.sh --carry-count <n> --carry-ts <epoch> --carry-platform <x|discord> --carry-max <n>` preserva a contagem consumida de follow-up, janela original de 7 dias, e orçamento de split de reply em vez de conceder um orçamento local fresco ou recuar para a plataforma errada.
O helper de follow-up encaminha `--image <path>` para o mesmo cliente de reply quando um follow-up precisa de imagem.
Cada follow-up é limitado por uma janela local de 7 dias e um cap de 3 posts; um post não-final bem-sucedido incrementa o contador e mantém o link, enquanto `--final`, atingir o cap, a janela expirar, ou o próprio relay rejeitar um binding esgotado todos o limpam, e o helper é pulado para tarefas que não se originaram de uma menção Relay.
Puros reconhecimentos ou menções sem nada para responder são dispensados através de `bin/sq-x-dismiss.sh`, que chama o endpoint `connector/dismiss` do relay e não posta texto, depois o arquivo local de inbox é limpo.
Reps concisas ficam como mensagens únicas não numeradas; replies genuinamente longas são splitadas pelo cliente em threads numeradas e limitadas usando o orçamento de reply da plataforma alvo, com `texts` carregando os chunks ordenados para o relay.
Split preserva limites de código-entreletras, parágrafo, linha e palavra quando possível.
Se uma imagem é anexada a uma reply dividida, o relay a coloca apenas na primeira/mensagem abritória e deixa os chunks posteriores como texto.
Para teste de preview, `SQX_DRY_RUN` faz `sq-x-reply.sh` e `sq-x-dismiss.sh` pularem a chamada de post público ou dismiss e registrarem o payload que seria em `state/x-outbox/`, incluindo `texts` quando a reply seria uma thread e um marcador `endpoint` quando o preview é um follow-up de conclusão ou dismiss, enquanto o resto do loop poll -> compose -> postaria ainda funciona.
Imagens anexadas são registradas como metadados compactos `{media_type, bytes, source_path}` no dry-run em vez de bytes base64.
Relay permanece camada sobre o mecanismo de check existente sem mudar seu comportamento de tratamento de requests.

Uma reply pública *final* prometida é um compromisso mais forte que um follow-up de marco, porque esquecê-la é publicamente visível.
Ela portanto não é carregada em memória conversacional de forma alguma: intake a transforma em uma obrigação `kind=public-followup` tipada de propriedade de `sq-tasks public-followup`, e todo passo posterior lê aquela obrigação do disco.
A fronteira do mecanismo é deliberadamente estreita.
`sq-tasks` é dono da máquina de estados de obrigação e é a única coisa que valida a base de origem, id de trabalho, geração, schema, resultado e deliverables de um resultado terminal.
`state/x-context/` permanece o único dono do contexto privado completo da request.
`bin/sq-x-reply.sh` permanece a única coisa que posta.
`bin/sq-public-followup.sh` compõe os três e não adiciona nada próprio além do gate de ativação, um inbox privado de eventos terminais e a sequência idempotente de entrega.
Trabalho roteado para outra base reporta um resultado terminal *tipado* através de `bin/sq-public-followup-emit.sh`; Squad nunca recupera a base de origem, id de trabalho, resultado ou deliverables parseando uma sentença `done:` em formato livre, e o filho nunca aprende a thread.
Porque o id de um evento terminal é derivado de sua tupla de identidade em vez de gerado, reports duplicados e replay de restart convergem sem coordenação.
Reconciliação usa o poll de relay existente e o digest de início de sessão em vez de uma nova sentinela, daemon ou timer, e ambos são condicionados ao mesmo contrato de ativação `.env` para que uma base que nunca optou pelo relay não execute nenhum dele.
A [Referência de configuração do Relay](configuration.md#respostas-públicas-prometidas-statepublic-followup) é dona do contrato voltado ao operador, e a skill `relay-respond` é dona do procedimento.

## Conhecimento de projeto pertence a projetos

Conhecimento durável e intrínseco do projeto do agente vive em cada `AGENTS.md` commitado do projeto, com `CLAUDE.md` como symlink.
Briefs de ship pedem aos operadores para criar ou atualizar esses arquivos pelo caminho normal de entrega; `data/projects.md` permanece um registro privado fino.
Cada `AGENTS.md` de projeto carrega uma seção curta de autogovernança `## Maintaining this file`; `bin/sq-ensure-agents-md.sh` é dono da redação canônica e a injeta idempotentemente ao criar o esqueleto, promover um `CLAUDE.md` existente, ou reconciliar um `AGENTS.md` existente que ainda carece dele.
Ele recusa um arquivo de memória real com variante de caixa como um `agents.md` em minúsculas, cujo symlink `CLAUDE.md` carregaria um target literal maiúsculo que dangle em filesystem com discriminação de caixa, e superficia a divergência para reconciliação manual.
A regra completa de posse - o que é intrínseco ao projeto versus privado da unidade, e como o Squad mantém os dois separados sem escrever em clones de projeto - é de propriedade de [`AGENTS.md`](../../AGENTS.md) (gestão de projeto e conhecimento).

## Roteamento de memória operacional

`/debrief` varre a sessão atual em busca de conhecimento durável que só existe na conversa e roteia cada achado para a base de disco mais específica.
Preferências do comandante do domínio da base vão para `data/commander.md`, preferências compartilhadas cross-domain do comandante vão para `data/commander-shared.md` da base primária, fatos operacionais e gotchas locais-à-unidade vão para `data/learnings.md` local-à-base, conhecimento intrínseco do projeto vai pela entrega normal do operador para o `AGENTS.md` commitado daquele projeto, e notas específicas de tarefa ou próximos passos não terminados vão para o backlog.
A curadoria de memória, de propriedade de `learnings-curation` e invocada por `/debrief`, usa inspect-then-update: lê o destino atual primeiro, depois consolida, reduz e roteia descobertas in-place em vez de appendar por padrão.
Notas específicas de tarefa usam `sq-tasks show <id> --full` seguido de `sq-tasks update <id> --body-file <caminho>`, adicionando `--archive-body` quando o corpo anterior deve permanecer recuperável.
Conhecimento generalizável do Squad vai para docs rastreados compartilhados pelo pipeline normal de PR; o `/debrief` interno ao Squad deliberadamente nunca armazena achados em nenhum dos diretórios de skill.
Invocado numa base primária, `/debrief` então propaga a mesma varredura para cada XO registrado, enumerado através de `bin/sq-debrief-cascade.sh`: cada base é contabilizada e curada contra sua própria cota de startup-memory, um XO vivo varre sua própria sessão, e uma base lenta ou inalcançável é reportada como exceção em vez de bloquear o primário.

## Clones locais permanecem frescos

O estágio de rede diferido do início de sessão travado, teardown baseado em PR, e tratamento de acordo de PR mesclado atualizam clones de projeto com suporte remoto quando o clone é seguro para mover.
Atualizações no momento de acordo podem mirar um único clone por nome de projeto, então a base primária também se atualiza quando um XO reporta merge de sua própria base.
Clones limpos de branch default fazem fast-forward para `origin/<default>`, e um HEAD detached limpo sem commits únicos é re-attachado à branch default antes que o mesmo caminho de fast-forward rode.
Clones sujos, branches não-default, HEADs detached com commits únicos, defaults divergentes, e branches default checked-out em outro worktree são reportados como `STUCK:` com sua contagem de atraso e deixados intactos.
Fetches bloqueados por um `.git/packed-refs.lock` órfão usam retries limitados e removem o lock apenas quando a prova compartilhada de staleness provar que está abandonado; [configuration.md](configuration.md#toolchain) é dona dos detalhes de recovery e knobs de tuning.
Projetos local-only, clones sem origin remoto, e falhas de fetch permanecem skips benignos.
A atualização também poda branches locais cujo remote se foi e que nenhum worktree ainda precisa.

## Self-updates permanecem seguros

`/updatesquad` faz fast-forward do repo Squad em execução e bases XO registradas a partir de `origin`, depois relê instruções atualizadas e cutuca XOs atualizados sem tocar em clones de projeto.
Para uma rota remota, a raiz de código configurada atualiza de sua própria origem naquele host antes que a base persistente faça fast-forward para o commit da raiz de código.
O update é somente-fast-forward: alvos sujos, divergentes, offline e off-default são reportados e deixados intactos.
Bases locais compartilham o helper de fast-forward protegido, enquanto updates remotos delegam a mesma decisão de segurança ao host configurado através do transporte genérico.
A mecânica é de propriedade da skill `/updatesquad` e do manual operacional do Squad em [`AGENTS.md`](../../AGENTS.md) (self-update).

## À prova de restart

Estado da unidade vive no backend de provedor de sessão de cada tarefa (tmux por padrão rígido, herdr ou cmux quando selecionado ou auto-detectado, zellij/orca/tuios quando explicitamente selecionado), registros de execução do drill, logs de eventos de status, markdown local sob `data/` incluindo `data/commander.md`, `data/commander-shared.md` e `data/learnings.md`, e bases XO persistentes.
Para herdr, respawn após layout restaurado pelo servidor fecha e substitui husks de tarefa confirmados sem-agente ou mortos em vez de exigir limpeza manual de abas.
No início da sessão, endpoints de agente XO confirmados como mortos são fechados e relançados pelo mesmo caminho de spawn de XO, enquanto leituras ambíguas de vitalidade são deixadas intactas para evitar supervisores duplicados.
Use `/debrief` antes de um reset intencional quando a conversa pode segurar conhecimento durável que ainda não foi escrito no disco; depois disso, a próxima sessão do Squad pode reconciliar e continuar.

## Notas de desenvolvimento

O trabalho atual de confiabilidade da sentinela combina triagem always-on com bash com uma fila durável para acordos acionáveis, lock singleton à prova de corrida, auto-despejo de duplicatas, afirmação de vitalidade no momento de drain, e wrapper de arm self-verifying rastreado por filho.
O sub-supervisor controlado por presença (`bin/sq-supervise-daemon.sh`) fornece supervisão ao sair via skill `/afk` enquanto reutiliza o mesmo classificador compartilhado de acordos que a sentinela always-on.
