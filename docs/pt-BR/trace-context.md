<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Propagação nativa de trace-context W3C

O Squad pode propagar um [`traceparent`](https://www.w3.org/TR/trace-context/) W3C para todo agente que ele spawnar para que um observador externo identifique cada tarefa como exatamente um trace e correlacione tudo o que aquela tarefa executa sob aquela única identidade.
A fronteira de trace é a tarefa: um XO persistente é infraestrutura de roteamento com sua própria identidade de agente, nunca uma raiz de trace compartilhada para as tarefas não relacionadas roteadas por ele.
A capacidade é default-off, source-owned, vendor-neutral e deliberadamente estreita.
Este documento é o guia de racional e comportamento atual; `docs/configuration.md` é dona do schema de configuração, o cabeçalho de `bin/sq-trace-context-lib.sh` é dono da mecânica exata, e [`verification/trace-context.md`](../verification/trace-context.md) registra a evidência repetível de teste.

## Por que isso é uma mudança de fonte

Os artefatos operacionais duráveis do Squad já permitem que um observador downstream derive identidade lógica de tarefa e ciclo de vida.
A capacidade de fonte que um observador não consegue reconstruir depois do lançamento é um id de trace com escopo de tarefa entregue no ambiente do agente antes do lançamento e registrado sob a mesma identidade nos metadados da tarefa.
Esta feature adiciona apenas essa costura de transporte.

## O que faz

Quando habilitada, para cada spawn o Squad resolve um carrier `traceparent` W3C para a tarefa - cunhado como raiz fresca no primeiro spawn da tarefa e reutilizado verbatim do meta no relançamento - e:

- forma-o como `00-<32 hex trace id>-<16 hex span id>-<2 hex flags>`, com ids aleatórios para uma nova raiz;
- injeta-o no shell do pane do agente como a variável de ambiente `TRACEPARENT` imediatamente antes do lançamento, pelo mesmo canal `spawn_send_text_line` que já entrega `GOTMPDIR`; e
- registra o valor idêntico como `traceparent=` em `state/<id>.meta`.

`TRACEPARENT` como variável de ambiente é uma convenção do Squad carregando um valor formatado em W3C: o padrão W3C Trace Context padroniza o header HTTP `traceparent`, não uma env var, e os SDKs do OpenTelemetry não a leem do ambiente automaticamente, então um observador downstream precisa ler explicitamente esse valor de ambiente ou o campo meta `traceparent=`.
Esta feature não cria nenhum span de SDK por si só.

Como o carrier injetado e o carrier registrado são a mesma string, um observador que lê os metadados reconstrói exatamente a identidade que o filho recebeu.
A injeção fica no site incondicional de export pré-lançamento, então cobre spawns ship e recon através de `claude`, `codex`, `opencode`, `pi`, `pi-signed`, `grok`, `kimi` e `muse`, mais spawns XO através desse mesmo conjunto exceto o adaptador `muse` deliberadamente exclusivo de operadores.
Essa é a mesma cobertura que `GOTMPDIR` já tem e não exige comportamento específico de trace em `launch_template()`.
Spawns ship e recon alcançam aquele site em todos os backends de spawn (`tmux`, `herdr`, `zellij`, `orca`, `cmux`); um XO alcança em todos os backends que aceitam spawn de XO (`tmux`, `herdr`, `zellij`), porque `bin/sq-spawn.sh` rejeita um XO em `orca` e `cmux`.

### Rotas remotas de XO

Um XO numa [rota remota](remote-XOs.md) nunca alcança aquele site de exportação no processo próprio do pai: o pai entrega o lançamento ao host configurado, que roda seu próprio `bin/sq-spawn.sh` lá.
A identidade ainda é a do pai, porque a base pai detém os metadados da tarefa que um observador lê.
O pai portanto resolve o carrier contra os próprios metadados daquela tarefa sob sua própria decisão congelada - reutilizado verbatim no relançamento, cunhado fresco caso contrário, nunca adotando o `TRACEPARENT` ambiente do processo pai - e passa-o ao host remoto, que o exporta no mesmo site incondicional pré-lançamento e devolve o carrier que seu endpoint realmente detém.
O pai registra esse valor devolvido, então um endpoint remoto já vivo que não foi relançado reporta a identidade que seu agente realmente recebeu em vez de uma que o pai meramente pretendia.
O host remoto valida o carrier entregue como valor W3C estrito antes que possa alcançar qualquer pane, e um pai desabilitado não passa nada, deixando o lançamento remoto idêntico ao sem trace.
Se o endpoint já está vivo, nenhum novo lançamento ou injeção ocorre; o pai mesmo assim registra qualquer carrier que o endpoint reporte, mesmo quando a decisão atual do pai é `off`, para que seus metadados não neguem a identidade real do agente em execução.
A decisão de habilitação viaja com ela exatamente como no caminho local: a base remota herda `config/trace-context` como material herdado declarado e o novo processo XO recebe o snapshot congelado `SQUAD_TRACE_CONTEXT=on|off` do pai.

## Semântica de raiz e recuperação

O objetivo dessas regras é um trace por tarefa: nunca mesclar tarefas não relacionadas, e nunca cunhar uma segunda identidade para a mesma tarefa.

- **Raiz** - um spawn cujo meta da tarefa não contém carrier registrado válido cunha um trace id fresco, um span id fresco e flags sampled (`01`).
  Isso inicia um novo trace, um por tarefa.
  O `TRACEPARENT` ambiente do próprio processo que spawna nunca é adotado: aquele valor é a identidade de agente que o próprio processo recebeu no lançamento dele, e um XO persistente o mantém por toda a vida enquanto requests não relacionados são roteados por ele.
  Adotá-lo encadearia toda tarefa roteada num único trace sempre crescente por XO; em vez disso cada tarefa roteada enraíza o próprio trace dela.
- **Recuperação** - um `traceparent=` válido já registrado no meta da tarefa é reutilizado verbatim, então uma tarefa relançada ou recuperada mantém uma identidade estável entre restarts em vez de iniciar um segundo trace.
  Um valor registrado corrompido é recunhado como raiz fresca em vez de propagado.

Como o `TRACEPARENT` ambiente nunca é lido, o ambiente sob o qual um supervisor por acaso roda - o carrier de lançamento de um XO, ou um shell de operador com um `TRACEPARENT` residual - não pode vazar para novas identidades de tarefa.
Desabilitar a propagação é uma fronteira intencional de trace: uma base desabilitada não injeta nenhum carrier num agente recém-lançado ou relançado mesmo quando o meta da tarefa já contém um `traceparent=` válido.
Um relançamento realmente desabilitado regenera o meta da tarefa sem `traceparent=`, então um relançamento posterior habilitado enraíza um novo trace em vez de retomar a identidade anterior à fronteira; reutilizar um endpoint remoto já vivo não é relançamento e preserva o carrier que aquele agente já detém.

### Habilitação tem escopo de sessão de base

Cada execução travada de `bin/sq-session-start.sh` resolve o `config/trace-context` daquela base mais `SQUAD_TRACE_CONTEXT` exatamente uma vez em estado efetivo com escopo de sessão.
A decisão é publicada atomicamente através de arquivo temporário no mesmo diretório e vinculada ao lock atual de sessão, então uma publicação falha não pode reativar um registro obsoleto `on` de uma sessão anterior.
Todo spawn daquela base lê apenas a decisão congelada `on` ou `off`.
Edições posteriores de config ou ambiente são ignoradas até aquela base iniciar nova sessão.
Estado efetivo ausente, obsoleto, ilegível, inválido ou publicado sem sucesso assume com segurança o padrão `off`.

Quando o primário lança um XO, local ou remoto, ele propaga `config/trace-context` para a base do XO e passa a decisão congelada da sessão primária como override de lançamento não vazio `SQUAD_TRACE_CONTEXT=on|off`.
O XO resolve aquele override herdado quando a própria sessão de base dele inicia.
Aquela flag é habilitação com escopo de sessão em vez de configuração durável, então é transferida no ponto de convergência de lançamento - onde a decisão congelada é entregue junto - e deixada intacta pela convergência viva numa base já rodando, tanto em rotas locais quanto remotas.
O que se propaga é a decisão de habilitação, nunca identidade de trace: um XO lançado enquanto habilitado recebe seu próprio carrier de tarefa do primário - a identidade do agente XO, reutilizada verbatim quando o próprio XO é relançado - e cada worker que ele spawnar enraíza seu próprio trace por tarefa.
Um XO lançado enquanto desabilitado mantém seus workers sem trace mesmo se `config/trace-context` estiver presente na base dele.
Quando habilitado, um relançamento reutiliza o carrier registrado válido da tarefa; uma tarefa sem um enraíza um trace fresco.
Um lançamento duplicado de XO é recusado antes da herança de trace-context, então o preflight de lançamento-duplicado não muta a base do XO.

Mudar a configuração na unidade inteira exige restart manual completo da unidade para que cada base inicie nova sessão e congele a nova decisão.
O Squad não monitora drift de configuração, não detecta divergências, não recusa lançamentos, nem para ou reinicia automaticamente qualquer base.

## Sampling

Uma nova raiz define as flags de trace W3C como `01` (sampled).
Esta é uma escolha deliberada, de propriedade da fonte:

- A capacidade é **opt-in** e default-off, então uma base que a habilita está pedindo para seus spawns serem rastreados; uma raiz unsampled (`00`) produziria um trace id que a maioria dos samplers parent-based downstream descartaria, não gerando nada para o operador que optou.
- **Um carrier registrado mantém suas flags verbatim.**
  A recuperação reutiliza o carrier registrado da tarefa byte-a-byte, flags incluídas, então a decisão de sampling de uma tarefa é estável entre restarts.
  O Squad escolhe a flag apenas quando cunha uma *raiz*, que é a única forma de criar um novo carrier.
- **Consequência de custo e privacidade.**
  `01` registra uma *decisão* de sampling, e um sampler parent-based downstream conforme vai honrá-la - mas ela sozinha não garante que qualquer collector armazene um span, e o Squad não emite spans próprios; apenas define a flag no carrier.
  Um operador que habilita a capacidade e aponta instrumentação respeitadora de sampling para ela deve esperar na ordem de um trace por tarefa gravado, com a cardinalidade e retenção para as quais aquela instrumentação estiver configurada.
  Um operador que quer raízes unsampled ou head-sampling é dono disso downstream ou via uma opção posterior explicitamente delimitada; o Squad não embute um sampler.

## Segurança

- **Default-off.**
  Sem `config/trace-context` e sem `SQUAD_TRACE_CONTEXT`, um spawn fresco ou relançamento real não injeta nada e não escreve linha `traceparent=`, então o meta gerado e o ambiente de lançamento ficam inalterados.
  Reutilizar um endpoint remoto já vivo registra qualquer carrier que o endpoint reporte sem injetar um novo.
  Um início de sessão travado faz a única checagem do arquivo de config, e cada spawn carrega (source) uma biblioteca extra e lê o arquivo congelado de estado efetivo, então o processo não é literalmente idêntico byte-a-byte, mas nada que um agente, um observador ou o meta da tarefa possam ver muda.
- **O que está e o que não está exposto.**
  Uma raiz *cunhada* pelo Squad usa id aleatório e não lê prompt, caminho, prosa da tarefa, credencial nem chave arbitrária de ambiente, então o Squad nunca *origina* dados sensíveis no carrier.
  Todo carrier que o Squad injeta ou é tal cunhagem ou o carrier previamente registrado da mesma tarefa reutilizado verbatim; o `TRACEPARENT` ambiente nunca é lido, então nenhum byte controlado pelo chamador entra num novo carrier.
  A exposição é limitada àquele carrier de largura fixa - ele não pode carregar um `tracestate`, uma variável de credencial `OTEL_*` nem qualquer chave arbitrária de ambiente, e não há comando configurável ou arbitrário (apenas os fixos locais `od`/`tr` para entropia).
- **Falha independente.**
  A cunhagem é um pequeno pipeline local de entropia: lê alguns bytes de `/dev/urandom` pelos fixos locais `od` e `tr` (resolvidos do PATH).
  Não há comando de provider configurado, rede ou watchdog.
  O custo normal é pequeno, mas `od`/`tr` são processos externos, então não há garantia dura de latência - isto não é um limite garantidamente desprezível.
  Qualquer falha de entropia ou auto-validação que retorna omite o carrier daquele spawn sem abortar o trabalho da fonte; um carrier registrado corrompido é recunhado como raiz fresca em vez de propagado (isso não é omissão).
  Se a exportação pré-lançamento do carrier falha, o Squad omite a alegação de metadados `traceparent=` e mesmo assim lança a tarefa.
  Se o backend reporta que o input de trace falho não pôde ser limpo, o Squad recusa appendar o comando de lançamento em vez de arriscar lançar com um carrier parcial desconhecido.
  Se o registro do carrier falha depois da exportação, o Squad unsetta `TRACEPARENT` no comando de lançamento e mesmo assim lança a tarefa, para que o filho nunca receba uma identidade ausente dos metadados dele.
- **Somente metadados.**
  O valor vive no shell efêmero do pane e em `state/<id>.meta`; o teardown remove estado como antes, então não há nova superfície durável nem migração de schema.

## Relação com OpenTelemetry e incrementos futuros

O Squad aprende nada sobre OpenTelemetry, exporter, collector, storage ou UI.
Ele emite um carrier W3C padrão e registra a mesma identidade; um observador downstream é dono de todo o resto e descobre a propagação ativa pela decisão congelada da sessão de base ou pelo campo `traceparent=`.
Emissão nativa de eventos de ciclo de vida, IDs estáveis extras, metadados de intake e qualquer OTLP embutido são deliberadamente adiados até um observador em execução demonstrar uma lacuna concreta de fidelidade que os artefatos derivados não consigam cobrir.

## Verificação

Evidência repetível de teste - as suítes de unidade e caminho de spawn com comandos e saída exatos - vive em [`verification/trace-context.md`](../verification/trace-context.md).
