<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Configuração

Os arquivos e variáveis de ambiente que você configura para operar o Squad.

## Comportamento do orquestrador (AGENTS.md)

O comportamento compartilhado do orquestrador vive em [`AGENTS.md`](../../AGENTS.md) — edite-o como qualquer prompt quando a unidade estiver vazia, ou despache edições ao repositório compartilhado para um operador enquanto tarefas estiverem em andamento.

## Layout e estado da base operacional

Esta seção é a única dona do layout da base operacional no nível superior; os cabeçalhos dos scripts de produção e sua ajuda são donos dos campos de arquivo filhos e contratos de mutação exatos.
A raiz de código rastreada contém as superfícies de instrução, habilidade, documentação, workflow e `bin/` compartilhadas, enquanto cada `SQUAD_BASE` efetivo contém diretórios operacionais privados.
`data/` contém registros privados duráveis da unidade, como os registros de projetos e XOs, preferências do comandante, preferências compartilhadas opcionais do comandante, aprendizados, backlog, briefs e relatórios de recon.
`state/` contém registros voláteis de runtime, como metadados de tarefas, eventos de status append-only, sinais de endpoint, coordenação de sentry e fila de stand-to, estado de away-mode, artefatos Relay gerados, gerações de re-leitura de configuração XO privadas com seu estado de retentativa e quarentena, e registros de resposta pendente de XOs de propriedade do pai sob `state/pending-replies/` (`bin/sq-pending-reply-lib.sh`).
`state/window-states` é a verdade derivada da sidebar tmux por janela publicada por `bin/sq-window-state.sh`; o cabeçalho desse script é dono do contrato do arquivo, e `bin/sq-crew-state.sh` continua sendo o dono da reconciliação de estado atual que publica.
`config/` contém escolhas de operação locais e gitignored, e `projects/` contém as cópias locais de projetos que Squad lê mas altera apenas através das exceções restritas, protegidas e concretamente aprovadas pelo comandante em `AGENTS.md`.

`bin/sq-spawn.sh` é dono dos campos de metadados de tarefa base que emite, enquanto a seção de backend de runtime abaixo é dona dos campos específicos do backend e da interpretação do seletor.
Os helpers de PR e Relay que produzem são donos dos campos que anexam, `bin/sq-classify-lib.sh` é dono do vocabulário de eventos de status, e `bin/sq-crew-state.sh` é dono da reconciliação de estado atual.
A mecânica de wake, sentry, away-mode e específica do Relay permanece com seus scripts e seções de referência nomeados em vez de ser duplicada em uma árvore de estado exaustiva aqui.

O cabeçalho de `bin/sq-session-start.sh` é o único dono da ordenação de início de sessão, comandos compostos, conteúdo do digest e o mecanismo de startup do digest.
O cabeçalho de `bin/sq-startup-network.sh` é dono do estágio de rede adiado que mantém todas as chamadas de rede externa fora do caminho de bloqueio do digest, incluindo seus arquivos de estado e o argumento de segurança para executá-los depois.
`docs/sessionstart-nudge.md` é dona dos níveis de adaptador de abertura de sessão nativos que executam ou incentivam o comando de digest, e do roteamento de fonte entre eles.
`AGENTS.md` retém as regras de execução única e leitura única, segurança de recusa de bloqueio, consentimento de instalação e limites de recuperação de relatório direto porque esses fatos se aplicam em cada início de sessão.
A recuperação de relatório direto morto comum é dona de `stuck-operator-recovery`, enquanto a recuperação de XO persistente é dona de `xo-provisioning`.

## Preferência Pi Calm (config/calm)

A extensão Pi Calm armazena a escolha de apresentação local do comandante em `config/calm` gitignored sob a base Squad efetiva, resolvida a partir de `SQUAD_BASE`, depois o legado `SQUAD_HOME`, depois `SQUAD_ROOT_OVERRIDE`, depois a raiz de código rastreada derivada do caminho da extensão, ou sob `SQUAD_CONFIG_OVERRIDE` quando esse override de teste e setup especializado está presente.
Os únicos valores que grava são `on` e `off`, cada um seguido por uma nova linha; um valor ausente, ilegível ou não reconhecido padrão é off.
O comando `/calm` substitui o arquivo atomicamente antes de alterar a apresentação ao vivo, então uma gravação fracassada deixa a escolha atual inalterada em vez de reivindicar persistência.
A extensão recarrega essa preferência em cada `session_start` do Pi, incluindo motivos de startup, new, resume, fork e reload.
Essa preferência é local para cada base Squad e não faz parte da configuração herdada de XOs.

## Backend de backlog (.tasks.toml / config/backlog-backend)

O `.tasks.toml` rastreado fixa o backend markdown padrão do `sq-tasks` em `data/backlog.md`, com `done_keep = 10` e um arquivo em `data/done-archive.md`.
Quando o backend padrão é selecionado e `sq-tasks` compatível está no `PATH`, Squad usa seus verbos para mutações rotineiras do backlog.
Handoffs de XO são separados e incondicionais: `sq-backlog-handoff.sh` mantém apenas sua própria validação em nível de unidade e sempre delega a movimentação do item para `sq-tasks mv`, o único dono do formato do backlog.
Move apenas itens `## Queued` dentro do escopo e recusa registros `## In flight` e históricos `## Done`, que permanecem em sua base para poda ou arquivamento.
Os corpos dos itens de handoff devem usar pelo menos dois espaços iniciais, e o helper recusa um item selecionado com continuação indentada por espaço único ou tabulação em vez de arriscar orfã-lo.
Como o bootstrap requer `sq-tasks` no `PATH` em cada perfil, essa delegação funciona em toda a unidade, e o parâmetro `config/backlog-backend=manual` governa a edição manual do Squad em seu próprio backlog, não este helper validado.
Compatível significa que a versão instalada passa na verificação de versão e funcionalidade compartilhada de [`bin/sq-tasks-lib.sh`](../../bin/sq-tasks-lib.sh), incluindo a movimentação multi-ID atômica exigida pela delegação de handoff.
O bootstrap requer `sq-tasks` compatível em cada perfil; veja "Toolchain" abaixo para relatório de ferramentas ausentes e comportamento silencioso do backend padrão.
Defina o arquivo local, gitignored `config/backlog-backend` como `manual` para forçar edição manual do backlog e suprimir o fato verboso `BOOTSTRAP_INFO: sq-tasks available`, não o relatório de ferramentas ausentes.
Ausente (ou qualquer valor não manual) seleciona o backend padrão sq-tasks.
O formato do arquivo não muda em ambos os modos; sq-tasks e edições manuais produzem as mesmas seções `## In flight`, `## Queued` e `## Done`.

## Backend de runtime (config/backend / SQUAD_BACKEND)

