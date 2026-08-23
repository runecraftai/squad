<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Viabilidade do modo Calm por harness

Este documento é dono da evidência de viabilidade com escopo de versão, da taxonomia de transcript do Pi e das fronteiras de API suportada para o modo Calm do Squad.
[`calm.md`](calm.md) é dona do contrato atual de uso e limitações do `/calm` voltado ao usuário.

## Superfície exigida da extensão

Uma implementação qualificante precisa auto-carregar do projeto confiável, persistir a escolha de toggle para a base Squad efetiva entre inícios e resumes de sessão Pi, manter atividade de trabalho visível, emitir nenhuma linha de status Calm, redesenhar linhas controláveis já renderizadas, remover linhas ocultas suportadas sem lacunas, restaurar renderização ordinária, e deixar entrega, execução de ferramentas, contexto do modelo, armazenamento de sessão, operação de export e share, diagnósticos e estado de expansão inalterados.
A política de apresentação governante permite prompts genuínos originais de usuário, texto genuíno voltado ao usuário de assistente, e atividade de trabalho.
Atividade de trabalho pode ser apresentada pela linha padrão do Pi ou por um widget controlado pelo Calm suportado, mas o Calm precisa deixar a linha padrão intacta sempre que estiver desligado.
Mudar contexto persistido para remover conteúdo oculto, filtrar contexto do provider, patchar código instalado do harness, ou alegar cobertura fora de um renderer suportado não satisfaz essa fronteira.

## Evidência de compatibilidade

