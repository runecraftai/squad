<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Backend de runtime Herdr

Herdr é um backend experimental nativo de agente com estado de agente nativo por pane e push events.
O Squad exige protocolo Herdr 14 ou mais novo; a verificação ampla de backend cobre versões 0.7.1, 0.7.3, 0.7.4, 0.7.5 e 0.8.0, enquanto features do protocolo 16 continuam condicionadas por disponibilidade.
Presentation spaces default-on têm um piso mais alto de Herdr 0.8.0 pela razão explicada em [Presentation spaces](#presentation-spaces).
Herdr fornece a sessão de terminal enquanto o FOB continua fornecendo task worktrees.
[`configuration.md`](configuration.md#runtime-backend-configbackend--squad_backend) é dona da semântica compartilhada de seleção de backend e metadados.

## Setup

Escolha o Herdr quando quiser estado nativo de busy, idle e blocked e aceitar os limites experimentais abaixo.

Pré-requisitos:

- Protocolo Herdr 14 ou mais novo, instalado de [herdr.dev](https://herdr.dev).
- `jq` para respostas JSON.
- Os requisitos universais de harness e toolchain em [`configuration.md`](configuration.md#toolchain).
- `python3` apenas para ordenação opcional de presentation-space por protocolo 16 e subscrição nativa de eventos.

Herdr é licenciado sob AGPL-3.0-or-later ou comercial.
O Squad invoca sua CLI como processo separado.

Selecione o Herdr com o `config/backend` local contendo `herdr`, `SQUAD_BACKEND=herdr` para um único lançamento, ou um pedido explícito ao Squad.
Um agente second-mate remoto é o único caso sem escolha: sempre roda no Herdr, e [`remote-XOs.md`](remote-XOs.md) é dono daquele requisito e da prontidão que seu host deve atingir.
Também é auto-detectado quando o primário roda nativamente sob `HERDR_ENV=1` e não está dentro do tmux.
Um pane tmux aninhado dentro do Herdr resolve para tmux porque o multiplexador mais interno ganha.
Um spawn auto-detectado do Herdr imprime um aviso de opt-out.

O spawn para antes de criar um container Herdr ou adquirir um worktree de tarefa quando `herdr`, `jq` ou o piso do protocolo estão indisponíveis.
Nenhum provisionamento separado de primeira execução é exigido.

A lane CI necessária instala o Herdr a partir de seu release fixado e o fob da fonte vendada via `bin/sq-install-herdr.sh` e `bin/sq-install-fob.sh`.
Os cabeçalhos desses scripts são donos dos contratos exatos de instalação (assets de release, checksums, limites de download, pré-requisitos de build e gates pós-instalação).
Testes reais de credenciais de harness permanecem opt-in em vez de parte do CI padrão.

## Monitoramento e task containers

A topologia ordinária coloca uma aba de tarefa por endpoint no workspace exato do Squad ou XO que o lança.
Quando o launcher não tem workspace Herdr a herdar, o adaptador mantém um workspace durável com rótulo de base em vez disso.
O rótulo da base primária é `Squad`.
O rótulo de base XO é `xo-<id-XO>`, derivado do marcador validado `.sq-xo-home`.
Um XO lançado pelo primário recebe override de base com escopo estreito durante a criação do container.

Anexe-se à sessão Herdr nomeada selecionada e mude para o workspace de base relevante para monitorar suas abas de tarefa.
A supervisão rotineira usa `bin/sq-peek.sh <id>` e `SQUAD_BASE=<home> bin/sq-send.sh <id> '<texto>'` sem anexar.

Criação de workspace e aba usam `--no-focus`.
A primeira aba num workspace Herdr completamente vazio deve ficar focada porque nenhum alvo prévio existe, mas criação posterior de tarefa não rouba foco intencionalmente.

Herdr não impõe unicidade de rótulo de workspace ou aba, então um rótulo nunca decide para onde um worker vai.
Herdr 0.7.5 exporta `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`, `HERDR_TAB_ID` e `HERDR_WORKSPACE_ID` para todo processo que gerencia um pane, e os próprios comandos de um agente Squad ou XO os herdam.
Formas mais antigas de injeção não são verificadas, então um launcher pane reivindicado sem a identidade injetada do socket não pode ser confiável.
Com presentation spaces desabilitados, um operador ou recon é criado no workspace exato que aquela identidade atualmente resolve, lido ao vivo do Herdr em vez do snapshot injetado, então o worker sempre aparece ao lado do agente que o lançou.
Rótulos duplicados em outro lugar na sessão são irrelevantes, e o workspace globalmente focado nunca é o alvo.
Uma lançamento `--xo` é a exceção deliberada: monta o workspace próprio daquela base XO em vez de entrar no do launcher.

Uma identidade pai reivadicada que não pode ser resolvida exatamente para o spawn antes que qualquer endpoint de worker exista, em vez de recuar para busca por rótulo.
Isso cobre identidade de socket ausente ou inutilizável, launcher pane fechado ou ilegível, pane e aba que discordam de seu workspace, workspace ausente da sessão, e pane pertencendo a outra sessão nomeada ou servidor Herdr.

O Squad rodando inteiramente fora do Herdr não tem workspace de launcher a herdar, então seus workers usam o workspace com rótulo próprio da base, criado no primeiro uso.
Esse caminho precisa do rótulo de base para identificar exatamente um workspace: dois workspaces compartilhando-o são um posicionamento irresolvível e recusam em vez de adotar qualquer um.
Evite nomear um workspace pessoal `Squad` ou `xo-<id>` por essa razão, e porque o adaptador não consegue distinguir essa colisão de rótulo do próprio container dele.
Um workspace XO mais antigo usando `Squad-<id>` não é migrado automaticamente; renomeie-o manualmente antes de esperar que novas tarefas ou recovery o usem.
Recovery e list-live ainda escaneiam o primeiro workspace correspondente ao rótulo de base, porque endereçam panes que já registraram em vez de escolher onde novo trabalho vai.

Operações existentes de tarefa usam IDs de endpoint registrados e não movem uma tarefa viva quando rótulos mudam.
O workspace por base é reutilizado enquanto tem abas de tarefa.
Fechar sua última aba pode remover o workspace, e o próximo spawn o recria.

## Presentation spaces

Cada novo operador ou recon é colocado em um workspace descartável de uma tarefa por padrão, no Herdr 0.8.0 e mais novo.
Uma base opta-out escrevendo `off` no local gitignored `config/herdr-presentation-spaces`, e força a projeção escrevendo `on`.
Um arquivo ausente deixa a escolha para o piso de versão abaixo, um arquivo vazio e o valor `on` são ambos opt-in deliberado, valores são comparados com whitespace removido e caso ignorado, e um valor não reconhecido avisa e segue o default não configurado em vez de falhar um spawn por uma configuração puramente visual.
O arquivo vazio é a forma histórica de opt-in baseada em presença, então toda base que já habilitou a projeção continua habilitada sem passo de migração, e nenhuma base previamente habilitada pode ser desligada pelo default ou pelo piso.
Uma base que nunca criou o arquivo ganha a projeção no próximo spawn Herdr em um release suportado; essa mudança é deliberada, e alcança apenas o backend Herdr porque nenhum outro backend de runtime tem caminho de projeção.

Projetar cada tarefa em seu próprio workspace faz toda limpeza de tarefa uma remoção que esvazia workspace, que é o único formato de remoção que o defeito de foco pré-0.8.0 do Herdr afeta, e o plano de remoção focus-safe abaixo só consegue evitá-lo enquanto o shell do pane sendo fechado pode ser provado solteiro, sem filhos e ocioso.
Um filho persistente daquele shell - um `gitstatusd`, um worker `zsh-async` ou `direnv` - falha essa prova permanentemente e força o fechamento explícito simples, que nessas versões move o workspace ativo por aproximadamente um sétimo de segundo antes de o backstop de restauração puxá-lo de volta, uma vez por limpeza de tarefa.
Uma base não configurada portanto é projetada apenas em release no ou acima do piso 0.8.0, onde toda primitiva de remoção de workspace preserva foco e aquela prova deixa de ser load-bearing.
Abaixo do piso uma base não configurada usa o layout ordinário flat por base em vez disso e avisa uma vez por base por release detectado, nomeando o release em execução e o upgrade que restaura a projeção.
Esse registro de-um-aviso-por-release é um marcador `state/.herdr-presentation-floor-<release>`; deletá-lo apenas faz o mesmo aviso aparecer novamente, e um upgrade ou downgrade re-anuncia-se porque o release é parte da chave.
O piso lê tanto o protocolo e versão do cliente instalado quanto os sinais do servidor da sessão nomeada selecionada enquanto aquele servidor está rodando, exige que ambos os releases aplicáveis passem, e usa apenas o cliente quando o status reporta positivamente que nenhum servidor está rodando porque aquele cliente o iniciará.
O default não configurado é reconferido depois que o servidor é iniciado ou adotado e antes que qualquer journal de apresentação ou workspace seja criado, enquanto estado ou release ilegível do servidor é tratado como não suportado em vez de adivinhado.
Um `on` explícito é honrado abaixo do piso, então uma base que deliberadamente optou-in nunca é silenciosamente downgradada; ela aceita aquele movimento de foco documentado, e o restore exato de prev-tab permanece seu backstop.
O piso tem um único dono, o gate de spawn, então limpeza para uma projeção que já existe sempre roda e nunca abandona um workspace, qualquer release que a base esteja agora.
Fazer upgrade do Herdr para 0.8.0 ou mais novo é o fix; escrever `off` é a mitigação imediata para uma base que ainda não pode fazer upgrade.
A configuração é herdada em bases XO pelo normal dono de convergence de config, e o default não precisa de convergence especial: o arquivo ausente do primário e o arquivo ausente do XO significam o mesmo default não configurado, então deixá-lo converte um XO para aquele mesmo default em vez de desligá-lo, e apenas um `off` primário explícito propaga o opt-out.
Um agente XO em si permanece sempre no workspace pai ordinário dele; apenas filhos lançados por aquela base são elegíveis.
Um opt-out não convergido mantém a projeção padrão naquela base até a convergência.

Apresentação é uma projeção visual de melhor esforço, nunca autoridade de posse ou ciclo de vida de tarefa.
Apenas uma tarefa nova sem metadados nem journal de apresentação existente é elegível para criação projetada.
O Squad publica atomicamente um journal de três campos versão 1 contendo um token base64url de 128 bits aleatórios antes de pedir ao Herdr para criar qualquer coisa.
Depois que o novo workspace converge para um endpoint exato de tarefa sob um workspace id exato pai, o journal avança para um binding versão 2 que registra a base física, sessão nomeada, endpoint, pai e rótulos imutáveis esperados.
Outro pai com o mesmo rótulo de apresentação não impede a publicação nem participa de reclaim no restart.
O token é visível no título do workspace porque o Herdr não expõe campo oculto e persistido verificado, mas nem token, título nem journal autorizam send, captura, posse de tarefa, retorno de FOB ou recovery geral.

O pai dono é o workspace exato próprio do launcher, resolvido da mesma identidade que o caminho flat usa, e recua para lookup único por rótulo de base apenas para um Squad fora do Herdr.
Filhos projetados nunca são colapsados de volta àquele pai; é a referência de posicionamento e ordenação que a projeção está vinculada.
A aba normal de tarefa `sq-<id>` é criada no workspace exato novo devolvido pelo Herdr.
Apenas a aba default semeada exata devolvida pela mesma resposta de criação de workspace pode ser podida.
Antes e depois de create, prune, abort de limpeza e limpeza normal, o Squad verifica exatos workspace, aba, pane e ids de focus ativo.
Uma resposta ambígua não concede autoridade de mutação ou limpeza.

Protocolo 16 expõe `workspace.move` sobre o socket de sessão nomeada mas nenhuma subcomando CLI.
`bin/backends/herdr-workspace-move.py` envia apenas aquele método whitelistado e verifica a ordem completa de workspaces devolvida.
Filhos projetados são colocados em um bloco contíguo imediatamente após sua base dona quando o layout da sessão, protocolo, socket, `python3` e o lock privado por sessão da máquina são todos verificáveis.
Rótulos legados de filho existentes podem se estender a um bloco já adjacente read-only mas nunca são renomeados ou migrados.
Um filho estrangeiro, ambíguo, detached ou manualmente interleaved faz a ordenação pular com um aviso em vez de reescrever o layout.

Falha de ordenação nunca falha o spawn de tarefa.
O Squad não retenta, adota, reutiliza, fecha, deleta ou renomeia nada em resposta a método indisponível, contenção de lock, socket ambíguo, resposta perdida, falha de move ou divergência de verificação.
O worker permanece no caminho ordinário flat ou Herdr-current-order.

Metadados normais de tarefa permanecem a única autoridade de endpoint depois da criação.
Cleanup fecha apenas o pane exato registrado da tarefa e nunca chama `workspace close`.
O close explícito do Herdr 0.7.5 move foco para um vizinho sempre que esvazia um workspace não-focado, enquanto sua remoção de pane-death preserva o workspace focado sempre que o workspace morrendo está atrás dele ou o workspace focado é o último; ambos os comportamentos são corrigidos no Herdr 0.8.0, e as regras exatas vivem no cabeçalho do adaptador de `bin/backends/herdr.sh`.
Cleanup projetado portanto roda sob o mesmo lock de sessão, captura a aba ativa exata, recusa deletar a aba ativa, e trata um close que esvazia workspace como remoção focus-safe: verifica que o close esvazia o workspace, reposiciona o workspace condenado atrás do focado através do transporte verificado `workspace.move` quando necessário, prova que o pane segura um shell solitário ocioso, e termina aquele shell para que o Herdr remova o workspace esvaziado através de seu caminho de pane-death que preserva foco.
O move-to-last de reposição preserva a ordem relativa de cada workspace sobrevivente, e a remoção é confirmada contra o workspace exato movido em vez de inferida do desaparecimento do pane antes de uma remoção não confirmada fazer uma tentativa verificada sob o mesmo lock de sessão para rollback do workspace condenado à sua posição exata original.
Se aquele rollback não conseguir restaurar a ordem original verificada, cleanup avisa ruidosamente e deixa os registros retidos para inspeção em vez de retentar a mutação do layout compartilhado.
Os sinais de pane-death são pid-exatos: a escalação relê as informações de processo do pane e recusa a menos que o mesmo pid de shell ainda passe a prova estrita de ownership de bare-idle, então um pid que saiu e foi reutilizado nunca recebe sinal.
Qualquer ambiguidade, move não suportado ou falhado, ou shell não provado recua para o fechamento explícito simples, e o restore exato de prev-tab permanece o backstop por trás de todo close, então comportamento degradado nunca é pior que o restore sub-segundo pré-mitigação.
Remoção normal de tarefa não projetada serializa através do mesmo lock de sessão, aplica o mesmo plano focus-safe quando seu close esvaziar um workspace não-focado, mantém o close simples legítimo quando o alvo é a aba ativa, e recusa um close unlocked se o lock não puder ser adquirido.
Cleanup de tarefa adquire aquele lock de sessão antes que a cópia isolada da tarefa seja retornada, então contenção de lock recusa de cara enquanto a cópia, todo registro durável, e o endpoint estão todos intactos para rerun simples.
Cleanup forçado de XO pré-check recursivamente cada endpoint filho Herdr e adquire cada lock de sessão nomeada afetada antes de mutar qualquer filho, depois retém a identidade durável de cada filho a menos que aquele pane exato retorne not-found estruturado após seu close.
Registros duráveis de tarefa são apagados apenas quando o pane exato é confirmado como ido através de sua presença estruturada: após todo caminho de close, apenas uma resposta estruturada de not-found conta como ido, enquanto resultado presente ou unknown retém todo registro com erro visível e retryable.
Identidade de endpoint ausente ou malformada e mecanismo de confirmação ausente são ambiguidade, nunca prova de pane ido, e recusam remoção de registro da mesma forma.
Se lock, snapshot, identidade de pane ou restauração for ambígua, cleanup avisa e preserva o journal para inspeção manual.

Recovery é deliberadamente conservador e apenas de apresentação.
Um journal existente suprime outro create projetado.
Antes de qualquer mutação de recovery, o Squad segura tanto o lock de spawn da tarefa quanto o lock de apresentação da sessão nomeada.
Um binding versão 2 de mesma identidade pode substituir um husk exato livre-de-agente no restart in-place apenas quando a base física, sessão, endpoint de metadados, match de token único, formato e rótulos do workspace, identidade e posicionamento do pai, e snapshot de foco não-alvo todos concordam.
A aba e o pane substitutos são criados e verificados antes que o pane antigo seja reconferido e fechado, depois o journal avança atomicamente para o endpoint substituto antes da publicação de metadados.
O caminho de reclaim nunca move, fecha, deleta ou renomeia um workspace e nunca toca em pai, irmão, comandante ou pane estrangeiro.
Uma substituição falhada faz rollback apenas do novo pane exato derivado da resposta quando a verificação focus-safe o permite.
Journals versão 1, panes mortos ou ausentes, tokens duplicados ou ausentes, espaços renomeados ou detached, divergências cross-base, bindings de endpoint inconsistentes, abas alvo ativas, e identidade ou foco ambíguos recuam flat sem mutar a projeção antiga quando o risco de duplicação de agente está positivamente ausente.
Um endpoint vivo ou desconhecido registrado ou com match de token recusa launch duplicado.

Locked session start tem uma limpeza mais estreita para um filho projetado restaurado que não é mais estado atual da tarefa.
Roda apenas quando a base atual tem pelo menos um journal ordinário de apresentação e considera apenas aquela base; um primário nunca varre recursivamente uma base XO.
Descoberta começa da gramática exata atual `└ <tarefa-concisa> · p:<token-22-caracteres>` mas título ou token sozinhos nunca são autoridade de mutação.
O título deve conter exatamente uma ocorrência de token no snapshot da sessão nomeada e deve igualar o título derivado de exatamente um journal válido de apresentação no `state/` própria desta base; um journal versão 2 adicionalmente deve bindar esta base física exata, sessão nomeada, workspace, aba e pane.
Os metadados ordinários da tarefa devem estar ausentes, e o candidato deve ter exatamente uma aba e exatamente um pane.
Antes do cleanup, o Squad adquire o lock de spawn do task-id existente e depois o lock de apresentação compartilhado da sessão nomeada.
Dentro de ambos os locks ele tira um snapshot exato, requer um foco não-alvo não ambíguo e o título, token, aba e formato exatos de pane, confirma positivamente nenhum agente registrado, e lê as informações de processo do Herdr para o pane exato da sessão nomeada.
A prova de processo requer um shell ocioso reconhecido como tanto o processo do shell quanto o único membro do grupo de processos em foreground, uma linha da tabela de processos do sistema operacional para aquele shell, nenhum processo filho, e um estado de shell sleeping ou ocioso.
A prova retenta samples estritos únicos por uma janela limitada de settle porque um shell interativo ocioso hospeda transitoriamente helpers curtos de prompt; um pane genuinamente ocupado falha todo sample.
Qualquer comando em foreground, processo filho, job de shell ativo, shell desconhecido, tabela de processos ilegível, campo ausente, ou erro de API preserva o pane.
O Squad imediatamente revalida o mesmo journal, ausência de metadados, título do workspace e unicidade de token, topologia de-uma-aba-e-um-pane, relação exata de pane, ausência de agente, prova de processo e foco não-alvo antes de chamar o helper existente de close que preserva focus do pane exato.
Ele fecha apenas aquele pane, nunca um workspace.
O journal correspondente é aposentado apenas depois que o pane exato é positivamente confirmado como ido; um close não confirmado retém o journal, enquanto um close confirmado pode aposentá-lo mesmo quando a restauração de foco reportou erro após o close.
Uma segunda execução não encontra título ou journal correspondente e é um no-op.
Título ou token malformado ou ausente, token duplicado, zero ou múltiplos matches de journal, binding cross-base versão 2, metadados atuais, agente registrado ou desconhecido, aba ou pane extra, alvo ativo, lock ocupado, revalidação mudada, checagem ilegível, ou qualquer erro preserva o candidato e deixa o startup da sessão continuar com no máximo um aviso conciso.

Compromissos operacionais:

- Agrupamento é de melhor esforço; apenas um binding exato de mesma identidade versão 2 sobrevive a um restart Herdr in-place.
- Uma publicação de journal falhada ou criação de workspace projetado para aquele spawn em vez de recuar flat, então uma falha de criação Herdr aparece como falha de spawn em toda base Herdr em vez de apenas em bases que optaram-in; toda degradação anterior no caminho fresh de projeção (sem servidor de sessão, lock de apresentação contedido, pai ausente ou ambíguo) ainda avisa e continua flat.
- Recovery de um journal de apresentação existente deliberadamente recusa o spawn quando o lock de apresentação compartilhado está contedido em vez de recuar flat, e default-on torna essa recusa alcançável em qualquer base Herdr.
- Layouts existentes não são renomeados forçadamente ou reorganizados.
- Bindings de restart ausentes ou ambíguos recuam para o workspace de base ordinário enquanto a projeção antiga permanece intacta.
- Crashes, respostas perdidas, cleanup de pane exato falhado, ou renomes humanos podem deixar espaços em quarentena; session start remove apenas a forma exata local-à-base, unicamente correlacionada-ao-journal, sem-filho-shell-ocioso acima.
- Espaços não têm caminho de cleanup cross-base, e um filho XO só pode limpar a partir da base exata dele.
- Toda espaço que parece stale fora daquela prova restrita de startup ainda requer cleanup manual na UI do Herdr após inspeção humana.
- Recuperar um espaço dedicado após degradação exige parar a tarefa flat, verificar manualmente a projeção stale, e limpar seu journal antes de um launch genuinamente novo.
- O token visível é apenas um correlator estável entre restarts e nunca substitui o binding exato.

`tests/sq-backend-herdr-presentation-e2e.test.sh` cobre ordenação multi-base, concorrência, contenção de lock, coexistência legada, preservação de foco, substituição de restart de mesma identidade exata, bindings e tokens ambíguos, e cleanup de pane exato através do caminho protegido de lab.
`tests/sq-herdr-session-cleanup.test.sh` cobre toda fronteira de descoberta, ownership, topologia, processo, lock, revalidação, foco, aposentadoria e continue-on-error.
`tests/sq-herdr-session-cleanup-e2e.test.sh` cobre o cleanup de shell restaurado num lab nomeado protegido não-padrão.
`tests/sq-backend-herdr-focus-flash-e2e.test.sh` reproduz o roubo de foco raw explícito-close no release instalado e prova que o plano de emptying-close focus-safe remove um workspace condenado sem intervalo de foco errado; [`verification/runtime-backends.md`](../verification/runtime-backends.md#workspace-removal-focus-safety) é dono da evidência versionada ativa.

## Segurança de poda de aba default

`herdr workspace create` semeia uma aba default.
O Squad poda-a apenas depois que uma aba de tarefa real existe e apenas quando a mesma resposta de create forneceu o id de aba semeada.
Um workspace adotado nunca fornece aquele id e nunca pode entrar no caminho de poda, independente de rótulos ou contagem de abas.
Imediatamente antes do close, o Squad reconferir a aba exata, rótulo de seed esperado e estado nativo do agente.
Um pane de seed working nunca é fechado.

Este gate de criado-vs-adotado é uma fronteira de segurança destrutiva.
Uma heurística anterior de rótulo poderia adotar um workspace de posse do comandante chamado `Squad` e fechar sua aba viva em formato de seed.
O gate estrutural atual remove inferência de rótulo da autoridade de cleanup.
`tests/sq-backend-herdr-prune-safety-e2e.test.sh` reproduz a colisão numa sessão nomeada isolada e prova que o pane adotado permanece intacto.

## Metadados de endpoint

```text
backend=herdr
window=<session>:<pane-id>
herdr_session=<session>
herdr_workspace_id=<workspace-id>
herdr_tab_id=<tab-id>
herdr_pane_id=<pane-id>
```

Um id de pane Herdr contém dois-pontos, então o adaptador divide `window=` apenas no primeiro dois-pontos.
O pane registrado é o caminho rápido operacional.
IDs de workspace e aba suportam verificação e cleanup mas não são inferidos de rótulos mutáveis durante operação normal.

## Comportamento atual de transporte

O adaptador inicia e faz polling de um servidor nomeado antes de chamadas de workspace, aba, pane ou agente.
Toda invocação Herdr passa por `fm_backend_herdr_cli`, que configura o ambiente e passa um `--session <nome>` explícito no final.
Uma variável de ambiente sozinha não é confiável quando outro servidor Herdr está rodando.

Texto literal e Enter são operações separadas para steers ordinários.
Comandos fixos no momento de spawn podem usar a primitiva atômica de run do Herdr.
Enter, Escape e Ctrl-C são suportados.
Input com prefixo de slash e dollar usa o settle compartilhado ciente-do-harness antes do primeiro Enter para que um popup de completion não o consuma.
Texto é digitado uma vez; apenas Enter é retentado.

Em uma baseline nativa idle ou done, confirmação de submit espera por `working` ou `blocked` em uma janela de polling limitada.
Em uma baseline já ativa ou ilegível, recua para clearance conservador de composer.
Um alvo totalmente ilegível para de retentar e reporta unknown.
A densidade de polling limita a possibilidade residual de um turno completo extremamente rápido; uma transição perdida pode causar apenas um Enter redundante em composer vazio, nunca texto de mensagem duplicado.

`pane read --lines N` pode devolver saída vazia quando N está abaixo da altura do viewport.
O dono da captura solicita pelo menos 200 linhas do Herdr e trima localmente ao limite do chamador.
Este piso generoso é exigido para leituras de composer e peek pequenas.

O estado nativo de agente do Herdr pode ler idle enquanto um harness espera sua própria ferramenta longa em foreground.
O caminho compartilhado de crew-state portanto aceita um `busy` nativo como evidência de atividade mas nunca um `idle` nativo como evidência de que um worker parou; o estado busy semântico da própria tarefa (`bin/sq-busy-lib.sh`) decide isso.
Um diálogo de permissão bloqueado por humano não tem banner de busy e ainda aparece.

## Segurança de composer e injeção

Herdr não tem primitiva nativa de linha de cursor.
O adaptador localiza a linha bordada reconhecida mais inferior, linha `❯` do Claude, linha `›` do Codex, ou uma região separadora do Pi admitida apenas quando a identidade nativa é exatamente Pi e o estado é idle, done ou blocked.
Um Pi working, linha intermediária pendente, identidade ausente, par de separador incompleto, ou candidato alto demais permanece pending ou unknown.

Captura ANSI preserva estilo de placeholder desenfatizado.
`bin/sq-composer-lib.sh` é o dono unitário que remove trechos dim ou faint e placeholders dark truecolor enquanto retém input digitado bright.
Se uma versão futura do Herdr remover estilo ANSI, ghost suggestions ficam pending em vez de vazio, o que postpone com segurança a injeção e eventualmente eleva o alarme wedge.

Um prompt de shell puro nunca é um composer vazio de agente.
Injeção do modo ausente procede apenas em resultado positivo de `empty`, nunca em unknown.
Isso impede que um pane morto de agente receba e possivelmente execute uma escalação como input de shell.

O envelope operacional atual começa com U+2063 e `SQUAD_OP: `.
O carrier separado de routed-request usa `[sq-from-squad]` mais U+2063.
U+2063 sobrevive ao input de terminal Herdr como texto, diferente do separador ASCII legado que poderia apagar o rótulo de roteamento visível.
`bin/sq-operational-input.sh` é dono da construção e parsing operacionais atuais, e a skill AFK é dona da compatibilidade legada de away-input.
Nenhuma cópia específica do Herdr desse protocolo existe.

## Comportamento de restart e vitalidade

Parar e reiniciar um servidor Herdr nomeado preserva IDs de workspace, aba, pane e rótulo, mas os processos de harness subjacentes e registros vivos de agente não sobrevivem.
Uma aba restaurada com mesmo rótulo e pane ausente ou agente não registrado é um husk.
Create substitui apenas um husk confiadamente morto ou sem-agente, cria o substituto antes de fechar a aba antiga, e recusa estados vivos ou desconhecidos.
Isso impede fechar a última aba do workspace antes que um substituto exista.

A sonda genérica de vitalidade de agente do Herdr reutiliza o mesmo classificador.
Um pane estruturalmente ido vira `missing`, um shell restaurado sem agente vira `dead`, um agente registrado vira `alive`, e uma leitura inesperada vira `unreadable`.
Diferente da inspeção de nome de processo do tmux, o registro nativo pode classificar o Pi sem adivinhar a partir de um nome genérico de interpretador.

A varredura de início de sessão usa esta sonda.
Vitalidade de XO no meio da sessão não é implementada porque XOs ociosos são deliberadamente isentos de escalação de pane stale e precisam de um sinal periódico de identidade separado.

## Push events e fallback de polling

Protocolo 16 pode subscrever `pane.agent_status_changed` através de um reader limitado de socket Unix.
`bin/sq-transition-lib.sh` é dono do vocabulário e política de transição neutros ao backend.
O adaptador Herdr subscreve antes de reconciliar níveis atuais, buffera edges durante reconciliação, e retorna transições blocked frescas para os panes desta base.
A sentinela mapeia o pane de volta à tarefa e pula endpoints XO e esperas declaradas `paused:`.

O caminho push apenas encurta latência.
Polling roda a cada ciclo e permanece o fallback permanente quando protocolo 16, schema de eventos, Python, conexão, subscrição, ou execução repetida do reader estão indisponíveis.
Ainda existe um processo de sentinela; o event reader é um filho limitado daquela sentinela.

`tests/sq-backend-herdr-eventwait-smoke.test.sh`, `tests/sq-transition-lib.test.sh` e `tests/sq-sopervision-events.test.sh` cobrem capacidade, ordenação subscribe-then-reconcile, dedupe, isenções e fallback de polling.

## Suporte do supervisor do modo ausente

O daemon away suporta apenas panes supervisor de tmux e Herdr.
Ele recusa Zellij, Orca e cmux como backends de supervisor em vez de aplicar o transporte errado.
Para Herdr, existência do alvo, estado nativo, captura, estado do composer e submit verificado todos roteiam pelo dispatcher compartilhado do backend e o dono explícito de CLI da sessão nomeada.
O alerta pane-independente de max-defer é configurado em [`wedge-alarm.md`](wedge-alarm.md).

Harnesses com execução rastreada nativa de segundo plano podem rodar o daemon em seu terminal.
Pi não tem tal mecanismo.
`bin/sq-afk-launch.sh` portanto cria um workspace Herdr dedicado sem foco, roda o daemon lá com alvo e backend explícitos de supervisor, registra o pane exato do daemon, e fecha apenas aquele pane no stop.
Ele nunca divide a aba ativa do comandante e nunca usa shell `&`.
Recovery reconcilia apenas o id exato registrado.

No stop, o daemon recebe terminação enquanto `state/.afk` ainda existe para que seu flush final possa rodar, o terminal registrado é fechado, e a flag AFK é removida por último.
Uma entrada nova limpa caches de escalação transientes obsoletos, enquanto registros duráveis de fila e tarefa permanecem autoritativos.

## Segurança de lab destrutivo

Nunca use `herdr server stop` ambiente para verificação Squad.
Uma seleção de sessão apenas por ambiente pode silenciosamente alcançar outro servidor rodando, e o comando stop ambiente não tem alvo explícito.

`bin/sq-herdr-lab.sh` é o único helper de ciclo de vida suportado para verificação isolada.
Ele provisiona apenas nomes não-padrão começando com `sq-lab-`, appenda `--session` explícito a comandos de tarefa permitidos, recusa flags de sessão fornecidas pelo chamador e subcomandos de ciclo de vida server/session, e realiza stop/delete destrutivo apenas através de suas ações de ciclo de vida protegidas.
Imediatamente antes de toda chamada destrutiva ele re-consulta a sessão nomeada e recusa identidades vazias, ausentes, `default` literal ou `default:true`.
Seu tripwire antes/depois exige que o snapshot live da sessão padrão permaneça idêntico em bytes.

O cabeçalho do helper e `--help` são donos dos comandos exatos.
Testes usam wrappers finos de compatibilidade em `tests/herdr-test-safety.sh` e nunca duplicam a política destrutiva.

## Limites ativos

- Herdr continua experimental.
- Ordenação de apresentação precisa de protocolo 16 e Python e é apenas de melhor esforço.
- Rótulos mutáveis podem colidir; nunca são autoridade de posicionamento ou destrutiva.
- Um Squad fora do Herdr não consegue resolver um workspace de launcher, então um rótulo de base colidente recusa novos spawns até que a colisão seja resolvida.
- Reconhecimento de ghost e placeholder depende de desenfatização ANSI e falha com segurança para pending quando indisponível.
- Vitalidade de XO no meio da sessão não é implementada.
- OpenCode 1.18.4 pode aceitar Enter enquanto ocupado sem limpar o composer.
  O backend tmux tem fallback de busy-queue, mas o Herdr ainda reporta este caso como submit pending e precisa de fix separado no adaptador.
- Apenas tmux e Herdr podem hospedar o terminal do supervisor do modo ausente.

## Pontos de entrada de regressão

```sh
tests/sq-backend-herdr.test.sh
tests/sq-backend-herdr-smoke.test.sh
tests/sq-backend-herdr-prune-safety-e2e.test.sh
tests/sq-backend-herdr-respawn-idem-e2e.test.sh
tests/sq-backend-herdr-workspace-per-home-e2e.test.sh
tests/sq-backend-herdr-launcher-workspace-e2e.test.sh
tests/sq-backend-herdr-presentation-e2e.test.sh
tests/sq-backend-herdr-eventwait-smoke.test.sh
tests/sq-herdr-session-cleanup.test.sh
tests/sq-herdr-session-cleanup-e2e.test.sh
tests/sq-afk-inject-herdr-e2e.test.sh
tests/sq-afk-pi-herdr-return-e2e.test.sh
```

Testes reais do Herdr usam o helper de lab nomeado e o tripwire da sessão padrão.
[`verification/runtime-backends.md`](../verification/runtime-backends.md#herdr) é dona da evidência ativa de versão, CLI, projeção, evento e ciclo de vida sem cronologia específica de tarefa.