Para adaptadores capazes de spawn, o backend de provedor de sessão de runtime controla onde as janelas/endpoints de tarefas são criadas, capturadas, enviadas, monitoradas e encerradas.
`tmux` é o backend de referência verificado (veja [`docs/tmux-backend.md`](tmux-backend.md)); `herdr`, `zellij`, `orca` e `cmux` são backends de spawn experimentais (veja [`docs/herdr-backend.md`](herdr-backend.md), [`docs/zellij-backend.md`](zellij-backend.md), [`docs/orca-backend.md`](orca-backend.md) e [`docs/cmux-backend.md`](cmux-backend.md)).
FOB continua sendo o provedor de worktree para tmux, herdr, zellij e cmux, pois herdr, zellij e cmux são apenas provedores de sessão; Orca fornece tanto o worktree da tarefa quanto o endpoint de terminal.
Novos spawns escolhem o backend nesta ordem: um flag `--backend` explícito que a autoridade atual para essa tarefa exata autorizou (uma instrução do comandante presente ou o brief aceito da própria tarefa; nunca precedente por analogia de outra tarefa), depois `SQUAD_BACKEND`, depois a primeira linha não vazia do `config/backend` local gitignored, depois auto-detecção de runtime a partir de `$TMUX`, `HERDR_ENV=1` ou sinais de runtime do cmux, depois o padrão `tmux`.
Se mais de um marcador de runtime estiver presente, a detecção resolve de dentro para fora: `$TMUX` é verificado antes de `HERDR_ENV=1`, que é verificado antes do marcador primário `CMUX_WORKSPACE_ID` do cmux e seus sinais de fallback documentados — tmux ou herdr iniciados de dentro de um terminal cmux é a camada mais interna, atualmente em execução, enquanto o próprio cmux (um aplicativo de terminal, não um multiplexador aninhável) é sempre verificado por último.
Veja [`docs/cmux-backend.md`](cmux-backend.md#runtime-detection) para por que cmux pode ser selecionado quando `CMUX_WORKSPACE_ID` está ausente.
Herdr ou cmux auto-detectados imprimem um aviso no stderr nomeando `config/backend` e `--backend tmux` como opt-outs; tmux auto-detectado fica silencioso para preservar o comportamento padrão existente.
Zellij e Orca nunca são auto-detectados; selecione-os colocando o nome em um arquivo local `config/backend`, exportando `SQUAD_BACKEND=<nome>` ou dizendo ao sargento de armas no chat.
Qualquer valor diferente de `tmux`, `herdr`, `zellij`, `orca` ou `cmux` é rejeitado até que outro adaptador seja implementado e verificado.
`sq-spawn.sh` aceita `tmux`, `herdr`, `zellij`, `orca` e `cmux` para tarefas de ship e recon; `backend=orca` e `backend=cmux` ainda recusam `--xo` até que a semântica de lançamento de XO seja projetada para cada um.
`codex-app` ainda não é um backend de runtime aceito; [`docs/codex-app-backend.md`](codex-app-backend.md) é dona do limite do Codex App.
A varredura de vivacidade de XO no início de sessão usa o classificador de grau de recuperação `fm_backend_agent_state` onde verificado.
O comentário acima daquela função em `bin/sq-backend.sh` é o único dono de seu contrato de estado detalhado e autorização de recuperação.
O helper de compatibilidade `fm_backend_agent_alive` continua colapsando esses resultados detalhados para `alive`, `dead` ou `unknown` para chamadores mais antigos.
Um spawn herdr adicionalmente faz gate de versão contra o protocolo do binário `herdr` instalado e requer `jq`, recusando alto e ruidosamente em caso de instalação incompatível ou ausente.
Um spawn zellij adicionalmente faz gate de versão contra a versão do binário `zellij` instalado e requer `jq`, recusando alto e ruidosamente quando qualquer um estiver ausente ou a versão for anterior a 0.44.
Um spawn cmux adicionalmente faz gate de versão contra a versão do binário `cmux` instalado, requer `jq` e requer que o socket de controle esteja acessível e acessível (veja [`docs/cmux-backend.md`](cmux-backend.md) "Setup" para a configuração de acesso ao socket uma vez que precisa; modo Automation é o modo de controle de socket recomendado, com modo Password suportado via `config/cmux-socket-password`), recusando alto e de forma não retentável em um socket `cmuxOnly`/não autenticado.
Uma recusa de spawn de backend por dependência ausente, gate de versão ou socket não autenticado é terminal para aquele backend selecionado; Squad o apresenta como um bloqueio em vez de silenciosamente retentar outro backend.
Metadados de tarefa gravam `backend=` apenas para um backend não padrão; um `backend=` ausente significa `tmux`, preservando metadados existentes do caminho padrão.
Cada nova tarefa grava `endpoint_task_id=` como o vínculo de limpeza entre o nome do arquivo de metadados e seu endpoint de runtime opaco.
Uma tarefa herdr adicionalmente grava `herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=` e `herdr_pane_id=`.
Uma tarefa zellij adicionalmente grava `zellij_session=`, `zellij_tab_id=` e `zellij_pane_id=`.
Uma tarefa Orca adicionalmente grava `orca_worktree_id=` e `terminal=`, com `window=sq-<id>` mantido como o alias Squad compartilhado.
Uma tarefa cmux adicionalmente grava `cmux_workspace_id=` e `cmux_surface_id=`.
Seletores de tarefa para `sq-peek.sh`, `sq-send.sh` e `sq-crew-state.sh` resolvem centralmente através de `fm_backend_resolve_selector`.
Um seletor contendo `:` é passado como escape explícito do endpoint do backend.
Caso contrário, uma correspondência exata do id da tarefa com `state/<id>.meta` vence antes do fallback legado do label `sq-<id>`, então ids de tarefa que começam com `sq-` roteiam para seus próprios metadados em vez de serem removidos.
Um seletor roteado por metadados retorna o alvo do backend gravado (`terminal=` para Orca, caso contrário `window=`), e alvos explícitos correspondentes ainda podem recuperar o backend gravado quando os metadados contêm o mesmo endpoint.
Apenas seletores de tarefa roteados por metadados carregam contexto de marcador XO e harness Codex; escapes explícitos de endpoint não.
Estas cinco frases são as únicas donas do vocabulário de seletor de tarefa; guias de backend e outros documentos apontam aqui em vez de redeclarar a ordem de resolução.
`sq-teardown.sh <id>` recebe um id de tarefa diretamente e valida a identidade completa do endpoint baseada apenas em metadados antes de qualquer dispatch de runtime ou mutação de limpeza.
Registros de endpoint ausentes, vazios, duplicados, malformados, inconsistentes com o backend ou incompatíveis com a tarefa são preservados e recusados.
Metadados legados do tmux continuam compatíveis com limpeza quando seu nome exato de janela é `sq-<id>`; endpoints opacos não-tmux requerem seu vínculo `endpoint_task_id=` gravado.
`SQUAD_BASE` determina o label base do Herdr: a base primária usa `Squad`, e uma base XO marcada por `.sq-xo-home` usa `xo-<XO-id>`.
[`herdr-backend.md`](../herdr-backend.md#watching-and-task-containers) é dona do posicionamento de workspace vinculado ao launcher, o fallback de label apenas, tratamento de colisão e comportamento de recuperação.
O arquivo local `config/herdr-presentation-spaces` em vez disso desativa uma base de, ou ativa explicitamente em, a projeção visual descartável de tarefa única do Herdr com padrão ligado; [Presentation spaces](../herdr-backend.md#presentation-spaces) é dona de seus valores aceitos, padrão, versão mínima do Herdr, migração, comportamento, limites de segurança, contrato de recuperação e limpeza restrita de início de sessão de filhos idle-shell restaurados exatos.
A configuração é herdada para bases XO sob o contrato de autoridade primária dona de [`xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md).
Para operações herdr normais, `HERDR_SESSION` seleciona a sessão nomeada, mas a limpeza destrutiva de teste não pode depender apenas de `HERDR_SESSION`.
Use o caminho de limpeza protegido descrito em [`docs/herdr-backend.md`](../herdr-backend.md) em vez de `herdr server stop`.
Para operações zellij normais, `SQUAD_ZELLIJ_SESSION` seleciona a sessão nomeada e padrão é `Squad`.
Zellij não tem divisão de workspace por base: tarefas primárias e de XO compartilham aquela sessão, e títulos de abas visíveis são escopados pelo label legível do `SQUAD_BASE` ativo mais um hash curto do caminho `SQUAD_ROOT` resolvido como `sq-<base-label>-<id>`.
Use o caminho de limpeza protegido descrito em [`docs/zellij-backend.md`](../zellij-backend.md) em vez de `kill-all-sessions` ou `delete-all-sessions`.
cmux não tem camada de sessão — um workspace por tarefa, em qualquer janela cmux aberta — e sua senha de socket (quando configurada) é lida de `config/cmux-socket-password` local, gitignored, sob o diretório de config efetivo, nunca commitada.
O label voltado para o chamador continua `sq-<id>`, mas o título real do workspace cmux é escopado pelo label legível do `SQUAD_BASE` ativo mais um hash curto do caminho `SQUAD_ROOT` resolvido como `sq-<base-label>-<id>`.
Limpeza de teste deve usar o caminho protegido em [`docs/cmux-backend.md`](../cmux-backend.md#current-operation-and-safety), nunca enumerar-e-fechar cada workspace.
`config/backend` é herdado para bases XO sob o contrato de autoridade primária dona de [`xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md).

## Backend de supervisor de away-mode (SQUAD_SUPERVISOR_BACKEND / SQUAD_SUPERVISOR_TARGET)

O sub-supervisor `/afk` injeta resumos de escalação no próprio painel do Squad independentemente de onde novos endpoints de tarefa são criados.
Atualmente suporta apenas painéis de supervisor `tmux` e `herdr`.
Defina `SQUAD_SUPERVISOR_BACKEND=tmux|herdr` e `SQUAD_SUPERVISOR_TARGET=<alvo>` para sobrescrever explicitamente ambos os eixos; para herdr o alvo é `"<session>:<pane-id>"`.
Sem sobrescrever, a detecção de backend usa `$TMUX_PANE` primeiro, depois `HERDR_ENV=1` com `HERDR_PANE_ID`, depois recua para `tmux`.
Isso mantém um painel tmux aninhado dentro de herdr no transport tmux, correspondendo à regra de dentro para fora do backend de runtime.
A detecção de alvo usa `SQUAD_SUPERVISOR_TARGET`, depois `$TMUX_PANE`, depois `"${HERDR_SESSION:-default}:${HERDR_PANE_ID}"` sob herdr, depois o fallback legado `Squad:0` do tmux com um aviso.
Selecionar qualquer outro backend de supervisor, incluindo `zellij`, `orca` ou `cmux`, recusa na inicialização do daemon em vez de tentar primitivas de injeção tmux contra um painel não-tmux.

## Canais de alarme wedge de away-mode (config/wedge-alarm)

Quando a injeção de away-mode trava além de `SQUAD_MAX_DEFER_SECS`, o sub-supervisor dispara um alarme alto e com taxa limitada.
Além do marcador durável `state/.subsuper-inject-wedged` e do flash na linha de status do tmux, tenta um alerta ativo configurado e independente do backend que pode alcançar o comandante mesmo quando cada painel e sua linha de status do backend estão ilegíveis.
`config/wedge-alarm` (local, gitignored) lista diretrizes de canal, uma por linha não vazia e não-comentário; cada canal listado que não é `dispara, melhor esforço.
`SQUAD_WEDGE_ALARM_CHANNEL` sobrescreve o arquivo com uma única diretriz.
As diretrizes são `off` (um interruptor de desligamento independente de posição que desativa todo alerta ativo), `auto`/`default`, `osascript` (banner do Notification Center do macOS), `herdr` (notificação da UI do herdr) e `command:<cmd>` (executa `<cmd>` via `sh -c`, resumo em `$1` e stdin).
Um arquivo ausente significa `auto`, ou seja, ligado por padrão no macOS: o alarme existe precisamente para que um primário com away-mode travado nunca fique silencioso, e dispara no máximo uma vez por janela de max-defer após um travamento genuíno.
Um canal ausente ou que falha registra e passa para o próximo, nunca crashando o daemon.
Veja [`wedge-alarm.md`](../wedge-alarm.md) para a referência atual de canais, [`verification/supervision.md`](../verification/supervision.md#wedge-alarm-channels) para evidência ativa e [`examples/wedge-alarm`](../examples/wedge-alarm) para uma configuração copiável.

## Propagação de trace context (config/trace-context / SQUAD_TRACE_CONTEXT)

A flag de presença opcional local e gitignored `config/trace-context` ativa a propagação nativa W3C trace-context desligada por padrão.
`SQUAD_TRACE_CONTEXT` sobrescreve o arquivo: `1`/`on`/`true`/`yes` ativa, qualquer outro valor não vazio desativa, e não definido ou vazio delega para o arquivo.
Cada sessão base bloqueada resolve esses inputs uma vez, e todos os spawns daquela base usam a decisão congelada até que uma nova sessão comece.
Ao lançar um XO, o primário copia a flag de presença para sua base e passa a decisão congelada da sessão primária como uma sobrescrever não vazia `SQUAD_TRACE_CONTEXT=on|off` para o próprio início de sessão do XO.
Um XO em uma rota remota é coberto da mesma forma: o primário resolve e registra o transport dessa tarefa, e o host configurado o exporta e recebe o mesmo snapshot de ativação.
A flag de presença é ativação escopada à sessão, então é transferida no lançamento e deixada inalterada pela convergência ao vivo em uma base em execução.
Veja [`trace-context.md`](../trace-context.md) para semântica do transport, rotas suportadas, o requisito de reinicialização manual da unidade, o limite de sessão e limites de segurança; o cabeçalho de `bin/sq-trace-context-lib.sh` é dono da mecânica exata, e [`verification/trace-context.md`](../verification/trace-context.md) registra evidência reproduzível.

## Defaults de gate (.drill.yaml)

O `.drill.yaml` rastreado mantém evidência de teste fora do repositório e fixa `commands.lint` em `bin/sq-lint.sh` para que o lint local corresponda ao CI.
Essa política de evidência é específica do repositório Squad: projetos alvo podem legitimamente commitar `.drill/evidence/` de seu próprio pipeline de drill, mas Squad mantém `.drill/` local e o CI rejeita entradas rastreadas sob esse caminho.
Não define `commands.test` para um walk completo de `tests/*.test.sh`.
Veja [CONTRIBUTING.md](../../CONTRIBUTING.md) para a política de testes locais específica do Squad e pontos de entrada.
Evidência de shards portáteis e regras de cobertura estão em [sq-test-portable-shards.md](sq-test-portable-shards.md); [herdr-backend.md](../herdr-backend.md#destructive-lab-safety) é dona do limite de isolamento da lane Herdr real, e [runtime-backends.md](../verification/runtime-backends.md#herdr) é dona da evidência ativa.

## Preferências do comandante (data/commander.md / data/commander-shared.md)

Preferências locais do domínio para a unidade de um comandante vivem localmente em `data/commander.md` de cada base; é gitignored e impresso no digest de contexto do início de sessão após `data/projects.md` e opcional `data/XOs.md`.
Antes de alterá-lo, inspecione o arquivo atual e reescreva ou sele o bullet correspondente no lugar; adicione um novo bullet apenas para uma preferência durável genuinamente nova.
Preferências compartilhadas do comandante que se aplicam entre domínios de XO vivem apenas em `data/commander-shared.md` opcional da base primária.
`xo-provisioning` é dona de seu contrato de propagação, incluindo o cabeçalho obrigatório, cópias XO somente-leitura, diagnósticos de quarentena e a regra de implantação de que bases existentes apararão `data/commander.md` à mão após a primeira propagação em vez de excluir conteúdo privado automaticamente.

## Aprendizados operacionais (data/learnings.md)

Fatos operacionais e armadilhas locais da unidade vivem localmente em `data/learnings.md`; é gitignored e impresso após os arquivos de preferência do comandante no digest de contexto do início de sessão.
O arquivo é criado lentamente no primeiro aprendizado e segue o mesmo estilo datado, baseado em evidência e curadoria de `data/commander.md`: inspecione o arquivo atual primeiro, depois reescreva ou sele entradas obsoletas em vez de anexar para sempre.
Não existe arquivo compartilhado de aprendizados por decisão do comandante.

## Orçamento de memória de startup (config/startup-memory-budget)

`config/startup-memory-budget` é a cota primária autoritária por base para a superfície de memória do prompt de startup: `data/commander.md`, `data/commander-shared.md` e `data/learnings.md` juntos.
O caminho mutável de bootstrap bloqueado materializa seu padrão visível de `7500` tokens estimados em uma base primária quando o arquivo está ausente.
Para selecionar outra cota, substitua o arquivo da base primária por um valor positivo válido no formato exato abaixo; a próxima convergência de bootstrap bloqueada ou `bin/sq-config-push.sh` o propaga para XOs registrados.
Um XO não cria um padrão independente e em vez disso recebe o valor primário através do contrato de material local herdado em [`xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md).
O arquivo deve ser um inteiro base-10 positivo seguido por exatamente uma nova linha em um arquivo regular, com link único, sob um diretório `config/` não-symlinked.
Valores malformados, multi-linha, symlinked, hardlinked, especiais ou de outra forma inseguros são rejeitados em vez de tratados como padrão.
Use `bin/sq-startup-memory-budget.sh read` para validar e imprimir o valor efetivo, ou `bin/sq-startup-memory-budget.sh report` para contabilizar os três arquivos.
A estimativa local estável é `ceil(UTF-8 bytes / 3)` por arquivo, uma aproximação portátil conservadora em vez de um tokenizador exato do provedor.
Um `data/commander-shared.md` herdado conta no total de um XO mas continua sendo de propriedade do primário e somente-leitura lá.
A habilidade interna [`/debrief`](../../.agents/skills/debrief/SKILL.md) é dona da curadoria e de seu cascade XO automático, que contabiliza cada base contra essa mesma cota por base separadamente em vez de contra um total da unidade.
O cabeçalho do helper é dono da mecânica exata de parsing, publicação e saída do relatório.

## Rotas de XO (data/XOs.md)

Rotas de XO persistentes vivem localmente em `data/XOs.md`.
O contrato de rota concisa de linha única é dono da [habilidade `xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md#routing-table), incluindo os campos compatíveis com o parser, requisito de resumo de uma frase, ponteiro `home:` para o brief charter e limite de texto adicional do registro.
Uma rota remota adiciona `host:` e `root:` antes dos campos existentes e coloca toda a base XO naquele host SSH; não torna workers comuns posicionáveis remotamente.
[`remote-XOs.md`](remote-XOs.md) é dona do setup remoto atual, operação e comportamento de segurança.
Use `sq-home-seed.sh validate` para verificar o contrato operacional completo do registro documentado pelo próprio comando.
O principal sargento de armas roteia lendo esses escopos com julgamento; a lista de projetos é dados de provisionamento, não propriedade exclusiva.
Use `sq-home-seed.sh <id> - {<projeto>...|--no-projects}` para alugar um novo worktree Squad local para a base XO.
Para provisionamento remoto, incluindo origens de projetos fornecidas, siga [Remote second mates](remote-XOs.md#provision-a-route).
Use o sinal deliberado `--no-projects` apenas para um domínio do Squad-repo que não precisa de cópias separadas de projetos.
Não pode ser combinado com uma lista de projetos, e omitir ambos ainda falha alto.
Uma seed sem projeto não requer cópias existentes de projetos ou entradas `data/projects.md` na base, então recusa uma conversão de base populada sem alterar aquela base.
Um charter existente com projetos também é recusado até que seja re-scaffolded com `--no-projects` ou removido.
O aluguel é mantido sob o id do XO até aposentadoria explícita ou rollback da seed retorná-lo, então reinicializações normais não liberam ou reciclam a base.
A limpeza de uma base alugada falha fechado se `fob return` não puder liberar o aluguel; bases clone simples sem slot de pool fob são removidas diretamente.
Rotas de XO cobrem projetos `drill` e `direct-PR`; projetos `local-only` permanecem como trabalho do Squad principal.
Para projetos `drill`, a seed inicializa apenas projetos recém-clonados em uma base XO e recusa mutar uma cópia pré-existente que ainda não foi inicializada.
Após criar um XO, mova itens enfileirados existentes do backlog principal que você julgou dentro do escopo com `sq-backlog-handoff.sh <XO-id> <item-key>...`; é idempotente e recusa In flight, Done ou bases não-XO.
Defina `SQUAD_XO_CHARTER` para seed a partir de texto de charter inline quando não existe brief de charter preenchido; defina `SQUAD_XO_SCOPE` quando o escopo de roteamento deve diferir do texto do charter.
`data/charter.md` da base seed é dona do contrato padrão de lifecycle e escalação de XO; o arquivo de rota aponta para ele através do campo `home:` existente em vez de adicionar outro ponteiro.
Cada seed escreve um marcador de identidade `.sq-xo-home` na raiz da base, junto com um registro durável `.sq-xo-parent` da rota da base para seu pai (veja "Provision a route" em [`docs/remote-XOs.md`](../remote-XOs.md)).
O `.gitignore` raiz rastreado ignora ambos os marcadores, então a validação pode ler sem fazer uma base recém-seedada parecer suja para verificações de segurança baseadas em porcelain.
Isso não relaxa a proteção para qualquer outro arquivo não rastreado.
Uma base de worktree vinculado existente que precede essa regra avança através de seu estado apenas-marcardor durante seu próximo bootstrap ou sync local de spawn, após o qual Git ignora o marcador normalmente.
Uma base clone standalone não pode receber um commit primário-local através desse sync sem-fetch, então recebe a regra através da atualização de origin do `/updatesquad` em vez disso.

## SQUAD_BASE

`SQUAD_BASE` seleciona a base operacional para uma instância Squad.
Quando não está definido, a maioria dos scripts usa a raiz do repositório como base; quando está definido, scripts ainda executam de `bin/` deste repositório, mas `state/`, `data/`, `config/` e `projects/` vêm de `$SQUAD_BASE`.
`SQUAD_HOME` continua aceito como fallback legado permanente de leitura: quando `SQUAD_BASE` está não definido ou vazio, scripts resolvem `SQUAD_HOME` em vez disso, e `SQUAD_BASE` sempre tem precedência quando ambos estão definidos.
`SQUAD_ROOT_OVERRIDE` sobrescreve a raiz do repositório Squad usada por scripts, incluindo o checkout primário monitorado pelo guard de tangle.
Quando nem `SQUAD_BASE` nem `SQUAD_HOME` estão definidos, `SQUAD_ROOT_OVERRIDE` se comporta como a sobrescrever antiga de raiz inteira.
`bin/sq-send.sh` é intencionalmente mais estrito que esse fallback geral: requer `SQUAD_BASE` (ou legado `SQUAD_HOME`) antes de resolver um alvo, então direcionamentos de operadores não podem silenciosamente resolver contra a base errada.
`SQUAD_STATE_OVERRIDE`, `SQUAD_DATA_OVERRIDE`, `SQUAD_PROJECTS_OVERRIDE` e `SQUAD_CONFIG_OVERRIDE` sobrescrevem diretórios operacionais individuais para testes e setup especializado de harness.
Antes que `sq-brief.sh`, `sq-spawn.sh` ou `sq-afk-launch.sh` persista um caminho ou passe para outro processo, resolve cada diretório relativo aplicável `SQUAD_BASE` (ou legado `SQUAD_HOME`), `SQUAD_STATE_OVERRIDE` ou `SQUAD_DATA_OVERRIDE` contra o diretório de trabalho do chamador, preserva grafias absolutas inalteradas e rejeita um diretório relativo não resolvível com a variável problemática nomeada.
O bootstrap aplica a mesma resolução relativa de `SQUAD_BASE` apenas ao incorporar aquela base no shim de poll Relay gerado; outros consumidores transitórios mantêm seu comportamento shell-relativo existente.
Para o backend herdr, `SQUAD_BASE` também determina o label de workspace usado pelo adaptador.
Para o backend zellij, `SQUAD_BASE` não divide containers, mas determina o prefixo base legível embutido nos títulos de abas visíveis; use `SQUAD_ZELLIJ_SESSION` quando uma sessão zellij separada for necessária.
O label base zellij completo também inclui um hash curto do caminho `SQUAD_ROOT` resolvido.
Para o backend cmux, `SQUAD_CONFIG_OVERRIDE` sobrescreve de onde `config/cmux-socket-password` é lido, enquanto `SQUAD_BASE` determina o caminho de config padrão e o prefixo base legível embutido nos títulos de workspace.
O label base cmux completo também inclui um hash curto do caminho `SQUAD_ROOT` resolvido, e não há divisão de container por base.

## Suporte de harness

claude, codex, opencode, pi, pi-signed, grok e kimi são verificados empiricamente para lançamentos de operador e XO; [requisitos do README](../../README.md#requirements) são donos do conjunto suportado para a sessão primária.
muse é verificado APENAS para lançamentos de operador e recon, e `sq-spawn.sh` o recusa para um XO, porque muse não fornece uma superfície de hook utilizável para a supervisão de fim de turno de uma sessão primária; [`docs/verification/muse.md`](../verification/muse.md) é dona dessa evidência.
muse também precisa de uma credencial acessível pelo worker antes de spawn, e o caminho portátil da unidade é a credencial `<config>/muse/auth.json` armazenada por `muse login`, porque um `META_API_KEY` apenas do chamador não cruza um daemon de backend de longa duração.
Novos harnesses são verificados através de uma tarefa de teste supervisionada antes de se juntar ao conjunto.
O conhecimento do adaptador verificado — a fonte de estado busy, comandos de interrupção e saída, sintaxe de invocação de habilidade e peculiaridades por harness — vive em [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md).
A mecânica de lançamento, incluindo os templates de comando verificados, vive em [`bin/sq-spawn.sh`](../../bin/sq-spawn.sh).
Integrações habilitadas de guard de fim de turno da sessão primária são rastreadas como arquivos de hook de nível de repositório e documentadas em [`docs/turnend-guard.md`](turnend-guard.md).
Kimi permanece fora das integrações do guard de fim de turno primário; [`docs/turnend-guard.md`](turnend-guard.md#compatibility-limits) é dona de seu hook de wake de crew separado aprovado pelo comandante.
Protocolos de wake de sentry da sessão primária são renderizados no início de sessão por [`bin/sq-supervision-instructions.sh`](../../bin/sq-supervision-instructions.sh) a partir de [`docs/supervision-protocols/`](supervision-protocols/).
O hook `asyncRewake` do Stop do Claude é dono dos ciclos de re-armazenamento sem token, Grok usa ciclos de background-notify, Codex usa checkpoints de primeiro plano delimitados, Pi e pi-signed usam as mesmas duas extensões primárias rastreadas, e OpenCode usa seu plugin TUI.
`config/crew-harness` é um arquivo local, gitignored contendo um nome de adaptador para lançamentos de operador e recon.
Quando pi-signed é selecionado, Squad lança o executável nomeado `pi-signed` de `PATH` com `SQUAD_PI_HARNESS=pi-signed` e recusa o lançamento se indisponível em vez de recuar para pi.
Lançamentos Pi simples definem `SQUAD_PI_HARNESS=pi`, então o ambiente de um primário assinado não pode rotular um worker Pi simples.
Quando está ausente ou contém `default`, operadores espelham o próprio harness do Squad.
`config/xo-harness` é um arquivo local, gitignored separado contendo o adaptador que o primário usa para lançar agentes XO, opcionalmente seguido por tokens de modelo e esforço na mesma linha.
A primeira linha não vazia e não-comentário é parseada como `<harness> [<modelo>] [<esforço>]`.
Um `<harness>` vazio preserva o comportamento anterior: apenas harness, sem flags de modelo ou esforço.
Quando o token de harness está ausente ou `default`, o lançamento de XO recua através de `config/crew-harness` e depois o próprio harness do primário, e nenhum modelo ou esforço é lido desse arquivo.
`sq-harness.sh XO-model` e `sq-harness.sh XO-effort` expõem apenas os tokens opcionais de `config/xo-harness`; `config/crew-harness` continua sendo um arquivo de nome de adaptador vazio.
Um argumento de harness explícito para `sq-spawn.sh` ainda sobrescreve qualquer arquivo de configuração para aquele spawn apenas.
Um `--model` ou `--effort` explícito sobrescreve o token correspondente de `config/xo-harness`; para uma rota local, um harness explícito ou comando de lançamento bruto começa com padrões de modelo e esforço limpos a menos que esses flags também sejam passados.
Rotas de XO remoto aceitam apenas adaptadores de harness verificados e rejeitam comandos de lançamento brutos.
Quando `config/crew-dispatch.json` existe, spawns de operador e recon requerem um harness resolvido explícito em vez de recuar automaticamente para `config/crew-harness`.
O contrato de material local herdado é dono de [`xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md); sua consequência relevante para harness é que os próprios operadores de um XO usam os perfis de dispatch e o valor estático de harness do primário.
Esses valores herdados são apenas padrões e regras; `sq-spawn` ainda permite um runtime conscientemente escolhido fora da config.
`config/xo-harness` não é herdado porque XOs não lançam XOs.
Para grok, `sq-spawn.sh` instala um hook de fim de turno global Squad-owned sob `$GROK_HOME/hooks/`, ou `~/.grok/hooks/` quando `GROK_HOME` não está definido, e coloca um ponteiro `.sq-grok-turnend` por tarefa no worktree, com a limpeza removendo o token e ponteiro da tarefa.
Para operadores Kimi, `sq-spawn.sh` executa `sq-kimi-turnend-hook.sh install`, coloca um ponteiro `.sq-kimi-turnend` por tarefa no worktree e registra o token de registro privado correspondente para limpeza.
Kimi continua usando o Kimi home normal do comandante, incluindo a config existente, habilidades e memória; Squad não cria um Kimi home isolado.
O instalador Kimi requer um `~/.kimi-code/config.toml` regular não-symlink existente, `python3` com `tomllib` e `jq`; valida mas nunca serializa o TOML do comandante e recusa antes de gravar quando a config está ausente, malformada, surpreendente ou quando qualquer requisito de ferramenta está indisponível.
Sua ação `remove` excisa apenas a região Squad delimitada por marcadores e remove os arquivos de hook do Squad.
Para lançamentos de XO Pi e pi-signed, `sq-spawn.sh` inicia o executável selecionado com `-e` apontando para `.pi/extensions/sq-primary-pi-watch.ts` e `.pi/extensions/sq-primary-turnend-guard.ts` rastreadas da própria base XO, ambas já presentes no git worktree da base XO.

## Perfis de dispatch de crew (config/crew-dispatch.json)

`config/crew-dispatch.json` é um arquivo opcional, local, gitignored contendo regras em linguagem natural que Squad lê antes de despachar um operador ou recon.
Os scripts shell não correspondem a essas regras; Squad escolhe a regra mais correspondente com julgamento, resolve seu objeto ou array de perfil sob o contrato operacional na seção 4 do `AGENTS.md` e `quota-array-dispatch`, e passa apenas flags concretas `--harness`, `--model` e `--effort` para `sq-spawn.sh`.
Quando o arquivo existe, `sq-spawn.sh` aplica esse contrato recusando spawns de operador e recon que não possuem um harness explícito (`--harness`, um adaptador posicional ou um comando de lançamento bruto).
Spawns em lote satisfazem o mesmo requisito com um `--harness` compartilhado.
Spawns de XO são isentos e ainda resolvem através de `config/xo-harness` e seus tokens opcionais de modelo e esforço.
Esta seção é a única dona do schema canônico e suas semânticas por campo.
A seção 4 do `AGENTS.md` é dona do limite de intake de dispatch sempre carregado, e `quota-array-dispatch` é dona do procedimento de seleção de array de perfil ciente de quota.

```json
{
  "rules": [
    {
      "when": "<condição em linguagem natural descrevendo um tipo de tarefa>",
      "use": [
        { "harness": "<adaptador>", "model": "<modelo opcional>", "effort": "<low|medium|high|xhigh|max, opcional>" }
      ],
      "why": "<raciocínio opcional que ajuda Squad a escolher>"
    }
  ],
  "default": [
    { "harness": "<adaptador>", "model": "<modelo opcional>", "effort": "<esforço opcional>" }
  ]
}
```

Por regra, `when` e `use` são obrigatórios.
Ambos `use` e o `default` opcional de nível superior aceitam um objeto de perfil ou um array não vazio de objetos de perfil.
A forma de objeto único continua totalmente compatível, e cada perfil precisa de `harness`.
Os campos `model` e `effort` do perfil e o `why` da regra são opcionais.
Um modelo ou esforço omitido significa que o harness selecionado usa seu próprio padrão para aquele eixo.
Cada array de perfil é uma escolha implícita ciente de quota resolvida através de `quota-array-dispatch`.
Se nenhuma regra de dispatch se encaixa, Squad resolve `default` através do mesmo caminho de objeto ou array antes de recuar para `config/crew-harness`.
Se um perfil selecionado carrega um valor de esforço que o harness escolhido não aceita, `sq-spawn.sh` registra o `effort=` solicitado nos metadados da tarefa para rastreabilidade mas omite a flag de lançamento, e bootstrap relata o par harness/effort inválido como um diagnóstico `CREW_DISPATCH` quando visível no arquivo.
Veja [`docs/examples/crew-dispatch.json`](../examples/crew-dispatch.json) para um ponto de partida para copiar para `config/crew-dispatch.json` local.
Quando o arquivo existe, bootstrap o valida com `jq`.
Arquivos válidos ficam silenciosos por padrão; com `SQUAD_BOOTSTRAP_VERBOSE_FACTS=1`, bootstrap emite `BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json`, um fato `BOOTSTRAP_INFO:` por regra e um fato para o perfil padrão opcional.
JSON malformado, um array rule/default vazio ou malformado, um harness não verificado ou um valor de esforço não suportado por aquele harness é reportado como `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; `jq` ausente é reportado através do fluxo normal de consentimento de instalação `MISSING: jq`.
Dentro de um array `use` ou `default`, cada perfil candidato compartilhando um harness deve carregar o mesmo `effort` quando mais de um deles especifica um; uma incompatibilidade é reportada como `CREW_DISPATCH: invalid config/crew-dispatch.json - mixed effort in array: <harness...>`.
Os candidatos de um array são alternativas guiadas por quota para a mesma tarefa (seção 4 do `AGENTS.md`, `quota-array-dispatch`), então deixar a pressão de quota escolher entre dois níveis diferentes de reasoning-effort substituiria silenciosamente a classe de reasoning da tarefa em vez de trocar apenas modelo ou harness; rotule uma diferença de esforço através de uma regra `when` separada, com chave nas características da tarefa.
Além disso, para harnesses da família pi (pi, pi-signed, opencode), bootstrap resolve cada `model` id configurado contra a saída `--list-models` do próprio harness e reporta `CREW_DISPATCH: model existence:` quando o id corresponde a zero modelos ou mais de um modelo.
Uma sonda que não pode executar surfaca incerteza explícita em vez de uma falha dura.
Enquanto o arquivo estiver presente, nenhum spawn de operador ou recon pode prosseguir sem um harness resolvido explícito; configuração malformada deve ser reportada e corrigida em vez de ser contornada por seleção.
Bases XO herdam este arquivo do primário, então os próprios operadores de um XO aplicam o mesmo comportamento de perfil de dispatch.

## Toolchain

No início de sessão, o sargento de armas detecta o que sua toolchain necessária está ausente ou muito antiga e lista cada problema com um comando de instalação exato ou instruções manuais.
Instala automaticamente ferramentas suportadas apenas após você dizer ok; ferramentas apenas-manuais permanecem para você instalar das instruções impressas.
Ferramentas obrigatórias vêm em duas partes: uma toolchain universal que cada base precisa independentemente do backend, e um delta por backend que segue o backend de runtime efetivamente resolvido para esta base.
A toolchain universal é node, git, gh com autenticação GitHub via `gh auth login`, drill, sq-gh compatível, sq-browser, sq-report compatível, sq-tasks compatível conforme "Backend de backlog" acima e sq-quota compatível.
[`bin/sq-bootstrap.sh`](../../bin/sq-bootstrap.sh) é dona da política de piso da família axi e dos pisos sq-gh e sq-report, enquanto [`bin/sq-tasks-lib.sh`](../../bin/sq-tasks-lib.sh) e [`bin/sq-quota-lib.sh`](../../bin/sq-quota-lib.sh) mantêm suas próprias constantes de piso.
Esta seção é a única dona dessa lista de toolchain universal; pré-requisitos de guias de backend apontam aqui e adicionam apenas suas ferramentas específicas do backend.
Nessa lista, drill executa o pipeline de validação, sq-gh, sq-browser e sq-report cobrem operações de GitHub, browser e review enriquecido, e sq-tasks mais sq-quota dão suporte a mutações de backlog e dispatch de array ciente de quota.
Ferramentas de validação de frontend — Playwright MCP, o CLI Playwright e o padrão de validação visual automática de PR — são cobertas em [playwright-validation.md](playwright-validation.md).
O delta por backend é exigido apenas para o backend resolvido a partir de `SQUAD_BACKEND`, depois `config/backend`, depois auto-detecção de runtime, depois o padrão `tmux`, então uma base nunca é instruída a instalar uma ferramenta que um backend ou feature inativo precisaria.
Esse delta é dono no código por `fm_backend_required_tools` em `bin/sq-backend.sh`: o CLI provedor de sessão do próprio backend resolvido (`tmux`, `herdr`, `zellij`, `orca` ou `cmux`), `jq` para os adaptadores experimentais que emitem JSON (`herdr`, `zellij`, `cmux`) cujos caminhos de spawn e vivacidade parseiam a saída JSON do backend, e o provedor de worktree `fob` para cada backend apenas-provedor-de-sessão (`tmux`, `herdr`, `zellij`, `cmux`).
Disponibilidade de ferramentas do backend usa o resolvedor executável do próprio adaptador, então bootstrap e spawn concordam em locais não-`PATH` suportados como o CLI empacotado do cmux.
Um backend resolvido desconhecido emite `BACKEND_INVALID` e bloqueia o dispatch em vez de silenciosamente descartar seu delta de dependência ou recuar para tmux.
Orca fornece tanto o worktree da tarefa quanto o endpoint de terminal (veja "Backend de runtime" acima), então `backend=orca` requer apenas `orca` além da toolchain universal e pula tanto `fob` quanto o CLI de sessão de cada outro backend.
Uma base herdr, zellij ou cmux portanto nunca é instruída de que `tmux` está ausente, e a verificação de upgrade de aluguel durável `fob` é executada apenas para backends que realmente usam fob.
Quando `config/crew-dispatch.json` existe, bootstrap também requer `jq` para validação de perfil de dispatch.
Quando Relay está ativado, bootstrap também requer `curl` e `jq` antes de armar o shim de poll do relay.
`sq-tasks` e `sq-quota` são ferramentas obrigatórias de bootstrap em cada perfil, a mesma classe de `sq-report`.
Um `sq-tasks` ausente ou incompatível reporta `MISSING: sq-tasks (install: (cd packages/sq-tasks && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build) && npm install -g ./packages/sq-tasks)`; quando `config/backlog-backend` não é `manual` e `sq-tasks` compatível está no `PATH`, bootstrap fica silencioso e Squad usa seus verbos para mutações rotineiras do backlog, caso contrário edita manualmente `data/backlog.md` até que a instalação seja aprovada e concluída.
Um `sq-gh` ausente ou incompatível reporta `MISSING: sq-gh (install: (cd packages/sq-gh && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build) && npm install -g ./packages/sq-gh && sq-gh setup hooks)`.
Um `sq-report` ausente ou incompatível reporta `MISSING: sq-report (install: (cd packages/sq-report && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build) && npm install -g ./packages/sq-report && sq-report setup hooks)`.
Um `sq-quota` ausente ou muito antigo reporta `MISSING: sq-quota (install: (cd packages/sq-quota && npx -y pnpm@11.1.1 install --frozen-lockfile && npx -y pnpm@11.1.1 run build) && npm install -g ./packages/sq-quota)`; Squad não pode resolver um array de perfil sem um binário compatível.
Bootstrap também reporta uma linha `TANGLE:` quando `SQUAD_ROOT` está em uma branch nomeada não-padrão; siga a correção de checkout impressa em vez de tratá-la como um problema de ferramenta instalável.
Em uma sessão somente-leitura que não obteve o bloqueio da unidade, a mesma linha é advisory e omite o comando de checkout.
A etapa de rede adiada de início de sessão bloqueada executa a melhor tentativa de refresh de clone de projeto do bootstrap através de `sq-unit-sync.sh`.
Emite `UNIT_SYNC:` para refreshes ignorados que podem importar, auto-curas recuperadas e alarmes `STUCK:`.
Execuções normais concluídas mantêm skips locais apenas e sem origem silenciosos.
Se bootstrap mata um refresh com timeout, reproduz qualquer saída `sq-unit-sync.sh` concluída antes do skip aggregate timeout para que nenhum resultado finalizado se perca.
Um refresh morto (ou um kill de processo de limpeza) pode deixar um `.git/packed-refs.lock` órfão em uma cópia, que faz o fetch do próximo refresh falhar com `Unable to create '...packed-refs.lock': File exists` do Git.
Nessa assinatura apenas, `sq-unit-sync.sh` retenta o fetch com uma espera delimitada para o lock se auto-limpar, depois remove o lock e retenta mais uma vez apenas quando pode provar o lock obsoleto, exatamente como a recuperação de `index.lock` do `sq-teardown.sh`.
Nunca remove um lock ativo, deixa qualquer outra forma de falha intacta e imprime cada espera, retentativa e remoção no stderr mais um resumo `recovered:` de uma linha no stdout em caso de sucesso para que esse relay de início de sessão ainda surface a recuperação.
A mesma etapa de rede adiada executa o sync XO protegido do bootstrap para bases gravadas vivas, depois propaga o material local herdado declarado para cada base validada viva.
Rotas locais usam operações diretas de filesystem protegidas, enquanto rotas remotas delegam sync e transferência allowlist através de seu host SSH configurado sem sondar nenhuma unidade não-configurada.
Emite `XO_SYNC:` apenas quando uma base foi ignorada por uma razão de sync acionável, herança falhou ou uma cópia divergente de preferência compartilhada do comandante foi posta em quarentena.
Quando uma base em execução avança e sua superfície de instrução carregada (`AGENTS.md`, `bin/` ou `.agents/skills/`) mudou, bootstrap envia o incentivo de re-leitura pelo estável seletor `sq-<id>` e reporta o envio exato concluído como `BOOTSTRAP_INFO:`.
Se o envio falhar, bootstrap mantém um marcador idempotente de retentativa e emite `NUDGE_XOS:` com o motivo da falha.
A mesma execução de bootstrap emite `XO_LIVENESS:` apenas quando um XO registrado é ignorado ou seu relançamento falha; XOs já vivos e relançados com sucesso são tratados silenciosamente.
Para uma edição herdada de material local no meio da sessão onde sync de arquivo rastreado não é necessário, execute `bin/sq-config-push.sh`.
Usa o mesmo helper de descoberta e propagação de XO vivo que bootstrap, imprime o resultado de `crew-dispatch.json`, `crew-harness`, `backlog-backend`, `backend`, `herdr-presentation-spaces`, `startup-memory-budget`, `trace-context` e `data/commander-shared.md` de cada base viva como `pushed`, `unchanged`, `skipped` ou `error`, e sai com código diferente de zero para erros reais de propagação ou falhas de envio de re-leitura de config.
Quando um item de config allowlistado muda para uma base local já em execução, envia o ponteiro de re-leitura de conteúdo literal descrito em [`xo-provisioning`](../../.agents/skills/xo-provisioning/SKILL.md); config allowlistado invariável não envia ponteiro a menos que uma entrega anterior esteja pendente.
Uma base remota alterada em vez disso recebe uma instrução marcada de re-leitura gravada de forma durável após os bytes allowlistados terem sido transferidos porque os caminhos de geração primária-local não são significativos em outro host.
A passagem de herança bootstrap bloqueada usa o mesmo comportamento específico de posicionamento; veja `xo-provisioning` para o único dono do contrato.
A descoberta ao vivo começa a partir dos registros `state/*.meta` com `kind=xo`; `data/XOs.md` apenas preenche `home=` para registros de metadados mais antigos ou incompletos.
Itens ignorados, como um checkout de destino que ainda não gitignores o item, são avisos visíveis mas não falhas duras.

## Relay (.env)

Relay permite que uma instância Squad responda a menções públicas e aja em solicitações de menção normais e reversíveis através do lifecycle normal do Squad.
Cobre ambas as superfícies públicas que o relay suporta: menções `@mySquad` no X e menções do bot mySquad em um servidor Discord onde está instalado.
Ambas as superfícies são o mesmo opt-in e a mesma mecânica — um token de emparelhamento, um poll de relay e um caminho de resposta — então tudo abaixo se aplica a menções Discord a menos que uma linha nomeie uma plataforma explicitamente.
Está desligado a menos que o `.env` gitignored da base Squad contenha um `SQX_PAIRING_TOKEN` não vazio.
O token de emparelhamento identifica o inquilino do relay e registra consentimento de opt-in para respostas públicas autônomas e ações de lifecycle elegíveis.
Pedidos destrutivos, irreversíveis ou sensíveis a segurança são sinalizados para confirmação por canal confiável em vez de serem executados a partir de uma menção pública.
O relay usa roteamento apenas-do-proprietário: uma menção entregue a uma base é do proprietário/comandante daquela base, enquanto o contexto de thread pai pode ainda incluir outras contas públicas.
`SQX_RELAY_URL` é opcional e padrão é `https://mySquad.io`, principalmente para desenvolvedores apontando para um relay local.
Para invocações diretas de cliente, valores de ambiente sobrescrevem `.env`; ativação de bootstrap ainda usa presença de `.env` como chave para que artefatos de sentry sejam estado local explícito de opt-in.
`SQX_ENV_FILE` pode apontar invocações diretas de poll/resposta de cliente para outro arquivo estilo `.env`, mas não altera a ativação de bootstrap.

Para ligar:

1. Faça login em [mySquad.io](https://mySquad.io) com X ou Discord.
2. Para a superfície Discord, use o link de instalação do dashboard para adicionar o bot mySquad a um servidor que você administra; a superfície X não precisa de etapa de instalação.
3. Copie o token de emparelhamento do dashboard para o `.env` gitignored desta base Squad como `SQX_PAIRING_TOKEN=<token>`.
4. Inicie uma nova sessão Squad para que o bootstrap capte o token, depois mencione `@mySquad` no X ou mencione o bot em um servidor onde está instalado.

O dashboard é dono da criação de conta, vinculação de identidade, instalação do bot e emissão de token; este documento é dono do que a base Squad local faz com o token uma vez que está em `.env`.

A etapa de bootstrap de início de sessão bloqueada transforma o token em estado local gerado.
Grava `state/x-sentry.check.sh`, um shim de identidade byte-estático para `bin/sq-x-poll.sh`, e `config/x-mode.env`, que exporta `SQUAD_CHECK_INTERVAL=30` para processos de sentry naquela base.
O sentry aceita o shim apenas quando seus bytes correspondem ao conteúdo gerado esperado, depois invoca o script de poll confiável do repositório diretamente em vez de executar fonte de arquivo de estado.
Esta seção é a única dona do contrato de cadência do Relay: uma instância Relay faz poll a cada 30 segundos em vez dos 300 padrão, apenas uma instância Relay acelera porque uma base não-Relay não tem `config/x-mode.env`, e o bloco de operações de supervisão do início de sessão inclui a instrução de cadência quando aquele arquivo existe.
O protocolo de supervisão do harness primário ativo é dona de como a cadência fonte atinge o processo de sentry.
Como `bin/sq-sentry.sh` lê `SQUAD_CHECK_INTERVAL` apenas no início do processo, uma transição de cadência — opt-in enquanto um sentry já está rodando, ou opt-out — é aplicada reiniciando o sentry com escopo de base através do protocolo de harness emitido; bootstrap deliberadamente nunca reinicia o sentry.
Enquanto o away mode está ativo, o daemon é dono do sentry e sua cadência padrão se aplica; cadência Relay de away mode é um follow-up adiado.
Quando o token é removido ou vazio, a próxima etapa de bootstrap de início de sessão bloqueada remove esses artefatos.
Estado estável desligado é silencioso e não grava nada.
Relay continua aditivo ao comportamento de lifecycle não-Relay: bases sem os artefatos gerados mantêm a cadência padrão do sentry e não executam o poll do Relay.
Seu tratamento de requests permanece em scripts `bin/` específicos do Relay e na habilidade `relay-respond`, enquanto o sentry é dono do dispatch autenticado a partir do shim de identidade local gerado.

`bin/sq-x-poll.sh` chama `GET /connector/poll` com `Authorization: Bearer <SQX_PAIRING_TOKEN>`.
HTTP 204 é silencioso.
Uma menção pendente recém-oferecida com `text` não vazio é armazenada em `state/x-inbox/<request_id>.json` e acorda Squad exatamente uma vez com `x-mention <request_id>`.
O poll atomicamente reivindica `state/x-context/<request_id>.offered.json` antes de emitir aquele wake, e ofertas subsequentes do mesmo request ficam silenciosas mesmo após o inbox ser drenado após uma resposta ou dismiss.
Marcadores de oferta compartilham a retenção limitada a sete dias do registro de contexto, então perder ou expirar o marcador local permite que uma oferta de relay acorde Squad novamente.

O objeto relay completo é preservado, incluindo `in_reply_to: {author_handle, text}` quando a menção é uma resposta em uma conversa ou `null` para menções novas.
Ao mesmo tempo, o poll grava um contexto de resposta durável por request em `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`) a partir do mesmo payload autoritário do relay, melhor esforço e com chave por `request_id` para que requests concorrentes nunca sobrescrevam uns aos outros; sobrevive à limpeza do inbox que segue a confirmação, então um follow-up atrasado pode recuperar a plataforma original e orçamento de split mesmo sem vínculo de tarefa.
`recorded_at` começa como o epoch Unix localmente observado de primeira aparição e permanece inalterado quando o mesmo request é novamente pollado.
Uma resposta ao vivo inicial bem-sucedida o atualiza para o tempo que o relay estabelece a vinculação do follow-up; dry-runs, respostas falhadas e follow-ups não o atualizam.
Polls configurados podam registros além da janela local de follow-up, limitados à janela de sete dias do relay; registros legados ou malformados recuam para seu horário de modificação de arquivo para que não possam permanecer indefinidamente.
O registro é gravado apenas quando uma plataforma ou orçamento explícito é realmente conhecido, então uma menção de plataforma desconhecida não deixa entrada inútil.
A habilidade `relay-respond` decide se a menção armazenada é uma solicitação acionável, uma pergunta ou um puro reconhecimento.
Solicitações reversíveis acionáveis são executadas através do fluxo de intake, backlog, dispatch, investigação ou ship conforme apropriado.
Se o trabalho é concluído naquele turno, a resposta pública reporta o resultado.
Se a solicitação gera uma tarefa de execução mais longa, Squad publica um reconhecimento através do endpoint de resposta normal, vincula a tarefa à menção com `bin/sq-x-link.sh` e publica até três follow-ups de conclusão em marcos genuínos, terminando com um `--final` para trabalho Relay-linked comum. Quando uma compromisso promised-final tipado é registrado, `bin/sq-public-followup.sh` é dona da resposta terminal e limpa o vínculo legado após sua recepção ser validada.
Esse vínculo armazena contexto opcional de plataforma de resposta para que follow-ups originados do Discord mantenham o orçamento de mensagem maior do Discord após o arquivo de inbox ter sido drenado.
Resolução de plataforma/orçamento é em camadas e independente do vínculo de tarefa: uma sobrescrever por eixo `SQX_REPLY_PLATFORM` / `SQX_REPLY_MAX_CHARS` (como `bin/sq-x-followup.sh` passa o contexto de um vínculo gravado) vence.
Para qualquer eixo sem sobrescrever, `bin/sq-x-lib.sh:fmx_resolve_reply_context` é dona da ordem de fonte: o registro durável por request é consultado primeiro, depois o payload ainda presente do inbox, depois — para um follow-up postado ao vivo por request_id — uma lookup autoritária do relay via `POST /connector/request-context` (`{request_id}` entrada, `{platform, reply_max_chars}` retorno).
Isso mantém um follow-up de request-id atrasado no orçamento da plataforma original mesmo após o inbox ter sido drenado e com nenhum vínculo de tarefa sobrevivendo; a etapa do relay é confinada ao caminho de follow-up ao vivo para que o caminho de resposta e cada dry-run permaneçam sem rede.
`bin/sq-x-link.sh` segue a mesma ordem ao gravar o contexto de um vínculo novo e requer `jq`; sua lookup de request-context é melhor esforço: sem token ou `curl`; uma resposta não-2xx; uma resposta não resolvida; ou uma versão do relay sem aquele endpoint deixa o contexto desconhecido.
Nesse caso o vínculo ainda é gravado mas `bin/sq-x-link.sh` imprime um aviso alto; e quando a plataforma ou orçamento explícito de um follow-up não pode ser resolvido autoritativamente de nenhuma fonte, `bin/sq-x-reply.sh` o recusa (saída segura 8) em vez de postar com um padrão local — Squad retém e retenta uma vez que ambos os valores sejam recuperáveis.
Vínculos novos começam com `x_followups=0` e o timestamp atual; ao re-vincular a mesma solicitação de relay para uma tarefa sucessora, passe flags pareadas `--carry-count <n> --carry-ts <epoch>` mais qualquer `x_platform=` e `x_reply_max_chars=` anteriores como `--carry-platform <x|discord> --carry-max <n>` para que a sucessora preserve a contagem de follow-up já consumida, a janela original de 7 dias e o orçamento de split de resposta.
Puros reconhecimentos ou menções sem nada a responder são dispensados através de `bin/sq-x-dismiss.sh` antes que o arquivo de inbox local seja limpo.
Dismiss envia `POST /connector/dismiss` com `{request_id}`, publica nenhum texto e diz ao relay para descartar a solicitação em vez de re-oferecê-la ou recuar para uma auto-resposta offline; em caso de sucesso, limpa o registro durável de contexto de resposta daquela solicitação, enquanto o marcador de oferta separado permanece para sua retenção limitada para que uma breve re-oferta do relay fique silenciosa.
Problemas de auth ou config do relay são reportados uma vez como `x-mode-error ...` até a recuperação.
Uma falha durável de claim de oferta é igualmente reportada uma vez como `x-mode-error cannot record mention offer` e permanece deduplicada através de polls silenciosos sem-pending até que uma oferta posterior confirme um marcador válido existente ou reivindique um novo.
Respostas ao vivo são publicadas por `bin/sq-x-reply.sh`, que envia `POST /connector/answer` com `{request_id,text}` para respostas de uma mensagem.
Adicione `--image <path>` para anexar uma PNG, JPEG, GIF, WebP, BMP ou TIFF local como `{media_type,data_base64}` no objeto opcional `image` do relay.
Follow-ups de conclusão usam `bin/sq-x-followup.sh`, que verifica o vínculo local `state/<id>.meta` e envia a mesma forma de payload através de `POST /connector/followup` chamando `bin/sq-x-reply.sh --followup`, até três vezes por vínculo dentro da janela.
Adicione `--image <path>` lá também quando um follow-up de conclusão deve carregar uma imagem.
Uma postagem bem-sucedida incrementa o contador local `x_followups=` e mantém o vínculo, a menos que `--final` tenha sido passado ou a nova contagem atinja o limite, caso em que o vínculo é limpo em vez disso; uma postagem falhada deixa o vínculo e contador intactos para que possa ser retentado.
O próprio relay rejeita um follow-up além de seu próprio limite ou janela com HTTP 409 e pode incluir `{"error":"followup_unavailable"}` no corpo da resposta; o cliente superfaca qualquer 409 de follow-up como um código de saída distinguível e usa o marcador de corpo apenas para um diagnóstico mais preciso.
`sq-x-followup.sh` trata essa saída exatamente como uma expiração detectada localmente — limpa o vínculo e pula silenciosamente em vez de retentar — então um relay mais antigo de follow-up único ou uma vinculação já exaurida degrada graciosamente.
Trata a recusa segura de `sq-x-reply.sh` (saída 8: plataforma ou orçamento explícito não resolvido) diferentemente: essa é uma retenção retentável, então o vínculo é MANTIDO e o follow-up é retentado uma vez que ambos os valores possam ser recuperados, nunca postado com um padrão local.
Rejeições de relay fora da janela são garantidas apenas enquanto a linha de vinculação expirada ainda existe no lado do relay; após sua varredura de limpeza, uma chamada de follow-up muito tardia pode em vez disso ver um 200 inofensivo de no-op, por isso a poda local de janela e limite continua sendo o principal guard.
Split de resposta é consciente de plataforma: um campo de plataforma relay explícito (`reply_platform`, `platform`, `target_platform`, `source_platform` ou `provider`) vence, caso contrário um `tweet_id` legado começando com `discord:` seleciona Discord e um `tweet_id` numérico seleciona X.
Um campo de limite relay explícito (`reply_max_chars`, `reply_max_characters`, `message_max_chars`, `message_limit` ou `max_chars`) vence sobre os padrões da plataforma.
Se a resposta exceder o orçamento selecionado, o cliente a divide em uma thread numerada em limites de código cercado, parágrafo, linha e palavra e envia `{request_id,text,texts}`, onde `texts` é a lista ordenada de chunks e `text` continua sendo o primeiro chunk para relays mais antigos.
Quando `--image <path>` está presente em uma resposta dividida, a imagem vai na primeira/mensagem abridora e chunks posteriores ficam apenas texto.
`SQX_X_REPLY_MAX_CHARS` padrão é 280 e limita a um mínimo de 50; `SQX_DISCORD_REPLY_MAX_CHARS` padrão é 1900, limita a um mínimo de 50 e reseta valores acima do limite de 2000 caracteres do Discord para 1900.
`SQX_X_THREAD_MAX` padrão é 25 e limita threads de resposta grandes demais para cada plataforma, marcando a última mensagem retida com reticências quando truncamento é necessário.
`SQX_FOLLOWUP_MAX_AGE_SECS` padrão é 604800 (7 dias) e controla a janela local de follow-up de conclusão; `SQX_FOLLOWUP_MAX_COUNT` padrão é 3 e controla o limite local de follow-ups.

Defina `SQX_DRY_RUN` para pré-visualizar respostas e dismissals sem postar.
Verdadeiro significa qualquer coisa exceto não-definido, vazio, `0`, `false`, `no` ou `off`; um valor de ambiente explícito vence sobre `.env`.
Em dry-run, `sq-x-reply.sh` grava o payload que seria para `state/x-outbox/<request_id>.json`, incluindo `texts` para uma thread e um marcador `endpoint` para pré-visualizações de follow-up, imprime um resumo `DRY RUN` no stderr, ecoa o `request_id` e sai com 0.
Quando uma imagem é anexada, o registro de dry-run usa metadados compactos `{media_type, bytes, source_path}` em vez de gravar os bytes base64.
Em dry-run, `sq-x-dismiss.sh` grava `{request_id, endpoint:"dismiss"}` no mesmo caminho do outbox, imprime um resumo `DRY RUN`, ecoa o `request_id` e sai com 0.
Os corpos de resposta e follow-up ao vivo intencionalmente permanecem na mesma forma, incluindo `image` opcional; o relay os distingue por endpoint, e dismiss continua `{request_id}`.
Esses caminhos precisam de `jq` para construir o payload JSON, mas são executados antes das verificações de token e rede, então não precisam nem de `SQX_PAIRING_TOKEN` nem de `curl`.

### Respostas públicas prometidas (state/public-followup)

Uma solicitação de relay que gera trabalho real pode deixar Squad devendo uma resposta pública específica em uma thread específica.
Essa promessa é uma obrigação tipada `kind=public-followup` de propriedade exclusiva de `sq-tasks public-followup`, com o contexto completo da solicitação privada permanecendo em `state/x-context/`; Squad não mantém nenhuma cópia paralela de nenhum dos dois.
`bin/sq-public-followup.sh` é o lado do Squad: registra um compromisso, reconcilia resultados de trabalho tipados terminais nele e publica a resposta final através de `bin/sq-x-reply.sh --followup`.
Execute `bin/sq-public-followup.sh --help` para os subcomandos e flags exatos.

Registration é o que cria o transporte privado desta base sob `state/public-followup/` (modo 0700): `registry/` para o vínculo público-seguro limitado de cada compromisso vivo, `events/` para resultados terminais tipados aguardando reconciliação, `consumed/` para o ledger de eventos aceitos, `rejected/` para recusas mantidas com uma linha de motivo e `surfaced` para a assinatura last-surfaced do poll.
A base que detém o compromisso também detém a postagem externa, porque apenas ela detém o consentimento do relay, o contexto da solicitação e a vinculação opaca da thread.
Trabalho roteado para outro lugar reporta um resultado terminal tipado com `bin/sq-public-followup-emit.sh` e nunca procura a thread; esse emissor recusa escrever em uma base sem registro para a obrigação nomeada.
O id de um evento terminal é derivado de sua tupla de identidade, então um relatório duplicado, uma retentativa ou uma reprodução após reinicialização resolve para o mesmo evento e não muda nada.

Activation é o mesmo contrato `.env` `SQX_PAIRING_TOKEN` do resto do Relay, sem segunda flag.
Uma base sem esse token executa um teste de arquivo e para: nenhuma chamada `sq-tasks`, nenhuma varredura de backlog ou request-context, e nenhum diretório `state/public-followup/`.
Startup comum, polling, limpeza e subcomandos silenciosos do lado da leitura também não produzem saída; comandos que requerem um relay ativo reportam aquele erro de configuração após o mesmo gate.
Uma base com relay habilitado sem compromisso registrado para em um check de presença O(1) de diretório, então o estado vazio não custa nenhuma chamada CLI e não adiciona nenhuma varredura periódica.
Resultados terminais não reconciliados usam o poll existente de 30 segundos do relay em vez de um novo processo ou timer: `bin/sq-x-poll.sh` compara a assinatura do evento pendente contra `surfaced` e acorda Squad uma vez por novo conjunto de resultados.
O digest de início de sessão separadamente imprime uma subseção "Public commitments awaiting delivery" do disco quando, e apenas quando, esta base está relay-ativa e ainda deve uma resposta, então compactação e reinicialização são não-eventos.
`bin/sq-teardown.sh` recusa limpar uma tarefa enquanto esta base ainda deve uma resposta pública para exatamente aquele trabalho, a menos que `--force` carregue aprovação explícita de descarte.
`SQUAD_PF_RETRY_BACKOFF_SECS` (padrão 900) define o horário da próxima tentativa gravado com um erro de entrega retentável.
Veja [verification/public-followup.md](../verification/public-followup.md) para a evidência atual do mantenedor por trás do end-to-end de reinicialização e da garantia de zero-overhead com relay desabilitado.

## Telegram bridge (config/telegram-bridge.env)

O Telegram bridge é um relay local opcional que implementa o contrato de conector da seção Relay acima e o traduz para a Telegram Bot API.
É o "relay local" que `SQX_RELAY_URL` pode apontar: o `.env` da base precisa apenas de `SQX_RELAY_URL=http://127.0.0.1:8787` ao lado do `SQX_PAIRING_TOKEN` existente, e a base Squad em execução não precisa de alterações de código.
Apenas o id de usuário Telegram do comandante é aceito como autor da menção, e o conector escuta em 127.0.0.1 por padrão.

Para configurar:

1. Crie um bot com @BotFather e copie seu token.
2. Grava o token e o id de usuário Telegram do comandante no `config/telegram-bridge.env` gitignored desta base:
   `TG_BOT_TOKEN=<token do bot>`
   `TG_ALLOWED_CHAT_IDS=<id de usuário Telegram do comandante>`
3. Coloque `SQX_PAIRING_TOKEN=<token>` no `.env` gitignored da base (o mesmo token que já está lá quando Relay está ligado) e defina `SQX_RELAY_URL=http://127.0.0.1:8787`.

Execute o bridge como o serviço de usuário fornecido para que inicie na inicialização e reinicie quando crashar:

1. Copie `systemd/sq-tg-bridge.service` para `~/.config/systemd/user/`, ajustando o caminho `SQUAD_BASE` dentro dele quando esta base vive fora do layout padrão `~/Projects/squad`.
2. `systemctl --user daemon-reload`
3. `systemctl --user enable --now sq-tg-bridge`
4. `loginctl enable-linger "$USER"` para que o gerenciador de usuário (e portanto o bridge) inicie na inicialização, não apenas após o login.

Verifique com `systemctl --user status sq-tg-bridge` (ativo, reinicializações registradas) e `journalctl --user -u sq-tg-bridge` (o bridge registra cada início no stderr).
Remova o serviço com `systemctl --user disable --now sq-tg-bridge`, depois delete o arquivo de unit copiado e execute `systemctl --user daemon-reload`.
O bridge precisa apenas da biblioteca padrão do Python 3, liga em 127.0.0.1 e registra no stderr (o cabeçalho do script e `--help` são donos dos flags e chaves de config exatos).
Uma reinicialização é não-destrutiva: estado de solicitação de runtime (a fila de pendências, vinculações de follow-up e o offset de atualização do Telegram) vive em `state/telegram-bridge/state.json` (gitignored) e sobrevive a reinicializações do bridge, então uma reinicialização nunca re-ingere uma mensagem já oferecida e nunca re-responde uma solicitação já respondida.

### Canal dual (chat to chat + Telegram)

Quando o comandante quer que respostas de chat também cheguem no Telegram, Squad espelha cada resposta voltada para o comandante com `bin/sq-tg-notify.sh <texto-ou-'-'>` (`-` lê a mensagem do stdin).
O espelhamento é um ping proativo, não uma solicitação de relay: chama a Telegram Bot API diretamente (`sendMessage`) contra o mesmo `config/telegram-bridge.env`, visa a primeira entrada `TG_ALLOWED_CHAT_IDS` e funciona mesmo quando o bridge está fora.
Imprime uma linha `telegram HTTP <code>` para que um chamador possa distinguir um espelhamento entregue de um falhado, e falha fechado (saída 1, nada enviado) quando o arquivo de config, token ou chat id está ausente.
A base home resolve como os outros scripts `sq-*`: `$SQUAD_BASE`, depois legado `$SQUAD_HOME`, depois a raiz deste repositório.
O bridge reporta a plataforma `discord` resolvida pelo cliente com um `reply_max_chars` explícito de 4096.
O cliente relay do Squad resolve apenas as plataformas `x` e `discord` para sua fail-safe de follow-up, e um limite explícito sempre vence sobre o padrão da plataforma, então respostas ainda dividem no orçamento de mensagem de 4096 caracteres do Telegram e follow-ups de conclusão passam a fail-safe.

## Fontes de processo para evento (state/procevent)

Um processo externo de longa polling é registrado como uma *fonte* através de seu adaptador, cujo cabeçalho e `--help` são donos dos comandos e flags.
`bin/sq-procevent.sh` é dona do contrato genérico; `bin/sq-procevent-sq-report.sh` é o primeiro adaptador e encapsula apenas a interface publicada atualmente `sq-report poll`.

Esta seção é a única dona do contrato operacional do runner.
Registration grava um registro privado sob `state/procevent/`, e um resultado concluído mais sua identidade imutável de adaptador são capturados sob `state/procevent-inbox/` antes de ser publicado.
Resultados são publicados como wakes comuns `check` carregando o id da fonte e a sequência de resultado comprometida através da fila durável existente de stand-to, então o runner não adiciona um segundo plano de controle de notificação.
O sentry entrega um resultado em fila em seu ciclo comum reportando-o como um wake acionável `check`, então um resultado capturado alcança Squad pelo mesmo caminho de rewake que todo outro wake usa e nunca espera uma drenagem manual.
Entrega é reportada no máximo uma vez por fonte capturada e sequência enquanto quaisquer registros para aquela chave permanecerem em fila.
Uma confirmação handled durável para futuras re-anúncios, enquanto um registro já em fila permanece sob a autoridade da fila durável até que a drenagem comum o consuma.

Discovery nunca é um timer.
Cada fonte registrada tem seu próprio processo filho bloqueando naquela fonte, e a `reconcile` por ciclo do sentry republica cada resultado capturado que ainda não tem confirmação handled durável — independente de qualquer publicação anterior — reinicia uma fonte cujo proprietário sumiu e para o runner desta base quando a reconciliação roda após seu registro ter desaparecido inesperadamente.
Em estado estável suportado, uma base sem fonte registrada não executa nada, gera nenhum estado e mantém sua cadência comum.

Se um resultado capturado termina sua fonte é conhecimento do adaptador, nunca do runner.
Após tentar publicação, o runner chama `bin/sq-procevent-<adapter>.sh terminal <result-file>` e aposenta o registro na saída 0 apenas, descartando exatamente a geração de registro capturada por seu claim e liberando aquele claim apenas após remoção bem-sucedida sob um limite de fonte; um comando ausente, um erro ou qualquer outra saída mantém a fonte armada, então um adaptador sem noção de término não precisa de alteração.
Uma remoção terminal falhada permanece duravelmente terminal e é completada por reconciliação comum sem reiniciar seu poll, enquanto um registro simultaneamente substituído sobrevive e se torna executável independentemente após o antigo claim ser liberado.
Uma fonte que terminou portanto captura no máximo um resultado terminal, nunca é reiniciada e deixa nenhum trabalho de poll recorrente, enquanto `retire` explícito permanece o caminho suportado e idempotente depois.
Para sq-report esse veredito cobre uma sessão encerrada, uma sessão ausente e o feedback final de uma revisão `Send & End`, que o poll publicado marca com `session_ended` antes de retornar apenas sessões encerradas vazias.

Aplicar um resultado capturado também é conhecimento do adaptador, e alguns resultados não carregam nenhum julgamento: eles devem simplesmente ser aplicados idempotentemente ao estado durável desta base própria.
Deixar isso para um handler significa que pode silenciosamente não acontecer, então imediatamente após o check terminal acima, o runner chama `bin/sq-procevent-<adapter>.sh autohandle <source-id> <sequence> <result-file>` apenas quando o wake desta própria captura foi anexado com sucesso à fila durável, depois deixa o adaptador aplicar e confirmar seu próprio resultado.
Essa chamada é executada estritamente após a aposentadoria terminal, porque um adaptador de handling re-arme sua próxima fonte e aposentar depois descartaria aquele registro fresco e deixaria a fonte silenciosamente morta.
Publicação falhada pula a chamada, e saída 0 significa que o adaptador aplicou e confirmou completamente o resultado; publicação falhada, um comando ausente, um erro ou qualquer outra saída não é uma falha de captura mas deixa o resultado não confirmado e portanto ainda elegível para re-anúncio, então um handler o recebe exatamente como antes e um adaptador sem tal comando não precisa de alteração.
O adaptador de resposta de XO remoto o implementa, então uma resposta capturada alcança seu espelho local de status e estabelece sua expectativa de resposta pendente correlacionada sem nenhuma etapa de handler; o wake publicado ainda alcança Squad, e tratar aquele wake através do adaptador novamente é idempotente.

Ownership é por máquina para cada fonte canônica, porque bases separadas podem compartilhar um armazenamento de fonte subjacente.
Claims vivem sob `$XDG_STATE_HOME/Squad/procevent-claims` (sobrescrever com `SQUAD_PROCEVENT_CLAIM_ROOT`).
Cada claim vincula sua base e PID do runner a uma identidade de processo, geração de claim única e geração exata de arquivo de registro.
Registration, aquisição, substituição, aposentadoria e liberação vinculada a geração são serializadas em um limite global por máquina por fonte.
Um proprietário vivo com identidade correspondente nunca é deslocado, e liberação remove apenas a geração exata que o chamador adquiriu.
Aposentadoria e reconciliação de órfãos sinalizam um grupo de processos do runner apenas enquanto sua identidade de processo gravada ainda corresponde, ou quando o líder gravado sumiu e apenas seu próprio grupo proprietário sobrevive.
Um runner lidera seu próprio grupo de processos, então um claim conta como recuperável apenas quando aquela geração inteira sumiu: um líder crashado cujo grupo ainda tem membros não está obsoleto, e reconcile para aquele grupo sobrevivente e libera sua geração antes de iniciar qualquer substituição.
Se a identidade não puder ser estabelecida para um PID vivo, ou um grupo proprietário sobrevivente não puder ser provado parado, a operação preserva o registro e claim para retentativa segura em vez de adicionar um segundo proprietário.
Um PID vivo cuja identidade não corresponde mais é um PID reutilizado, então é tratado como obsoleto e seu grupo de processos nunca é sinalizado.

Aposentadoria suportada de XO verifica cada base alvo com o comando delimitado `sweep-home` antes da limpeza destrutiva, tira um snapshot de seus registros fora do alvo, depois executa a varredura no limite de exclusão ou retorno final da base.
Se exclusão ou retorno falhar, a limpeza restaura esses registros e os reconcilia antes de devolver a recusa.
Se restauração ou re-armazenamento também falhar, a limpeza devolve um status distinto e reporta o caminho de backup de registro retido para recuperação manual em vez de esconder as waits aposentadas.
A varredura aposenta registros locais e claims globais de máquina fisicamente detidos por aquela base através do mesmo caminho de aposentadoria vinculado a geração e verificado por identidade, e deixa claims de bases estrangeiras intactos.
A limpeza recusa com a base, aluguel, evidência de roteamento, registros, claims e runners retidos quando a identidade é incerta, a ownership é ilegível ou não liberada, ou estado relevante existe sem um script filho capacitado de varredura.
Exclusão manual direta de uma base Squad não é suportada porque pode orfã um filho bloqueador.
Para recuperar, restaure o `bin/sq-procevent.sh` rastreado daquela base, execute `SQUAD_BASE=<base> <base>/bin/sq-procevent.sh sweep-home`, depois re-execute a limpeza suportada.

`SQUAD_PROCEVENT_MAX_OUTPUT_BYTES` (padrão 1048576) limita um único resultado capturado enquanto a fonte roda; saída dimensionada demais é drenada mas truncada com um aviso no stderr em vez de ser encenada ou publicada inteira ou descartada.

O runner prova exatamente um limite de durabilidade: output que alcançou o runner é armazenado no modo `0600` antes de qualquer evento que o referencie ser publicado, e um resultado capturado sem confirmação handled durável permanece elegível para re-anúncio delimitado em qualquer número de drenagens e reinicializações, não apenas a janela de crash logo após a captura.
`bin/sq-procevent.sh handled <source-id> <sequence>` é a única coisa que para a re-anúncio: uma confirmação durável, chaveada por geração, privada, segura de caminho e idempotente que atomicamente verifica e deduplica pela fonte e sequência exatas, então um efeito pareado vinculado ao seu relatório de primeira-vez-vs-repetição nunca é autorizado duas vezes.
A publicação do wake em si continua sendo melhor esforço, então a mesma fonte e sequência podem repetir mesmo antes de qualquer reinicialização; handlers deduplicam aquela identidade em vez de assumir que um wake é único.
O runner não prova nada sobre o lado da fonte, e a confirmação handled não prova nada sobre um efeito externo pareado executado antes dela: um crash entre aquele efeito e a chamada de confirmação pode ainda repetir o efeito em reprodução, então isso nunca é uma garantia genérica de exatamente-uma-vez.
O `sq-report poll` publicado limpa feedback destrutivamente antes de retorná-lo, então um resultado perdido entre aquela limpeza e o runner lendo output do processo é irrecuperável.
Nunca descreva este caminho como pelo-menos-uma-vez, sem-perda ou sem-perda.
`docs/verification/process-event-sources.md` contém as medições e `.agents/skills/process-event-sources/SKILL.md` é dona do procedimento de handling.

## Variáveis de ambiente

Ajuste de runtime via variáveis de ambiente (padrões mostrados):

```sh
SQUAD_BASE=                 # base operacional opcional para a maioria dos scripts, não definido recua para legado SQUAD_HOME, depois raiz deste repositório; sq-send requer explicitamente
SQUAD_HOME=                 # alias legado para SQUAD_BASE, aceito quando SQUAD_BASE não está definido
SQUAD_ROOT_OVERRIDE=        # sobrescreve raiz do repositório Squad, alvo do tangle-guard e hash de base-title zellij/cmux; também sobrescrever legado de raiz inteira quando SQUAD_BASE não está definido
SQUAD_STATE_OVERRIDE=       # diretório state alternativo, principalmente para testes
SQUAD_DATA_OVERRIDE=        # diretório data alternativo, principalmente para testes
SQUAD_PROJECTS_OVERRIDE=    # diretório projects alternativo, principalmente para testes
SQUAD_CONFIG_OVERRIDE=      # diretório config alternativo, principalmente para testes
SQUAD_PROC_ROOT_OVERRIDE=   # /proc root alternativo para leituras de identidade de processo Linux em sq-stand-to-lib.sh e sq-teardown.sh, principalmente para testes
SQUAD_BACKEND=             # sobrescrever backend de runtime opcional para novos spawns; tmux/herdr/zellij/orca/cmux suportam spawns ship/recon, codex-app não é aceito
SQUAD_TRACE_CONTEXT=       # sobrescrever trace-context opcional; veja "Propagação de trace context"
HERDR_SESSION=default  # apenas herdr: sessão nomeada para operações normais de backend; insuficiente para limpeza destrutiva (docs/herdr-backend.md)
SQUAD_BACKEND_HERDR_COMPOSER_LINES=20  # apenas herdr: linhas de cauda escaneadas por caminhos de fallback/guard de composer-state; submissão de confirmação de idle-baseline usa agent-state
SQUAD_BACKEND_HERDR_IDLE_RE='^Type a message\.\.\.$'  # apenas herdr: regex de placeholder de composer vazio após extração de ghost compartilhado mais remoção de borda e prompt
SQUAD_BACKEND_HERDR_BARE_PROMPT_RE='^(❯|›)'  # apenas herdr: glyphs de agente verificados reconhecidos como uma linha de composer DESBORDERADA (bare), por exemplo ❯ do Claude ou › do Codex; uma alternância, não uma expressão de colchete `[...]`, então uma correspondência de bytes de local C nunca falha em um glyph multibyte não relacionado; glyphs de shell permanecem desconhecidos em vez de vazios, e texto fantasma/lugar desenhado lê vazio através de fm_composer_strip_ghost compartilhado (docs/herdr-backend.md "Composer and injection safety")
SQUAD_BACKEND_HERDR_PI_COMPOSER_MAX_LINES=8  # apenas herdr: máximo de linhas admitidas entre o par separador corroborado por identidade nativa do Pi; candidatos mais altos ou ambíguos permanecem desconhecidos (docs/herdr-backend.md "Composer and injection safety")
SQUAD_BACKEND_HERDR_SUBMIT_POLLS=6  # apenas herdr: amostras de agent-state distribuídas pelo orçamento de cada tentativa de Enter ao confirmar uma submissão (docs/herdr-backend.md "Current transport behavior")
SQUAD_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0.6  # apenas herdr: orçamento mínimo de confirmação por Enter antes de pollar agent-state após um idle baseline
SQUAD_BACKEND_ORCA_COMPOSER_LINES=200  # apenas orca: linhas de leitura de terminal escaneadas para localizar a linha de composer para verificação de submissão
SQUAD_BACKEND_ORCA_IDLE_RE='^Type a message\.\.\.$'  # apenas orca: regex de placeholder de composer vazio após remoção de borda/prompt
SQUAD_ZELLIJ_SESSION=Squad  # apenas zellij: sessão nomeada para operações normais de backend e isolamento de teste (docs/zellij-backend.md)
SQUAD_BACKEND_CMUX_COMPOSER_LINES=20  # apenas cmux: linhas de cauda escaneadas para localizar a linha de composer para verificação de submissão
SQUAD_BACKEND_CMUX_IDLE_RE='^Type a message\.\.\.$'  # apenas cmux: regex de placeholder de composer vazio após remoção de borda/prompt
CMUX_SOCKET_PASSWORD=   # apenas cmux: fallback de senha de socket quando config/cmux-socket-password está ausente (docs/cmux-backend.md)
SQUAD_SESSION_START_STATUS_TAIL=5   # linhas state/*.status impressas por tarefa no digest de início de sessão; cada linha é limitada por bin/sq-line-cap-lib.sh
SQUAD_SESSION_START_QUEUED_LIMIT=20   # linhas de backlog queued comuns no digest de início de sessão; linhas in-flight, held e blocked nunca são delimitadas e linhas done nunca são listadas
SQUAD_BOOTSTRAP_DETECT_ONLY=0   # modo de início de sessão interno/somente-leitura: pula varreduras mutantes do bootstrap e imprime texto advisory TANGLE
SQUAD_BOOTSTRAP_NETWORK=all   # divisão de fase de início de sessão interna: all, skip (apenas etapas locais) ou only (apenas etapas de rede); veja bin/sq-bootstrap.sh
SQUAD_STARTUP_NETWORK_TIMEOUT=120   # segundos delimitando toda a etapa de rede adiada; atingir imprime uma linha NETWORK_CHECKS acionável
SQUAD_TASKS_AXI_COMPATIBLE=   # handoff de um salto de compatibilidade de sq-tasks já computado (0 ou 1); consumido quando bin/sq-tasks-lib.sh é fonte
SQUAD_GUARD_READ_ONLY=0    # modo de guard interno/somente-leitura: mantém alarmes mas suprime drenagem, reparo de supervisão e comandos de reparo de checkout
SQUAD_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # linha de continuação do banner; sq-send.sh a sobrescreve para nomear a mensagem solicitada especificamente
SQUAD_POLL=15              # segundos entre ciclos de poll do sentry
SQUAD_HEARTBEAT=600        # segundos base entre varreduras de heartbeat; heartbeats sem mudança são absorvidos quando ocioso
SQUAD_HEARTBEAT_MAX=7200   # teto de backoff do heartbeat
SQUAD_CHECK_INTERVAL=300   # segundos entre checks lentos (polls de merge autenticados, checks customizados ou dispatch do Relay)
SQUAD_CHECK_TIMEOUT=30     # segundos permitidos por script de check lento
SQUAD_PROCEVENT_MAX_OUTPUT_BYTES=1048576   # limite para um único resultado de processo para evento capturado
SQUAD_PROCEVENT_CLAIM_ROOT=                # raiz de claim de fonte global na máquina; padrão $XDG_STATE_HOME/Squad/procevent-claims
SQUAD_CODEX_WATCH_CHECKPOINT=180   # segundos por checkpoint de sentry em primeiro plano na supervisão primária do Codex
SQUAD_CREW_STATE_DRILL_TIMEOUT=10   # segundos permitidos por query de drill dentro de sq-crew-state.sh
SQUAD_TEARDOWN_DRILL_TIMEOUT=10    # segundos permitidos por query de drill ou abort dentro de sq-teardown.sh
SQUAD_CREW_STATE_RUNS_LIMIT=200  # linhas recentes de execução de drill escaneadas quando axi status não pode ser atribuído ao código atual
SQUAD_CREW_STATE_BIN=bin/sq-crew-state.sh   # sobrescrever de teste para o leitor de estado atual usado por triagem de sentry working/paused
SQX_PAIRING_TOKEN=      # token de emparelhamento Relay; opt-in .env autoriza respostas e ações de lifecycle elegíveis
SQX_RELAY_URL=https://mySquad.io   # sobrescrever endpoint Relay opcional, principalmente para desenvolvimento de relay local
SQX_ENV_FILE=           # arquivo .env alternativo opcional para invocações diretas de cliente Relay; bootstrap ainda verifica $SQUAD_BASE/.env
SQX_DRY_RUN=            # verdadeiro pré-visualiza respostas e dismissals do Relay para state/x-outbox/ sem postar ou exigir token
SQX_X_REPLY_MAX_CHARS=280   # orçamento de split por mensagem de resposta X; valores abaixo de 50 limitam a 50
SQX_DISCORD_REPLY_MAX_CHARS=1900   # orçamento de split por mensagem de resposta Discord; valores abaixo de 50 limitam a 50, valores acima de 2000 resetam para 1900
SQX_X_THREAD_MAX=25     # máximo de mensagens em uma thread de resposta auto-dividida
SQX_FOLLOWUP_MAX_AGE_SECS=604800   # janela local para postar follow-ups de conclusão do Relay (7 dias)
SQX_FOLLOWUP_MAX_COUNT=3   # limite local de follow-ups de conclusão do Relay por menção vinculada
TG_BOT_TOKEN=            # Telegram bridge: token do bot do @BotFather (config/telegram-bridge.env)
TG_ALLOWED_CHAT_IDS=     # Telegram bridge: ids de usuário Telegram do comandante separados por vírgula autorizados a enviar solicitações
TG_BRIDGE_BIND=127.0.0.1   # Telegram bridge: endereço de escuta do conector
TG_BRIDGE_PORT=8787     # Telegram bridge: porta de escuta do conector (0 = efêmera)
TG_BRIDGE_CONFIG=        # Telegram bridge: arquivo env alternativo (padrão <SQUAD_BASE>/config/telegram-bridge.env)
TG_BRIDGE_STATE_FILE=    # Telegram bridge: arquivo de estado de runtime alternativo (padrão <SQUAD_BASE>/state/telegram-bridge/state.json)
TG_BRIDGE_SEND_TIMEOUT=8   # Telegram bridge: limite HTTP por envio em segundos (padrão 8; deve ser positivo)
SQUAD_PF_RETRY_BACKOFF_SECS=900   # segundos antes da próxima tentativa após um erro de entrega de resposta pública prometida retentável
SQUAD_LOCK_STALE_AFTER=2   # segundos antes que registros de bloqueio de pid-morto possam ser recuperados; bloqueios no meio da aquisição mantêm pelo menos 2s de graça
SQUAD_GUARD_GRACE=300      # segundos antes que avisos de guard, checks de saúde de armazenamento e o guard de fim de turno primário tratem um beacon de sentry como obsoleto
SQUAD_CLAUDE_AUTOARM_ATTEMPTS=2   # tentativas limitadas de armazenamento Stop-owned por ciclo de auto-arm do Claude; valores aceitos são 1, 2 ou 3
SQUAD_CLAUDE_AUTOARM_SYNC_WAIT_MS=800   # milissegundos que o guard de fim de turno --claude espera por saúde de sentry, uma reivindicação auto-arm Stop verificada por função ou uma nova época antes de decidir propriedade de recuperação ou progressão de falha
SQUAD_CLAUDE_AUTOARM_EPOCH_FRESH=15   # segundos que um resultado auto-arm gravado permanece elegível para a decisão de recuperação ou falha da época de evento atual
SQUAD_CLAUDE_TURNEND_BLOCK_BUDGET=3   # re-bloqueios consecutivos do guard --claude antes do fail-open atendido uma vez verificado; seguramente abaixo do override de 8 blocos do Claude Code
SQUAD_ARM_CONFIRM_TIMEOUT=10   # segundos que sq-sentry-arm espera para confirmar um sentry novo antes de reportar FAILED; padrão 30 no Git Bash/MSYS
SQUAD_ARM_ATTACH_POLL=0.5  # segundos entre checks enquanto sq-sentry-arm está anexado a um ciclo de sentry existente saudável
SQUAD_OPENCODE_ARM_READY_TIMEOUT_MS=12000   # milissegundos que o plugin sentry do OpenCode primário espera para que uma tentativa de armazenamento reporte iniciado, saudável, wake ou falha; padrão 35000 no Windows para ficar acima do orçamento de confirmação do MSYS
SQUAD_PI_ARM_READY_TIMEOUT_MS=12000   # milissegundos que a extensão sentry do Pi espera para que um armazenamento sucessor reporte iniciado ou anexado; padrão 35000 no Windows para ficar acima do orçamento de confirmação do MSYS
SQUAD_WATCH_ARM_RETIRE_TIMEOUT_MS=1000   # milissegundos que Pi/OpenCode espera para que um armazenamento sucessor não-saudável saia antes de abandonar retentativas
SQUAD_WATCH_REARM_RETRY_BASE_MS=250   # atraso base do adaptador Pi/OpenCode para retentativas de restauração de continuidade
SQUAD_WATCH_REARM_RETRY_MAX_MS=4000   # teto do adaptador Pi/OpenCode para atraso exponencial de retentativa de continuidade
SQUAD_WATCH_REARM_RETRY_LIMIT=5   # retentativas de falha de lançamento do adaptador Pi/OpenCode antes de surfacar falha de restauração
SQUAD_WATCH_CYCLE_LOG_MAX_BYTES=262144   # limite de tamanho para o ledger de lifecycle do sentry de propriedade do armazenamento
SQUAD_WATCH_CYCLE_LOG_KEEP_LINES=1000   # linhas de lifecycle completas mais recentes consideradas quando o ledger está no limite
SQUAD_SENTRY_STALE_GRACE=300   # padrão para SQUAD_GUARD_GRACE; segundos que um sentry vivo pode ter um beacon obsoleto antes de erros de re-armazenamento
SQUAD_SIGNAL_GRACE=30      # segundos para consolidar sinais de status e fim de turno próximos em um único wake
SQUAD_COMMANDER_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # regex de status relevante para o comandante; verbos de progresso não-terminais permanecem excluídos mesmo quando seu texto corresponde
SQUAD_CLASSIFY_PAUSED_VERB=paused     # verbo de status inicial para uma espera externa declarada; excluído de SQUAD_COMMANDER_RE e distinto de blocked
SQUAD_STALE_ESCALATE_SECS=240         # segundos ociosos antes que um painel estagnado provavelmente-trabalhando escale; painéis obsoletos cuja crew não está provavelmente trabalhando surfacam imediatamente a menos que declarem o verbo de pausa
SQUAD_BUSY_TURN_MAX_SECS=3600         # idade máxima do marcador state/<id>.turn-ended mais recente de um painel ocupado, ou seu registro state/<id>.meta de spawn antes que qualquer turno se complete, antes que a mesma escalação de wedge usada para um estagnado provavelmente-trabalhando não-ocupado assuma; apenas inspeção, nunca interrupção ou reinicialização automática
SQUAD_PAUSE_RESURFACE_SECS=3600       # segundos antes que uma espera externa declarada ociosa resurfaça para uma re-check no sentry ou daemon de away mode
SQUAD_WEDGE_DEMAND_INSPECT_COUNT=3    # escalações estagnadas provavelmente-trabalhando consecutivas no mesmo painel inalterado antes que demanda-de-inspeção-profunda seja adicionada
SQUAD_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # limite de tamanho para o log de debug de wakes absorvidos do sentry
SQUAD_UNIT_SYNC_BOOTSTRAP_TIMEOUT=     # segundos opcionais permitidos para a melhor tentativa de refresh de clone do bootstrap; não definido/vazio padrão para max(20, 5 + 3 * contagem-de-projetos-com-origem)
SQUAD_FLEET_PRUNE=1        # definir como 0 para pular poda de branches locais cujo upstream sumiu
SQUAD_STALE_WORKTREE_LOCK_AGE_SECS=30       # idade mtime mínima antes que sq-teardown.sh trate um git index.lock de worktree residual como provavelmente obsoleto
SQUAD_FOB_RETURN_LOCK_RETRIES=3        # retentativas após uma falha de retorno de fob na assinatura transitória de git index.lock
SQUAD_FOB_RETURN_LOCK_RETRY_WAIT_SECS=1 # segundos que sq-teardown.sh espera antes de cada retentativa após aquela assinatura
SQUAD_TREEHOUSE_RETURN_LOCK_RETRIES=   # alias legado para SQUAD_FOB_RETURN_LOCK_RETRIES quando a nova variável não está definida
SQUAD_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS= # alias legado para SQUAD_FOB_RETURN_LOCK_RETRY_WAIT_SECS quando a nova variável não está definida
SQUAD_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=   # alias legado para SQUAD_FOB_RETURN_LOCK_RETRY_WAIT_SECS quando a nova variável não está definida
SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_RETRIES=3        # retentativas de fetch após sq-unit-sync.sh atingir a assinatura órfã de .git/packed-refs.lock
SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1 # segundos que sq-unit-sync.sh espera antes de cada uma dessas retentativas
SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_AGE_SECS=30       # idade mtime mínima antes que sq-unit-sync.sh trate um packed-refs.lock residual como provavelmente obsoleto
SQUAD_BUSY_REGEX=          # sobrescrever opcional para guards de entrega renderizados e fallback de estado de tarefa isolado do Grok; estado de worker convertido o ignora
SQUAD_COMPOSER_IDLE_RE=    # regex opcional de composer vazio, aplicada após remoção de ghost e borda
SQUAD_COMPOSER_GHOST_LUMA_MAX=128   # unidade-wide: luminância percebida máxima (0.299R+0.587G+0.114B, 0-255) para um foreground TRUECOLOR contar como texto ghost/lugar desenhado desenhado e ser removido; dim/faint (SGR 2) é removido independente. Assume um tema de terminal escuro (fm_composer_strip_ghost de bin/sq-composer-lib.sh, compartilhado pelos leitores de composer tmux e herdr)
GROK_HOME=              # Grok config home opcional para o hook global grok de fim de turno do Squad; padrão ~/.grok
SQUAD_SEND_RETRIES=3       # tentativas de retry de Enter do sq-send após digitar a linha uma vez
SQUAD_SEND_SLEEP=0.4       # segundos entre checks de submissão do sq-send
SQUAD_SEND_SETTLE=1        # segundos que sq-send espera após uma submissão de texto bem-sucedida; 0 desativa
SQUAD_PENDING_REPLY_GRACE_SECS=120   # segundos após entrega de solicitação marcada antes que um turno concluído sem um relatório pai correlacionado seja elegível para sua única retentativa de repost
# sub-supervisor (bin/sq-supervise-daemon.sh); presence-gated via /afk
SQUAD_SUPERVISOR_BACKEND=             # sobrescrever backend de painel de supervisor opcional; apenas tmux/herdr, caso contrário detecta $TMUX_PANE depois HERDR_ENV/HERDR_PANE_ID antes de fallback tmux
SQUAD_SUPERVISOR_TARGET=              # sobrescrever alvo de painel de supervisor opcional; alvo tmux ou herdr <session>:<pane-id>, caso contrário auto-detectado
SQUAD_INJECT_SKIP=heartbeat           # prefixos |-forçam auto-tratamento ignorando classificação; vazio desativa
SQUAD_ESCALATE_BATCH_SECS=90          # janela de buffer para resumos de escalação em lote; 0 = esvaziar imediatamente
SQUAD_MAX_DEFER_SECS=300              # idade máxima de escalação em buffer antes de retentativa mais alarme wedge; 0 desativa
SQUAD_WEDGE_ALARM_CHANNEL=            # sobrescrever config/wedge-alarm com uma diretriz de alerta ativo para o alarme wedge; off|auto|osascript|herdr|command:<cmd>; ausente = auto (macOS -> uma notificação do SO)
SQUAD_WEDGE_ALARM_EXEC=              # costura de notificador: rota todos os canais (osascript, herdr, command:) através deste comando como `<cmd> <canal> <resumo>`; "discard" não dispara nada; não definido em produção; o daemon o define como "discard" quando fonte para que nenhum teste envie uma notificação real (docs/wedge-alarm.md)
SQUAD_WEDGE_ALARM_TIMEOUT_SECS=10    # segundos máximos para cada notificador osascript, herdr, override ou command: antes de seu watchdog terminá-lo e continuar para o próximo canal; valores inválidos ou zero usam 10
SQUAD_INJECT_FAIL_SLEEP=30            # segundos de backoff quando o painel de supervisor está indisponível
SQUAD_INJECT_CONFIRM_RETRIES=3        # tentativas de retry de Enter do daemon após digitar um resumo uma vez
SQUAD_INJECT_CONFIRM_SLEEP=0.5        # segundos entre checks de submissão do daemon
SQUAD_HEARTBEAT_SCAN_SECS=300         # cadência da varredura de status catch-all para verbos de comandante perdidos
SQUAD_HOUSEKEEPING_TICK=15            # segundos entre flush em lote, re-check de stale/pause e passes de varredura
SQUAD_CRASH_THRESHOLD=10              # crashes de sentry permitidos dentro de SQUAD_CRASH_WINDOW antes de backoff do daemon
SQUAD_CRASH_WINDOW=60                 # segundos na janela de detecção de crash-loop
SQUAD_CRASH_BACKOFF=60                # segundos a esperar após cruzar o limiar de crash
SQUAD_CRASH_NORMAL_SLEEP=5            # segundos a esperar após um crash isolado de sentry
SQUAD_LOG_MAX_BYTES=1048576           # tamanho do log do daemon que dispara truncamento
SQUAD_LOG_KEEP_LINES=2000             # linhas de log do daemon mantidas durante truncamento
```

`sq-teardown.sh` retenta apenas a falha de retorno `Unable to create '...index.lock': File exists` do Git até `SQUAD_FOB_RETURN_LOCK_RETRIES` vezes.
`SQUAD_FOB_RETURN_LOCK_RETRIES` aceita um inteiro não negativo, e um valor inválido usa o padrão de 3.
`SQUAD_FOB_RETURN_LOCK_RETRY_WAIT_SECS` aceita segundos inteiros ou fracionários não negativos entre tentativas.
Quando não está definido ou em branco, `SQUAD_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS` permanece como fallback compatível, depois `SQUAD_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS`, e um fallback em branco usa o padrão de 1 segundo.
Quando `SQUAD_FOB_RETURN_LOCK_RETRIES` não está definido ou em branco, `SQUAD_TREEHOUSE_RETURN_LOCK_RETRIES` permanece como fallback compatível, e um fallback em branco usa o padrão de 3.
Uma espera não-vazia inválida recua para 1 segundo em vez de interromper a limpeza.
A limpeza nunca remove um bloqueio durante a janela de retentativa, e após aquela janela tenta limpeza de bloqueio obsoleto apenas para um bloqueio ainda presente que passa as verificações de idade e detentor ao vivo configuradas.

`sq-unit-sync.sh` aplica a mesma forma a um `.git/packed-refs.lock` órfão: retenta apenas a falha de fetch `Unable to create '...packed-refs.lock': File exists` do Git até `SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_RETRIES` vezes (inteiro não negativo; não definido, em branco ou inválido usa o padrão de 3), esperando `SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS` segundos (inteiros ou fracionários não negativos; inválidos recuam para 1 segundo) antes de cada uma.
Apenas após essas retentativas se esgotarem ele remove o bloqueio, e apenas quando é provavelmente obsoleto — ainda presente, idade mtime de pelo menos `SQUAD_UNIT_SYNC_PACKED_REFS_LOCK_AGE_SECS` (padrão 30) e nenhum `lsof` detentor do arquivo de bloqueio ou do próprio worktree de clone (um `git` vivo mantém isso como seu cwd mesmo na janela após fechar o bloqueio e antes de sair).
Um bloqueio ativo, um `lsof` ausente, qualquer check falhado ou qualquer outra falha de fetch mantém o comportamento atual.
Cada espera, retentativa e remoção é impressa no stderr, e uma recuperação bem-sucedida também imprime uma linha de resumo `recovered:` no stdout para que um refresh de início de sessão — que descarta stderr do unit-sync e repassa apenas stdout — ainda a surfac.
A prova de obsolescência compartilhada vive em `bin/sq-lock-lib.sh`, que tanto `sq-teardown.sh` quanto `sq-unit-sync.sh` usam.