[`calm.md`](calm.md#compatibilidade-com-o-pi) é dona do contrato atual de compatibilidade com o Pi.
O Pi 0.81.1 estava instalado quando o Calm foi construído pela primeira vez, e o Pi 0.82.0 foi o alvo posterior de reverificação.
O CHANGELOG inspecionado do Pi mostra nenhuma API relevante de apresentação introduzida em qualquer uma das versões, então essas versões permanecem evidência de verificação em vez de limites de compatibilidade.
As classes exportadas usadas pelos adaptadores (`AssistantMessageComponent` e `InteractiveMode`) são internals não documentados sem garantia declarada de versão.
`tests/sq-calm-pi-extension.test.sh` registra a versão instalada do Pi como evidência sem condicionar-se a ela e cobre tanto versões sintéticas mais novas quanto uma costura indisponível de adaptador.

### Restrições de override de ferramenta embutida

[`calm.md`](calm.md#compatibilidade-com-o-pi) é dona do comportamento atual de colisão visível ao usuário e sua limitação.
A inspeção do Pi 0.80.10 e 0.82.0 estabeleceu que extensões sobrescrevem uma ferramenta embutida registrando o mesmo nome, a primeira extensão registrada ganha a definição completa de `ToolDefinition` sem merge, e o Pi expõe nenhuma operação de unregister.
O Pi carrega extensões locais ao projeto antes das extensões globais ou configuradas via CLI, então a extensão Calm rastreada do Squad anteriormente ganhava aquelas colisões mesmo quando sua preferência persistida estava desligada.
As funções de execução e render da definição perdedora são ambas descartadas, então registrar incondicionalmente os wrappers do Calm substituiria a ferramenta homônima de outra extensão em vez de mudar apenas a apresentação.

O `getAllTools()` do Pi expõe metadados de ferramenta e identidade de fonte mas não as funções executáveis ou de renderização necessárias para envolver a definição completa de outra extensão.
Ele também só é utilizável para detecção confiável de colisão depois do binding de extensões, o que o torna adequado à primeira ativação de `/calm` na mesma sessão mas não ao carregamento síncrono de extensão.
Adiar o registro para `session_start` não é caminho equivalente: o Pi constrói linhas de ferramenta restauradas a partir de um snapshot anterior do registro de ferramentas durante reload, nova sessão, fork e troca de sessão, então essas linhas retêm a definição capturada antes do `session_start`.
`tests/sq-calm-pi-extension.test.sh` cobre o contrato dividido resultante: nenhum claim no load-time com o Calm desligado, claims síncronos quando já está ligado, primeira ativação conferida contra colisões com um warning, preservação da execução de uma ferramenta contestada, e o limite não-retroativo para linhas renderizadas antes da primeira ativação.

## Reprodução end-to-end no Pi 0.81.1

A versão do Pi instalada na época foi verificada em 2026-07-22.

```text
$ pi --version
0.81.1
```

### Limpeza de transcript original

A reprodução pré-limpeza usou uma TUI real isolada do Pi a 180 colunas por 44 linhas com as extensões rastreadas Calm e sentinela, um `SQUAD_BASE` isolado, e um ciclo de sentinela vivo de propriedade da base.
O modelo chamou `sq_watch_arm_pi`, a ferramenta real devolveu `sentry: started Pi extension arm child 1`, e uma escrita de status `done:` fez a extensão de sentinela injetar `SQUAD WATCHER WAKE: signal: ...` seguida da instrução estável de drain.
Com o Calm desligado, o transcript capturado continha o prompt genuíno do usuário, a casca completa da ferramenta sentinela, o acordo sintético de papel usuário, quatro rótulos colapsados `Thinking...`, linhas de ferramentas embutidas do tratamento do acordo, e a resposta final do assistente.
Com o modo Calm da implementação pré-limpeza ligado, as sete linhas existentes de ferramentas embutidas desapareceram, mas a casca da ferramenta sentinela, o acordo sintético, e todos os quatro rótulos `Thinking...` permaneceram.
A regressão final em escala de screenshot reproduziu o mesmo transcript depois da limpeza e verificou que o Calm removeu aquelas linhas controladas restantes mantendo o prompt genuíno, um prompt genuíno quase-acerto em formato sentinela, e as respostas genuínas do assistente.

O caminho original de comparação provada foi uma ferramenta de texto embutida.
O Calm era dono dos dois slots suportados de renderer daquela ferramenta e trocou a casca dela para `renderShell: "self"`, então retornar componentes vazios removeu a linha completa e `setToolsExpanded` redesenhou componentes existentes de ferramenta.
Adicionar slots vazios suportados de renderer a uma cópia scratch de `sq_watch_arm_pi` igualmente removeu a linha dele enquanto a sentinela real ainda iniciava e o modelo ainda devolvia `PROBE_COMPLETE`.
Entradas legadas de apresentação sintética usam `CustomEntryComponent`, cujo host adiciona espaçamento apenas quando seu renderer retorna conteúdo, então um resultado undefined do renderer Calm remove a linha completa e pode depois restaurá-la pelo redraw ordinário de expansão.
A evidência posterior de turno duplicado abaixo torna obsoleta a rerotação de custom-message como implementação aceitável para input operacional atual.

### Regressão de altura de bloco oculto

A reprodução alinhada-ao-usuário-final de 2026-07-23 usou a TUI instalada do Pi 0.81.1 a 100 colunas por 44 linhas, projeto e `SQUAD_BASE` isolados, o caminho real do comando `/skill:reporting`, e um provider determinístico que produziu cinco chamadas read portadoras de thinking, cinco resultados de ferramenta, thinking final oculto, e uma resposta final visível.
Com o Calm ligado e a exibição de thinking do Pi colapsada, o turno completado deixou 14 linhas vazias entre a linha visível de conteúdo `[skill] reporting` colapsada e a primeira linha final do assistente.
Com o Calm desligado, a mesma sequência renderizou todos os seis rótulos `Thinking...` e todas as cinco linhas read em vez de um campo vazio.
Uma baseline controlada contendo apenas a linha de skill e a resposta final tinha dois separadores padrão de linhas visíveis.
Adicionar um bloco final de thinking aumentou aquele vão de duas para quatro linhas, enquanto adicionar uma chamada de ferramenta sem resultado, ou uma chamada de ferramenta completada com resultado, manteve-o em duas.
Remover apenas os seis blocos thinking da sessão persistida falha deixou todas as cinco chamadas e resultados de ferramenta intactos e reduziu o vão de 14 linhas para a baseline de duas.
Habilitar o `terminal.clearOnShrink` do Pi na sessão falha inalterada manteve o vão em 14 linhas, o que descarta alocação obsoleta de terminal como causa.

O gatilho iniciante era um bloco thinking não vazio numa mensagem de assistente que o Pi renderizava através de `AssistantMessageComponent`.
A condição de exposição era a combinação do Calm ativo com a exibição de thinking do Pi colapsada, porque o Calm substituía o rótulo visível por string vazia enquanto Calm desligado ou expansão explícita de thinking preenchia aquelas linhas com conteúdo visível.
O sintoma visível era o grande campo vertical vazio entre a linha colapsada de skill intencionalmente visível e a resposta final do assistente.

O caminho divergente mais antigo de layout era `AssistantMessageComponent.updateContent`, antes da renderização diferencial de terminal ou composição de resultado de ferramenta.
O Pi computava `hasVisibleContent` dos dados originais de thinking e adicionava um `Spacer` inicial antes de aplicar a apresentação de thinking oculto.
O Pi então estilizava o rótulo vazio antes de construir `Text`, então a string resultante apenas-ANSI ocupava uma linha renderizada, e um bloco thinking seguido de texto de assistente também adicionava seu spacer ordinário inter-blocos.
Cada turno somente-thinking portanto retinha duas linhas vazias, enquanto o turno final thinking-mais-texto retinha duas linhas extras além do separador inicial normal da resposta final.
O caminho provado de ferramenta divergia através de `ToolExecutionComponent`, onde a casca self-render do Calm devolvia zero linhas tanto para os slots de chamada quanto de resultado e não contribuía com altura residual.

O menor contrafactual foi a remoção somente-thinking da mesma sessão persistida, que preservou skill, ferramentas, resultados, resposta final, ordenação da sessão e configurações de terminal enquanto eliminava cada linha indesejada.
Os controles de thinking único, somente-chamada-de-ferramenta, resultado-de-ferramenta, Calm-desligado e `clearOnShrink` deliberadamente buscaram evidência desconfirmante e isolaram layout de thinking colapsado dos candidatos skill, ferramenta, resultado e cache de terminal.
O PR 927 tornou o Calm persistente e descreveu linhas controladas como sem lacunas mantendo uma fronteira documentada não suportada para espaçamento de thinking colapsado.
O PR 936 removeu a rerotação insegura de input operacional e preservou entradas legadas de altura zero mas não mudou o layout de mensagens de assistente.

O fix instala um adaptador idempotente de apresentação, verificado no Pi 0.81.1 até 0.82.0, sobre o método exportado `AssistantMessageComponent.updateContent`.
O adaptador sonda por aquele método exato e, conforme o [contrato de compatibilidade](calm.md#compatibilidade-com-o-pi), degrada independentemente com um diagnóstico em vez de condicionar-se a um número de versão.
Apenas enquanto o Calm está ativo e o Pi tem thinking colapsado, o adaptador passa uma cópia rasa de apresentação livre de thinking ao cálculo ordinário de layout do Pi, depois retém a mensagem original no componente para invalidação e expansão de thinking.
A mensagem persistida do assistente, contexto do provider, execução de ferramentas, dados de export e histórico de expansão permanecem inalterados.
Mensagens de assistente somente-thinking colapsadas agora renderizam zero linhas, thinking antes de texto visível de assistente não adiciona espaçamento além da baseline só-texto, e expandir o thinking ainda renderiza o raciocínio original.

As checagens desconfirmantes deliberadamente retêm fronteiras suportadas.
Uma ferramenta custom arbitrária de terceiros e um read embutido de imagem permanecem visíveis porque o Pi expõe nem um renderer global de ferramentas nem controle de linhas de imagem.
Thinking expandido permanece visível por design, enquanto re-colapsá-lo retorna à apresentação de altura zero do Calm.
Quase-acertos ordinários de papel usuário permanecem visíveis, incluindo marcadores atuais citados, rótulos apenas-ASCII, texto não relacionado antes de um marcador, texto não relacionado depois de U+2063, e input portador de imagem.

## Regressão de turno duplicado e fronteira semântica

A regressão visível ao comandante reproduziu três vezes consecutivas numa sessão Pi persistida sob `~/.pi/agent/sessions/`.
O assistente `bb83873b` foi seguido pelo input custom oculto `9d087b52` e pelo assistente distinto duplicado `f4232aa3`.
O assistente `3a388d8c` foi seguido pelos inputs custom ocultos adjacentes `e1914f28` e `cfdefb09` e pelo assistente distinto duplicado `47c81eeb`.
Identificadores distintos de resposta do provider e assinaturas provam turnos separados do modelo em vez de pintura duplicada da TUI.

O gatilho iniciante era `pi.sendUserMessage(..., { deliverAs: "followUp" })` da sentinela ou do adaptador turn-end depois de uma resposta voltada ao comandante.
A condição de exposição era o handler `input` carregado do Calm do commit `6db3b09`, que rodava tanto com o toggle persistido ligado quanto desligado, devolvia `handled`, substituía a mensagem do usuário por `pi.sendMessage`, e disparava um turno aninhado de custom-message.
O sintoma visível era uma segunda linha de assistente repetindo a resposta anterior ao comandante.
A divergência persistida mais antiga era o tipo de entrada operacional: Calm carregado produzia `custom_message` com role `custom` antes da conversão do provider, enquanto Calm ausente produzia uma `message` normal com role `user`.
A divergência de ciclo de vida mais antiga era que o caminho de substituição contornava o processamento normal de prompt de usuário do Pi depois do evento `input`.

Uma reprodução determinística nativa da TUI do Pi no PR 927 landado produziu `COMMANDER_VISIBLE_ANSWER` duas vezes com Calm carregado e explicitamente ligado, e produziu a mesma duplicata com Calm carregado e explicitamente desligado.
A mesma notificação tipada exata com Calm ausente produziu uma resposta ao comandante seguida de `MONITOR_NOTIFICATION_HANDLED`.
Remover apenas a rerotação de input de uma cópia scratch mantendo o Calm carregado e ligado produziu o mesmo resultado provado e restaurou a entrada operacional ao role `user`.
Esse é o menor contrafactual e prova que o carregamento da extensão, não o toggle ativo, era a condição exigida de exposição.
O caminho de sucesso sem-extensão é evidência contra uma causa independente de turno-duplicado no núcleo do Pi para a mesma sequência, mas não afirma que o núcleo do Pi nunca pudesse conter um bug separado de duplicação.

O PR 936 removeu o handler semântico de input do Calm e o caminho de entrega de custom-message porque o Pi 0.81.1 não expõe nenhum renderer suportado de usuário-ordinário e aquela substituição duplicava turnos do modelo.
Essa correção preservou input operacional atual como mensagem exata ordinária de papel usuário com sua ordenação e autoridade inalteradas, mas deliberadamente deixou a linha visível até que uma fronteira only-presentation fosse provada.
Entradas legadas `Squad-synthetic-input-presentation` permaneceram renderizáveis para que sessões existentes preservassem a apresentação armazenada e o comportamento de linha oculta de altura-zero delas.

## Regressão de altura zero da linha operacional de usuário

A reprodução alinhada-ao-usuário-final de 2026-07-23 usou a TUI instalada do Pi 0.81.1 a 160 colunas por 36 linhas, a extensão Calm rastreada persistida ligada, diretórios isolados de home e sessão, e um provider determinístico in-process.
A mensagem injetada de usuário começava com U+2063 exato mais `SQUAD_OP:` e carregava o caminho de status da sentinela tirado do screenshot durável do comandante seguido da linha em branco e instrução estável de drain.
Os bytes exatos de U+2063, ambas as linhas do payload, papel usuário e ordenação sobreviveram à entrega ao vivo e ao restart do processo.
O provider observou uma mensagem de usuário correspondente, devolveu `OPERATIONAL_PROCESSED occurrences=1`, e a sessão continha uma entrada correspondente de usuário e uma correspondente de assistente.

O viewport falho renderizava o input operacional como uma caixa de usuário de cinco células de altura nas linhas 1 a 5 e colocava o texto do assistente na linha 7 após o separador normal de assistente do Pi.
A mesma sessão persistida reproduziu aquelas coordenadas depois de restart.
Calm desligado renderizava a mesma geometria de componente de usuário, provando que o toggle ativo não tinha efeito de apresentação neste caminho.
O gatilho iniciante era a mensagem exata gerada pela sentinela.
A condição de exposição era o caminho seguro de entrega de usuário-ordinário do PR 936 combinado com a ausência de um adaptador de apresentação de linha-de-usuário, não perda de marcador, drift de fonte-de-evento, classificação falha, persistência, replay ou entrega duplicada.
O sintoma visível era a caixa sintética completa de duas linhas e suas cinco linhas de altura de terminal.

A divergência mais antiga significativa de layout em relação às entradas provadas de apresentação oculta era `InteractiveMode.addMessageToChat`.
Seu branch de usuário-ordinário adicionava um `Spacer` inicial quando aplicável e depois um `UserMessageComponent`, cujo `Box` contribui padding vertical ao redor das três linhas Markdown.
O caminho legado de custom-entry em vez disso confere conteúdo do renderer antes de montar um filho de transcript, e o fix completado de assistant-thinking remove thinking oculto antes do layout do assistente.
Esses comportamentos têm donos diferentes e permanecem separados.

O menor contrafactual retornava apenas do branch ordinary-user do dono do transcript para aquele input exato de sentinela.
O viewport real do Pi moveu o texto inalterado do assistente da linha 7 para a linha 2, não renderizou texto operacional, e mesmo assim persistiu uma entrada exata de usuário e uma exata de resposta.
A causa principal teria sido falsificada se a linha ou altura permanecesse, o provider perdesse ou duplicasse a mensagem, ou o papel persistido ou bytes mudassem.
Nada ocorreu.

O fix instala um adaptador idempotente separado de apresentação, verificado no Pi 0.81.1 até 0.82.0, sobre o método exportado `InteractiveMode.addMessageToChat`.
O adaptador sonda por aquele método exato e, conforme o [contrato de compatibilidade](calm.md#compatibilidade-com-o-pi), degrada independentemente com um diagnóstico em vez de condicionar-se a um número de versão.
Ele delega reconhecimento atual ao `bin/sq-operational-input.sh`, adiciona apenas a forma de compatibilidade de apresentação respaldada-evidência de `Supervisor escalate (` com U+2063 puro, monta uma subclasse de `UserMessageComponent` que preserva a linha padrão do Pi mais spacer inicial enquanto o Calm está desligado, e devolve zero linhas renderizadas enquanto o Calm está ligado.
Ele nunca intercepta o evento de input, reescreve a mensagem, muda o papel dela, filtra contexto do modelo, nem muda dados da sessão.
Mensagens contendo imagem ficam no caminho ordinário do Pi mesmo quando seu texto equivale a um envelope operacional porque os produtores autoritativos do Squad são apenas-texto.

Uma execução nativa exata de sentinela e seu replay pós-restart de processo mantiveram o texto vizinho do assistente no espaçamento de duas linhas apenas-visível enquanto retinham uma entrada exata de usuário e uma resposta em processamento.
Uma execução adjacente de duas notificações reteve as mesmas coordenadas vizinhas-de-assistente de duas linhas, provando que ambos os componentes operacionais contribuíram altura zero.
Calm desligado, preferência Calm ausente, e extensão Calm ausente retinham linhas ordinárias.
O marcador exato atual e a forma estreita de compatibilidade `Supervisor escalate (` com U+2063 puro se escondiam sob o Calm, enquanto marcadores citados, `SQUAD_OP:` ASCII sem U+2063, texto ordinário antes do marcador atual, texto não relacionado depois de U+2063, e input portador de imagem permaneciam visíveis.

## Apresentação de trabalho do Calm

O Calm substitui a linha de trabalho padrão do Pi por um pequeno barco animado enquanto o Calm está ligado e uma execução lógica de agente está ativa.
Este caminho usa apenas API pública de extensão e patcha nada: `ExtensionUIContext.setWorkingVisible(false)` esconde a linha padrão, e `setWidget()` instala uma factory temporária de componente acima do editor.
Os frames documentados do Pi de indicador customizado de trabalho são estáticos e cegos à largura, então não podem ser donos de geometria responsiva; um componente widget recebe `render(width)` e pode.

`.pi/extensions/sq-calm.ts` continua sendo o único dono da escolha de apresentação e o único chamador de `setWorkingVisible()`, enquanto `.pi/extensions/lib/sq-calm-working-ship.ts` é dono da geometria do sprite, da pista de bounce e do widget.
Visibilidade segue `agent_start` até `agent_settled` em vez de turnos ou chamadas de ferramenta.
O Pi emite `agent_settled` de um bloco `finally` uma vez que uma execução não continuará automaticamente, então retries, continuações automáticas, follow-ups enfileirados e compactação dentro de uma mesma execução nunca removem o barco, enquanto settle, abort e falha alcançam a mesma limpeza.
Eventos repetidos de `agent_start` dentro de uma mesma execução são idempotentes, e o Pi dispõe o componente anterior antes de instalar um substituto sob a mesma chave e quando limpa widgets de extensões, então o timer de frames não pode duplicar nem sobreviver ao widget.
O contêiner de widgets acima-do-editor do Pi reserva uma linha de spacer haja ou não widget presente, então remover o barco não deixa linha em branco residual.

O sprite tem duas linhas quando a largura útil admite o casco completo: uma vela principal de duas células centrada sobre um casco simétrico `\__/` que substitui a água em sua linha em vez de adicionar uma terceira linha.
A vela é direcional porque uma vela principal se estende à ré do mastro, então ela renderiza `<|` quando viaja para a direita e `|>` quando viaja para a esquerda.
A direção reverte no momento em que o barco pousa num endpoint, então o frame do endpoint já mostra o novo rumo e nenhum frame em ou depois de um bounce mostra a vela anterior.
A linha de água preenche a largura completa fornecida, a pista é recomputada e limitada dessa largura a cada frame para que um resize não possa quebrar linha nem abandonar o barco fora da tela, e larguras estreitas demais para o casco recuam para uma única linha determinística.

Um scheduler comanda dois relógios logicamente independentes.
Todo tick avança uma fase de água limitada de células fixas, e apenas a cada quarto tick o barco se move, então a um tick de 220ms a água ondula várias vezes entre passos do barco e o barco viaja uma coluna a cada 880ms.
Ticks em vez de timestamps de wall-clock comandam toda mudança de estado, então testes buscam tempo de animação exatamente, e dispor o widget para ambos os relógios juntos.
Fases de água são ASCII de coluna única, então avançá-las nunca muda largura visível, adiciona linha, nem move a coluna do casco.

Cores são códigos ANSI padrão de foreground em vez de lookups de tema: azul para cada célula de água e amarelo para o barco completo, sem variante bright, 256 cores ou escape RGB.
Cada trecho colorido é fechado com um reset de foreground padrão para que o estilo não vaze no padding da linha da vela, UI vizinha, ou frame posterior, e a geometria é sempre computada de células visíveis em vez de bytes de escape.

A apresentação é exclusiva de TUI e visual.
Ela não adiciona entrada de sessão, linha de transcript, contexto do modelo, nem conteúdo de export ou share, e seu widget recebe nenhum input de teclado, então foco do editor e abort por Escape ficam inalterados.
Loaders de compactação e retry permanecem padrão porque o Pi não expõe substituto suportado para eles.

## Política central de visibilidade e input

`.pi/extensions/lib/sq-calm-visibility.ts` é dona apenas da política de apresentação de transcript estilo allowlist.
`bin/sq-operational-input.sh` é dono da construção e parsing cross-language atuais de input operacional, enquanto o adaptador fino de Pi vive em `.pi/extensions/lib/sq-operational-input.ts`.
Apenas `genuine-user-prompt`, `genuine-agent-response` e `working-status` são policy-visible.
Toda outra classe auditada é policy-hidden quando o Pi expõe fronteira suportada de apresentação, mas input semântico nunca é transformado para impor essa preferência.
O schema de persistência local à base é de propriedade de [`docs/configuration.md`](configuration.md#preferência-pi-calm-configcalm).

Inputs atuais de session-start, sentinela, turn-end guard, supervisor away e launch-brief retêm seus envelopes estáticos versionados de U+2063.
O carrier de roteamento estabelecido de `[sq-from-squad]` mais U+2063 no início permanece atual para que charters XO em execução continuem compatíveis.
Um envelope estático atual exato permanece proveniência suficiente sem nonce, autenticação de fonte, prevenção de replay, token secundário, bloqueio, redação ou maquinaria privada de recuperação.
O Calm classifica apenas no dono de apresentação de transcript do Pi através do parser canônico e nunca substitui, reordena ou enfraquece essas mensagens.

O nudge de início de sessão já se origina como mensagem custom não exibida, então permanece nesse caminho existente mantendo contexto de modelo e persistência de sessão.
Entradas e mensagens custom legadas do Calm permanecem nos artefatos existentes de sessão, e sua entrada de apresentação ainda usa o renderer suportado de altura-zero enquanto ativo.
Ciclar expansão de ferramentas e restaurar seu valor original reconstrói linhas controláveis e deixa o estado final de `Ctrl+O` inalterado.
HTML exportado e compartilhado retém prompts genuínos de usuário, respostas genuínas de assistente, mensagens atuais operacionais de usuário, renderização ordinária de ferramentas, e o artefato completo de sessão.
Dados serializados de sessão e a árvore lateral do Pi 0.81.1 também retêm mensagens custom operacionais legadas ocultas.

## Taxonomia completa atualmente alcançável do transcript do Pi

A taxonomia foi derivada das declarações públicas instaladas do Pi 0.81.1, documentação, exemplos, `interactive-mode.js`, e suas implementações exportadas de componentes.
O fixture de teste enumera cada classe abaixo através da política centralizada, e o fixture interativo exercita as classes de screenshot, input operacional atual de papel-usuário, e entradas legadas de apresentação sintética.

| Classe de política | Caminho de transcript do Pi | Resultado Calm (verificado no Pi 0.81.1 até 0.82.0) |
| --- | --- | --- |
| `genuine-user-prompt` | `UserMessageComponent` | Visível, incluindo todo quase-acerto testado de operacional. |
| `genuine-agent-response` | Texto de assistente em `AssistantMessageComponent` | Visível. |
| `assistant-thinking` | Conteúdo thinking em `AssistantMessageComponent` | Raciocínio colapsado é removido da cópia rasa de apresentação antes do layout e ocupa zero linhas; expansão explícita renderiza o raciocínio original. |
| `assistant-tool-call` | `ToolExecutionComponent` | Sete embutidas e `sq_watch_arm_pi` ocultas; ferramentas custom arbitrárias permanecem fronteira não suportada. |
| `tool-result` | `ToolExecutionComponent` | Resultados de texto para as ferramentas controladas ocultos; resultados custom arbitrários permanecem fronteira não suportada. |
| `tool-image` | Filhos de imagem anexados fora dos slots de renderer de ferramenta | Fronteira não suportada; permanece visível. |
| `user-bash` | `BashExecutionComponent` para `!` e `!!` | Fronteira não suportada; permanece visível. |
| `skill-invocation` | `SkillInvocationMessageComponent` mais texto parseado de usuário | Fronteira não suportada; permanece visível. |
| `custom-message` | `CustomMessageComponent` quando `display` é true | O nudge de início de sessão e mensagens legadas de contexto Calm usam `display: false`; mensagens arbitrárias de extensão permanecem fronteira não suportada. |
| `custom-entry` | `CustomEntryComponent` com renderer registrado | Entradas legadas de apresentação Calm reconstroem para zero filhos sem spacer residual e restauram por redraw ordinário de expansão quando montadas; entradas arbitrárias de extensão permanecem fronteira não suportada. |
| `compaction-summary` | `CompactionSummaryMessageComponent` | Fronteira não suportada; permanece visível. |
| `branch-summary` | `BranchSummaryMessageComponent` | Fronteira não suportada; permanece visível. |
| `working-status` | `WorkingStatusIndicator`, ou o widget barco-de-trabalho do Calm enquanto o Calm está ativo | Sempre visível. Calm desligado deixa a linha padrão do Pi intacta; Calm ligado esconde aquela linha pela duração de uma execução lógica de agente e renderiza o barco de trabalho em vez dela. |
| `command-status` | Linhas de resultado e status de comando interativo | O Calm emite nenhum aviso de habilitação, mas linhas genéricas de comando do Pi permanecem fronteira não suportada. |
| `system-notice` | `showStatus`, `showError`, linhas de compactação, retry e warning de startup | Fronteira não suportada; permanece visível. |
| `cache-notice` | Linha `Text` não persistida de cache-miss | Fronteira não suportada; permanece visível. |
| `project-trust-warning` | Linha `Text` não persistida de startup | Fronteira não suportada; permanece visível. |
| `synthetic-user` | `sendUserMessage` de extensão do Squad, input injetado pelo terminal, brief posicional gerado pelo Squad para o Pi, ou o nudge de início de sessão já não-exibido | Mensagens textuais operacionais canonicamente classificadas de usuário continuam mensagens semânticas ordinárias de usuário mas renderizam pelo adaptador de altura-zero (verificado no Pi 0.81.1 até 0.82.0) sob Calm; entradas legadas continuam controláveis sem lacunas, e o nudge de início de sessão mantém seu caminho existente de custom-message não exibida. |
| `synthetic-assistant` | Nenhuma fonte autoritativa do Squad encontrada | Policy-hidden, mas o Pi expõe nenhum renderer genérico de papel-assistente. |
| `unknown` | Componente futuro ou não classificado de transcript | Policy-hidden, mas nenhum renderer genérico existe; nunca alegado como coberto. |

A API instalada de extensão não tem filtro global suportado de transcript, renderer de mensagem de usuário, renderer de mensagem de assistente, API de contêiner de chat, ou wrapper genérico de ferramenta custom.
Pi 0.81.1 até 0.82.0 exportam `AssistantMessageComponent` e `InteractiveMode`, então o Calm usa adaptadores separados idempotentes sondados-via-API para layout de thinking de assistente e para a linha completa operacional-de-usuário do transcript deixando todos os dados de mensagem e renderização não-Calm inalterados; veja o [contrato de compatibilidade](calm.md#compatibilidade-com-o-pi) para como um Pi futuro carente de uma dessas exportações é tratado.
Substituição geral de componente, apagamento de cursor ANSI, mutação de contexto do provider, e patching de arquivo instalado permanecem rejeitados como workarounds não suportados ou que quebram preservação.

## Registro de verificação cross-harness

A inspeção original dos cinco harnesses foi feita em 2026-07-22, com toda superfície de integração reconferida e o Pi reverificado na 0.81.1 em 2026-07-23 para a mudança mais recente de apresentação Calm.

```text
$ claude --version
2.1.218 (Claude Code)
$ codex --version
codex-cli 0.144.6
$ opencode --version
1.17.18
$ pi --version
0.81.1
$ grok --version
grok 0.2.106 (bde89716f679)
```

| Harness | Conclusão | Evidência |
| --- | --- | --- |
| Claude Code 2.1.218 | Não viável pela superfície de projeto suportada inspecionada. | Hooks de projeto observam eventos de ciclo de vida e ferramenta, enquanto os pacotes CLI de plugin suportam componentes; nenhuma superfície inspecionada expõe renderer de linha de transcript ou API de redraw amplo de transcript. |
| Codex CLI 0.144.6 | Não viável pela superfície de projeto suportada inspecionada. | Os hooks rastreados expõem tratamento de sessão, pre-tool e stop, enquanto os inventários de plugin e feature não expõem renderer de linha de ferramenta na TUI nem controle de redraw de transcript. |
| OpenCode 1.17.18 | Não viável sem violar a fronteira de preservação. | Plugins expõem eventos e hooks de execução de ferramenta, não um renderer embutido de linha de transcript; substituição de ferramenta homônima muda execução em vez de apenas apresentação. |
| Pi (verificado 0.81.1 até 0.82.0) | Parcialmente viável com dois adaptadores sondados-via-API de classes exportadas. | APIs públicas controlam visibilidade de trabalho, rótulos colapsados, slots conhecidos de ferramenta, entradas custom e redraws de expansão; as classes exportadas de assistente e interactive-mode fornecem as fronteiras de layout de thinking-colapsado e operacional-de-usuário, condicionadas à presença do método exato em vez de número de versão, enquanto filtragem genérica de usuário, ferramenta e status permanece indisponível. |
| Grok CLI 0.2.106 | Não viável pela superfície de projeto suportada inspecionada. | Hooks de projeto expõem interceptação de ciclo de vida e ferramenta, enquanto a CLI de plugin não expõe contrato de row-renderer; `--minimal` muda o modo inteiro de tela em vez de linhas selecionadas de transcript. |

Estas conclusões são deliberadamente limitadas às versões nomeadas e superfícies suportadas.
Elas não afirmam que um harness nunca possa adicionar a API de renderer faltante.
Para o fix de turno-duplicado e a mudança de apresentação mais recente, os templates de lançamento de Claude, Codex, OpenCode, Pi e Grok e os produtores de sentinela, turn-end, session-start, away-supervisor e from-squad foram reinspecionados.
O encoder canônico e todo caminho de entrega não-Pi permanecem inalterados, e as superfícies de runtime tmux, Herdr, Zellij, Orca e cmux continuam transportando o mesmo input selecionado pelo adaptador de harness.
Apenas a implementação de apresentação Calm do Pi mudou; todo produtor e transporte não-Pi permanecem inalterados.

## Cobertura de regressão

`tests/sq-calm-pi-extension.test.sh` compara renderers wrapped e padrão, verifica todos os sete embutidos mais `sq_watch_arm_pi`, exercita redraw de linhas já renderizadas de ferramenta, thinking, operacional-de-usuário atual e sintética legada, e cobre toda classe de política.
Ele cobre restauração de preferência persistida por toda razão de início de sessão e um restart real, prova a apresentação do barco de trabalho e a linha padrão `Working...` com Calm desligado através de um provider determinístico com atraso, afirma nenhuma linha de status Calm, verifica que mensagens operacionais permanecem entradas exatas ordinárias de papel-usuário na sessão e exports completos, e conduz fixtures reais de terminal de 100 por 44, 160 por 36 e 180 por 44.
Um turno nativo determinístico de `/skill:reporting` produz blocos de thinking, tool-call e tool-result, afirma que o vão colapsado skill-até-final equivale à baseline de duas linhas apenas-visíveis, expande e re-colapsa o thinking original, restaura renderização com Calm desligado, verifica histórico persistido oculto, e repete a asserção de geometria depois de restart com `terminal.clearOnShrink` explicitamente desligado.
O caminho de provider operacional cobre Calm carregado ligado, carregado desligado, preferência padrão, extensão ausente, entrega exata de sentinela, input legado estreito de bare-marker, replay persistido pós-restart, um prompt genuíno do comandante, e notificações adjacentes coalescidas num único turno pretendido de processamento.
Ele afirma uma resposta persistida e renderizada ao comandante, envelopes exatos operacionais de papel-usuário em ordem, nenhuma mensagem custom substituta, um resultado de processamento, zero linhas operacionais de transcript, e a geometria vizinha-de-assistente de duas linhas para caminhos ao vivo, adjacentes e pós-restart.
Marcadores atuais citados, rótulos apenas-ASCII, texto ordinário antes de marcador, posicionamento não relacionado de U+2063, e input portador de imagem permanecem visíveis nas checagens de componente e transcript nativo.
`tests/sq-pi-primary-live-e2e.test.sh` também prova que o barco de trabalho substitui a linha embutida `Working...` enquanto o Calm está ativo no caminho credenciado de provider, e que ele se limpa quando a execução se estabiliza, antes de continuar seu ciclo de vida ordinário de sentinela.
`tests/sq-pi-primary-types.test.sh` faz checagem TypeScript estrita no-emit contra as declarações instaladas do Pi, atualmente package versão 0.81.1.

Os comandos relevantes são:

```sh
tests/sq-calm-pi-extension.test.sh
SQUAD_PI_LIVE_E2E=1 tests/sq-pi-primary-live-e2e.test.sh
tests/sq-pi-primary-types.test.sh
```

## Registro de verificação 2026-07-23

O provider determinístico preserva o caminho completo real de renderização da TUI do Pi sem usar credenciais.
A regressão ao vivo credenciada permanece opt-in e não foi exigida porque esta mudança não altera entrega da sentinela nem integração com providers.

```text
$ pi --version
0.81.1

$ tests/sq-calm-pi-extension.test.sh
ok - Pi calm extension is presentation-only with one persisted visibility choice, no Calm status row, native working visibility, supported redraw controls, and the Squad sentry-tool integration
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps native working visible, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:reporting geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi calm native E2E keeps Working and commander turns visible, hides exact operational user rows without changing persistence, restores them Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/sq-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/sq-lint.sh
sq-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/sq-test-run.sh --changed --base origin/main
SQUAD_TEST_SUMMARY total=38 failed=0 skipped_gate=7 duration_ms=166881
SQUAD_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=192 failed=0
SQUAD_TEST_SUMMARY_FAMILY family=pure-contract-unit count=31 duration_ms=165384 failed=0

$ tests/sq-pi-primary-live-e2e.test.sh
skip: set SQUAD_PI_LIVE_E2E=1 to run the isolated interactive Pi regression
```

## Verificação de compatibilidade Pi 0.82.0, 2026-07-26

O Pi 0.82.0 preservou ambas as costuras de apresentação sondadas-via-API e toda garantia determinística da TUI Calm.
O package globalmente instalado de declarações permaneceu 0.81.1, então o typecheck estrito continuou cobrindo aquela versão anterior de evidência-declaração enquanto a CLI real exercitava 0.82.0.

```text
$ pi --version
0.82.0

$ tests/sq-calm-pi-extension.test.sh
ok - Pi calm extension is presentation-only with one persisted visibility choice, no Calm status row, native working visibility, supported redraw controls, and the Squad sentry-tool integration
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps native working visible, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:reporting geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi calm native E2E keeps Working and commander turns visible, hides exact operational user rows without changing persistence, restores them Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/sq-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1
```

## Verificação da apresentação de trabalho do Calm, 2026-07-30 (obsoleta)

Este registro captura a primeira implementação da apresentação de trabalho e é mantido como histórico de pipeline.
Sua vela de mesma orientação, cores derivadas do tema e movimento de cadência única foram todos substituídos no mesmo dia; o registro de revisão ao final deste documento é dono do comportamento atual.

O barco de trabalho foi verificado contra a CLI instalada do Pi 0.82.0 com um provider determinístico in-process e nenhuma credencial.
O package globalmente instalado de declarações permaneceu 0.81.1, então o typecheck estrito continuou cobrindo aquela versão de evidência-declaração enquanto a CLI real exercitava 0.82.0.
A regressão real-TUI captura dois frames em colunas diferentes de casco, faz resize da mesma TUI rodando, afirma que a linha de água refluiu para a nova largura em uma única linha de ondas, digita no editor enquanto a animação roda, aborta com Escape, e depois prova que a linha padrão `Working...` do Pi volta com o Calm desligado.

```text
$ pi --version
0.82.0

$ tests/sq-calm-pi-extension.test.sh
ok - Pi calm resolves its persistent home independently of Pi's launch directory
ok - Pi calm compatibility evidence never rejects a Pi version for being newer than 0.82.0, and still fails closed on a missing or malformed version
ok - a missing collapsed-thinking presentation API degrades only that Calm adapter with a clear skip reason, while the rest of Calm still registers
ok - missing Pi presentation class exports reach the independent adapter degradation path
ok - Pi calm centralizes transcript visibility, preserves execution/export data, keeps Pi's stock working row visible while no run is active, and persists its choice across session starts
ok - Pi operational follow-up E2E processes exact user-role notifications once while Calm hides current and adjacent rows, Calm off and absent render them, and restart preserves semantics
ok - Pi Calm native /skill:reporting geometry keeps every collapsed thinking and tool block at zero height while preserving expansion, history, restart, and Calm-off rendering
ok - Pi Calm working ship renders an exact two-row full-width sprite, clamps every resize, bounces at both edges, falls back deterministically when narrow, and installs and removes one timer-owning widget across starts, settle, abort, failure, shutdown, reload, replacement, and Calm toggles
ok - Pi calm native E2E replaces the stock working row with a moving, resize-clamped working ship that clears on abort, keeps commander turns visible, hides exact operational user rows without changing persistence, restores stock rendering Calm-off, survives restart, and preserves export plus Ctrl+O behavior

$ tests/sq-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/sq-lint.sh
sq-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/sq-doc-audience-check.sh
sq-doc-audience-check: ok surfaces=57 local_links=160

$ bin/sq-test-run.sh --changed --base origin/main
SQUAD_TEST_SUMMARY total=32 failed=0 skipped_gate=7 duration_ms=196009
SQUAD_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=202 failed=0
SQUAD_TEST_SUMMARY_FAMILY family=pure-contract-unit count=25 duration_ms=194670 failed=0
```

Um frame renderizado a 120 colunas, com a linha de trabalho padrão do Pi oculta e o barco diretamente acima do editor:

```text
 |>
\__/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

A mesma execução depois de fazer resize daquela TUI para 64 colunas, mostrando as ondas reenchidas à nova largura em uma linha com o barco ainda na tela:

```text
                         |>
~~~~~~~~~~~~~~~~~~~~~~~~\__/~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
```

As cores naquela época foram confirmadas de uma captura preservadora de escapes como entradas derivadas do tema; a revisão abaixo as substituiu por azul e amarelo ANSI padrão.
Pressionar Escape durante uma execução deixou `Operation aborted` sem barco e sem linha em branco residual, e desligar o Calm restaurou a linha padrão `⠴ Working...` do Pi na próxima execução.

## Verificação da revisão da apresentação de trabalho do Calm, 2026-07-30

A revisão substituiu o sprite de cadência única, cores de tema e mesma orientação por um barco mais lento sobre água animada independentemente, cores ANSI padrão, e uma vela principal direcional.
Foi verificado contra a CLI instalada do Pi 0.82.0 com um provider determinístico in-process e nenhuma credencial.

```text
$ pi --version
0.82.0

$ tests/sq-pi-primary-types.test.sh
ok - tracked Pi extensions pass strict no-emit typecheck against Pi 0.81.1

$ bin/sq-lint.sh
sq-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

$ bin/sq-doc-audience-check.sh
sq-doc-audience-check: ok surfaces=57 local_links=163

$ bin/sq-test-run.sh --changed --base origin/main
SQUAD_TEST_SUMMARY total=32 failed=0 skipped_gate=7 duration_ms=386738
SQUAD_TEST_SUMMARY_FAMILY family=live-harness-optin count=7 duration_ms=257 failed=0
SQUAD_TEST_SUMMARY_FAMILY family=pure-contract-unit count=25 duration_ms=383010 failed=0
```

Observações reais da TUI do Pi da tentativa determinística isolada a 100 colunas.
A coluna do casco ficou estável entre amostras consecutivas enquanto o padrão da água mudava, depois avançou cerca de uma coluna a cada 880ms, o que separa as duas cadências:

```text
hull_col=12  water=~-~~~-~~~-~\__/~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~
hull_col=12  water=~~~-~~~-~~~\__/-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-
hull_col=13  water=~~-~~~-~~~-~\__/~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~~~-~
hull_col=16  (about 2.6s later)
```

Uma captura preservadora de escapes confirmou apenas códigos ANSI padrão de foreground, água azul e barco amarelo, com um reset de foreground padrão fechando cada trecho:

```text
^[[34m~~~-~~~-~~~-~~~^[[33m\__/^[[34m-~~~-~~~-~~~-~~~-...
^[[33m<|^[[39m
```

Fazer resize da mesma TUI rodando para 12 colunas encurtou a pista o suficiente para observar ambas as reversões, cada uma já mostrando o rumo que estava prestes a viajar:

```text
left-heading :          |>  over  ~-~~~-~~\__/
right-heading:  <|          over  \__/~~-~~~-~
```

A 3 colunas o sprite recuou para uma única linha de largura exata, `<|~`.
Escape abortou a execução deixando `Operation aborted`, sem barco e sem linhas obsoletas de sprite, e a tentativa saiu 0 depois de deletar seu estado temporário.
