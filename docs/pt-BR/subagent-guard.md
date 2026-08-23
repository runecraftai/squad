<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Guard de delegação da sessão primária

Este documento é o contrato autoritativo legível por humanos do guard que impede que um primário do Squad delegue trabalho fora da unidade.

O mecanismo embarcado é `bin/sq-subagent-pretool-check.sh`, um guard PreToolUse que nega um nome de ferramenta com formato de delegação numa base primária genuína.
Primários Claude devem também usar uma lista não rastreada local `permissions.deny` por base como hardening para ferramentas conhecidas de delegação Claude, porque remove-as do schema do modelo completamente.
Essa lista deny não deve ser embarcada em `.claude/settings.json` rastreado porque é exclusiva de Claude em vez de agnóstica ao harness, e porque configurações rastreadas de projeto propagam para linked worktrees onde desarmam operadores legítimos.

## Por que isso existe

Em 2026-07-22 um primário Squad rodou quatro workers através da ferramenta embutida de subagent do Claude Code em vez de `bin/sq-spawn.sh`.
Três consequências foram observadas, não hipotetizadas.

- A view da unidade mostrou zero trabalho em andamento durante toda a execução, porque nenhum `state/<id>.meta` e nenhum `data/<id>/brief.md` foram criados.
- Quando a sessão primária reiniciou, dois daqueles workers morreram no meio do caminho e seu trabalho foi perdido.
  Um operador real vive em sua própria sessão de backend com estado durável e sobrevive a um restart primário.
- O ciclo de supervisão então ficou por 73 minutos sem ser percebido, o que silenciosamente matou o canal de intake do comandante no Workflowy, já que aquele canal só dispara enquanto um ciclo de watch roda.

O defeito mais profundo é que o bypass não apenas pulou despacho, ele tornou o branch de trabalho-em-andamento da pilha de guards estruturalmente inerte.
Apenas `bin/sq-spawn.sh` escreve `state/<id>.meta`, então trabalho não rastreado de projeto não contribui em nada com a contagem de trabalho-em-andamento usada por `bin/sq-supervision-lib.sh` e `bin/sq-turnend-guard.sh`.
Trabalho iniciado pela ferramenta de delegação própria do harness não escreve metadados, então a contagem em-andamento ficou em zero e o turn-end guard nunca bloqueou um fim de turno às cegas.

Essa é a razão por que a cerca tem que ficar na superfície de ferramentas do harness, antes que o primário possa criar trabalho não rastreado.
Nenhum guard adicional chaveado em metadados de tarefa pode pegar esta classe de falha, porque a falha é precisamente a ausência desses metadados.

## Propósito e fronteira

O guard endereça um evento concreto e mecanicamente identificável: a sessão primária alcançar uma ferramenta que cria trabalho que a unidade não vai conhecer.

Ele deliberadamente **não** endereça a questão mais ampla se uma dada peça de trabalho deveria ser delegada de forma alguma.
Essa questão é uma fronteira de julgamento sobre trabalho de ler-e-pensar, não tem sinal de formato de ferramenta, e um hook que tentasse policiá-lo degradaria em uma insistência consultiva.
A linha de escopo é portanto: ferramenta errada alcançada, negar; quantidade errada de raciocínio antes de alcançar uma ferramenta, fora do escopo.

O guard também não é uma checagem de qualidade de despacho.
Ele não diz nada sobre se o brief, projeto ou modo de entrega resultante está correto.

## Mecanismo embarcado

`bin/sq-subagent-pretool-check.sh` é a camada embarcada.
Ele classifica o NOME da ferramenta por formato em vez de contra uma lista fixa.
O matcher rastreado Claude PreToolUse é `.*`, então todo nome de ferramenta Claude alcança o script e o script é o único dono da classificação.
Um matcher que enumera estacas reintroduziria o problema de fail-open-por-enumeração que este guard existe para resolver, porque qualquer nome futuro de ferramenta fora do matcher seria silenciosamente perdido antes que o script pudesse inspecioná-lo.
Uma ferramenta tem formato de delegação quando seu nome normalizado em minúsculo contém uma dessas estacas:

```text
agent  subagent  task  workflow  cron  schedul  worktree
delegate  spawn  dispatch  handoff  remote  sendmessage  monitor
```

Três exclusões mantêm o teste de formato de gerar falsos positivos.

- Um nome começando com `mcp__` nunca é classificado.
  Um servidor MCP escolhe seus próprios nomes de ferramenta, um substantivo task ou agent ali é comum, e não tem impacto no despacho da unidade.
- `OBSERVE_ONLY_TOOLS`: os nomes exatos `taskoutput`, `taskstop`, `taskget`, `tasklist`, `cronlist`, `bashoutput` e `killshell` são permitidos.
  Eles observam ou param trabalho que já existe em vez de criá-lo, e negá-los nesta camada poderia deixar trabalho já rodando sem forma de inspecionar ou encerrar.
  Uma lista deny local opcional de um primário Claude pode ainda removê-los do schema.
  O guard embarcado fica mais estreito de propósito para nunca ser a razão de que uma tarefa descontrolada não possa ser parada.
- `PLAN_ONLY_TOOLS`: os nomes exatos `taskcreate` e `taskupdate` são permitidos.
  Eles escrevem, que é por que são uma lista separada em vez de mais entradas na de observar-ou-parar, mas o que eles escrevem é a lista de todo local-à-sessão do harness.
  Aquela lista não tem executor: não spawna nenhum agente, não aloca nenhum worktree, não registra nenhum agendamento e não inicia nada que possa sobreviver à sessão ou escapar de um guard do Squad.
  Então não é o "trabalho, agente, agendamento ou workspace isolado que o Squad não conheceria" que o guard existe para impedir, e a correspondência de estaca em `task` é um falso positivo em vez de política.
  O custo do falso positivo era concreto: o primário não conseguia rastrear seu próprio plano, e o texto deny dizia para rodar `bin/sq-brief.sh` e `bin/sq-spawn.sh` para criar uma entrada de todo.

Ambas as listas de exclusão casam com o nome normalizado inteiro, nunca substring, então nenhuma pode alargar por acidente: `TaskCreateAgent` e `RemoteTaskCreate` continuam negados.
Fundir as duas listas seria o risco de drift, porque a rationale de observar-ou-parar não é verdade para uma ferramenta que escreve.

O guard embarcado dispara em todo nome com formato de delegação que o alcança, incluindo futuros nomes que nenhuma lista deny conhece ainda.
Esse comportamento de nome-futuro é a razão pela qual o matcher rastreado deve casar com todas as ferramentas e deixar o script filtrar.

## Lista deny local recomendada para Claude

Primários Claude devem adicionar esta lista deny em configurações locais não rastreadas por base, nunca em `.claude/settings.json` rastreado:

```json
{
  "permissions": {
    "deny": [
      "Task",
      "Agent",
      "Workflow",
      "RemoteTrigger",
      "Monitor",
      "ScheduleWakeup",
      "SendMessage",
      "EnterWorktree",
      "ExitWorktree",
      "CronCreate",
      "CronDelete",
      "CronList",
      "TaskGet",
      "TaskList",
      "TaskStop",
      "TaskOutput"
    ]
  }
}
```

Um nome negado é removido do schema do modelo completamente.
O modelo nunca recebe a ferramenta oferecida, então não há chamada a interceptar, nenhum matcher para errar, nenhum caminho fail-open e nenhuma dependência da cooperação do modelo.
Isto é remoção, não interceptação, e é estritamente mais forte que qualquer hook.

Esta lista é hardening local recomendado porque fecha a superfície conhecida do Claude antes que o hook seja necessário.
Ela não é rastreada por duas razões.

- É exclusiva de Claude, então nunca pode ser a correção embarcada agnóstica ao harness.
- Um `.claude/settings.json` rastreado propaga para linked worktrees e desarma operadores legítimos.
  Isso foi verificado quando uma sessão Claude num worktree de tarefa deste repo perdeu sua ferramenta `Agent`.

A largura da lista continua sendo decisão do comandante, porque negar algumas delas muda como o comandante trabalha com a sessão primária.
Mantenha-a como um array local plano que pode ser revisado num olhar e estreitado em uma linha.
Em particular `TaskOutput`, `TaskStop`, `TaskGet`, `TaskList` e `CronList` apenas observam ou param trabalho que já existe, mas a lista deny local recomendada ainda remove todos os cinco por padrão.
O hook deliberadamente permite aqueles cinco, então o guard embarcado nunca pode deixar uma tarefa descontrolada sem forma de inspecionar ou encerrar, e ele permite `TaskCreate` e `TaskUpdate` também, então nunca pode ser a razão de que o primário não consiga rastrear seu próprio plano.
As duas ferramentas de todo local-à-sessão não são mais recomendadas para negação local de forma alguma, porque escrevem apenas a lista de todo local-à-sessão do harness, que não tem executor e não spawna nada, então removê-las do schema não remove poder de delegação.
Negá-las lá reproduziria em camada mais forte o exato falso positivo que o guard embarcado agora evita, deixando qualquer um que adote esta lista verbatim incapaz de deixar um primário rastrear seu próprio plano.
Estreitar a lista mais, incluindo os cinco nomes de observar-ou-parar, é decisão do comandante, e esta lista local é a única camada que pode remover uma ferramenta de todo do schema do primário.

`permissions.allow` é uma lista de pré-aprovação, não uma lista de disponibilidade, então não existe allowlist fail-closed positiva disponível.
É por isso que qualquer lista deny fixa é fail-open contra futuras ferramentas e por que o guard baseado em formato ainda existe.
O hook não pode re-habilitar uma ferramenta removida do schema; ele apenas lida com um nome de ferramenta que ainda alcança PreToolUse.

### Tanto `Task` quanto `Agent` são chaves deny válidas

A ferramenta se apresenta ao modelo como `Agent`.
Uma investigação prévia registrou que a chave deny deve ser `Task` e que usar `Agent` "silenciosamente não faz absolutamente nada".
Isso não é o que esta máquina mostra.

Um A/B cinco vias com controle, cada um rodado em seu próprio diretório para descartar cache de configurações, descobriu que `Task` e `Agent` cada um independentemente removem a ferramenta, e que um nome absurdo a deixa presente.
A evidência completa está no registro de validação abaixo.

Fixar ambos os nomes na lista deny local recomendada é correto independente de qual build esteja rodando.
Custa uma linha e remove o modo de falha onde um rename ou rollback silenciosamente reabre a superfície.

## Escopo

O hook embarcado dispara apenas numa base primária genuína do Squad, usando o predicado compartilhado `fm_primary_scope_matches` de `bin/sq-primary-scope-lib.sh`.
Este é o mesmo predicado usado por `bin/sq-sessionstart-nudge.sh` e `bin/sq-turnend-guard.sh`, então os três hooks rastreados com escopo primário não podem divergir.

Uma base está em escopo quando tem `AGENTS.md`, um diretório `bin/`, um diretório de estado existente, e ou um checkout simples onde git-dir é igual a git-common-dir ou um marcador `.sq-xo-home` válido.
Uma base XO marcada está em escopo de propósito: opera sua própria unidade e deve despachar por ela pelas mesmas razões de durabilidade.

O worktree descartável de tarefa de um operador é um linked git worktree, que é o formato que `bin/sq-spawn.sh` sempre entrega, então está fora do escopo.
Um operador usando ferramentas de delegação dentro de seu próprio worktree de tarefa é legítimo e continua permitido.
Um repo não-Squad está fora do escopo.
Qualquer falha em confirmar a base é inerte, nunca bloqueio, então um ambiente quebrado nunca pode negar uma chamada de ferramenta.

Uma lista deny local do Claude está upstream do escopo do hook e remove ferramentas conhecidas de delegação Claude onde quer que Claude a aplique.
Não coloque aquela lista em configurações rastreadas de projeto, porque linked worktrees herdariam aquelas configurações e perderiam ferramentas legítimas de delegação.
O escopo do hook é a fronteira de imposição embarcada, e o caso negativo de linked-worktree prova que o próprio script não bloqueia delegação legítima de operadores.

## Escape hatch

`SQUAD_ALLOW_SUBAGENT=1` no ambiente da sessão permite a chamada no hook embarcado.
Este é o único escape hatch e o guard fecha com segurança em todo outro valor, incluindo vazio, `0`, `yes` e `true`.

É uma variável de ambiente em vez de flag, arquivo de configuração ou arquivo de estado porque isso torna-a inforjável na sessão.
A variável precisa estar presente quando o processo do harness é lançado, então nenhuma chamada de ferramenta que o agente faça pode habilitá-la para a chamada seguinte.
Um uso deliberado portanto exige reiniciar a sessão com a variável definida, que é um ato consciente, enquanto um uso acidental é impossível.

O escape hatch não afeta nenhuma lista deny local do Claude.
Uma ferramenta removida do schema permanece removida, então um uso genuinamente pretendido de uma ferramenta localmente negada também exige estreitar ou remover aquela entrada local antes do lançamento.

## Contrato de saída

- Allow retorna exit 0 com ambos os streams vazios.
- Deny retorna exit 2 e escreve `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[subagent-dispatch] ..."}` no stderr.
- O modo deny padrão também escreve `{"decision":"deny","reason":"[subagent-dispatch] ..."}` no stdout para o Grok.
- `--claude` suprime o stdout completamente, porque o Claude Code ignora um deny PreToolUse quando o stdout não está vazio.
  Esta é a mesma peculiaridade verificada registrada em [`arm-pretool-check.md`](../arm-pretool-check.md), e o hook rastreado Claude portanto passa `--claude`.
- Stdin malformado ou vazio, JSON inválido, payload sem nome de ferramenta, e `jq` ausente no transporte stdin todos falham abertos com exit 0 e nenhuma saída.

A mensagem deny nomeia o caminho real de despacho.
Quando `bin/sq-recon.sh` existe na base a mensagem primeiro adia à classificação de intake do `AGENTS.md`, depois roteia trabalho já classificado como recon lá e trabalho ship autorizado com sua pesquisa limitada para `bin/sq-brief.sh` depois `bin/sq-spawn.sh`.
Quando esse script está ausente a mensagem ainda adia à classificação de intake e degrada para nomear `bin/sq-brief.sh` depois `bin/sq-spawn.sh` para trabalho despachado, em vez de apontar para um script que não existe.

## Fiação por harness

Todo harness primário suportado foi revisado.
Aplicabilidade gira em torno de uma questão: o harness expõe ferramentas embutidas de delegação que uma sessão primária poderia usar em vez de `bin/sq-spawn.sh`?

| Harness | Superfície de delegação | Status |
| --- | --- | --- |
| Claude | 16 ferramentas conhecidas, listadas acima | Guard escopado fiaado e verificado ao vivo; lista deny local não rastreada verificada e recomendada. |
| Codex | nenhuma | Não aplicável, verificado empiricamente abaixo. Codex 0.144.1 não expõe nenhuma ferramenta de subagent, sub-task ou delegated-agent, então não há nada para remover ou interceptar. `.codex/hooks.json` inalterado. |
| Grok | presente, tokens exatos não confirmados | Não fiaado pendente de verificação ao vivo. Veja abaixo. |
| OpenCode | presente, tokens exatos não confirmados | Não fiaado pendente de verificação ao vivo. Veja abaixo. |
| Pi | nenhuma reportada | Não fiaada pendente de verificação ao vivo. Veja abaixo. |

### Codex, verificado não aplicável

Codex 0.144.1 recebeu instruções de enumerar suas próprias ferramentas num repo git de rascunho em 2026-07-22.

```sh
codex exec --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
  "List the exact names of every tool available to you in this session, one per line, nothing else. Then state on a final line whether you have any tool that spawns a subagent, sub-task, or delegated agent: answer SUBAGENT_TOOL=yes or SUBAGENT_TOOL=no."
```

Conjunto exato de ferramentas reportadas e veredito:

```text
web.run
functions.exec_command
functions.write_stdin
functions.list_mcp_resources
functions.list_mcp_resource_templates
functions.read_mcp_resource
functions.update_plan
functions.request_user_input
functions.request_plugin_install
functions.view_image
functions.get_goal
functions.create_goal
functions.update_goal
functions.apply_patch
image_gen.imagegen
tool_search.tool_search_tool
multi_tool_use.parallel
SUBAGENT_TOOL=no
```

`multi_tool_use.parallel` agrupa chamadas às ferramentas acima; ele não spawna um agente.
O Codex portanto não é aplicável hoje, e esta linha da tabela é o tripwire: se um release futuro do Codex adicionar uma ferramenta delegated-agent, fie `.codex/hooks.json` da mesma forma que suas entradas Bash PreToolUse já encaminham stdin para um checker.

### Grok, OpenCode e Pi, inspecionados mas não fiados

A superfície de integração de cada um foi inspecionada e cada um é estruturalmente fiaável para o guard embarcado.

- Os hooks rastreados do Grok (`.grok/hooks/sq-primary-pretool-check.json`, `.grok/hooks/sq-primary-cd-check.json`) usam um matcher `PreToolUse`, atualmente `Bash`, e canalizam stdin para um checker.
  O checker já lê o campo `.toolName` do Grok, então só falta o token do matcher.
  O Grok expõe sim uma superfície de delegação: `docs/supervision-protocols/grok.md` documenta `get_command_or_subagent_output(<task_id>)`, o que implica uma ferramenta de despacho correspondente.
- Os plugins rastreados do OpenCode condicionam em `input?.tool !== "bash"` dentro de `tool.execute.before` e bloqueiam lançando exceção.
  Trocar essa comparação por uma chamada a este checker com `--tool` é a mudança inteira.
- A extensão rastreada do Pi condiciona em `event.toolName !== "bash"` dentro de `pi.on("tool_call", ...)` e bloqueia retornando `{block: true}`.
  A mesma mudança se aplica. Uma avaliação paralela reporta que o Pi não expõe nenhuma ferramenta de delegação, o que o tornaria não aplicável, mas isso não foi verificado aqui.

Nenhum dos três está fiaado nesta mudança porque nenhum dos três binários está instalado no host onde este trabalho foi feito, então os tokens exatos de nomes de ferramenta não puderam ser confirmados e a fiação não pôde ser validada contra o harness real.
A regra neste repo na skill `squad-coding-guidelines` é que um hook de harness deve ser validado num projeto de rascunho antes de ser confiável, e `arm-pretool-check.md` registra o custo concreto de adivinhar: um hook do Grok cuja string `command` está mesmo um pouco errada falha em lançar o hook completamente.
Fiar um matcher não validado trocaria uma lacuna conhecida por uma falha desconhecida.

O follow-up limitado para cada um é idêntico ao procedimento do Codex acima.
Num host com o binário instalado, peça ao harness para enumerar suas ferramentas, depois fie o matcher e reexecute a matriz ao vivo abaixo.
`bin/sq-subagent-pretool-check.sh` não precisa de mudanças para nenhum deles: já aceita o formato stdin do Grok e a forma CLI `--tool` que OpenCode e Pi usam, e já emite o objeto stdout decision do Grok por padrão.

## Registro de validação ao vivo, 2026-07-22

Versão do harness:

```text
2.1.217 (Claude Code)
```

Toda execução usou um projeto de rascunho sob este worktree de tarefa.
Nenhum arquivo modificado foi instalado no checkout primário ou configuração viva de harness, e nenhuma sentinela viva, estado de unidade ou metadados de tarefa foram usados.
O comando de lançamento durante todo o processo foi:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
```

### Mecânica de nome de ferramenta e matcher

O nome de ferramenta entregue aos hooks PreToolUse foi estabelecido antes de qualquer matcher ser escrito, usando um projeto descartável cujo único hook appendava `.tool_name` num log para matcher `.*`.
Ele logou `Agent` e `Bash`.
Um segundo projeto usando matcher `^(Task|Agent)$` logou apenas `Agent`, confirmando tanto o nome de ferramenta ao vivo quanto que o Claude Code honra âncoras regex num matcher PreToolUse.
O matcher rastreado agora é `.*`, correspondendo à evidência do projeto descartável acima para que qualquer futuro nome de ferramenta alcance o classificador do script.

### A/B de chave deny, com controle

Prompt: `List the exact names of every tool available to you, comma-separated on one line, nothing else.`
Cada variante rodou em seu próprio diretório fresco para descartar cache de configurações.

| `.claude/settings.json` | `Agent` na lista de ferramentas? |
| --- | --- |
| `{}` | Sim |
| `{"permissions":{"deny":["Task"]}}` | Não |
| `{"permissions":{"deny":["Agent"]}}` | Não |
| `{"permissions":{"deny":["ZzzNotARealTool"]}}` | Sim |
| `{"permissions":{"deny":["Task","Agent"]}}` | Não |

O controle de nome absurdo é o que torna isso conclusivo: a ferramenta some apenas quando um nome real é negado, então a remoção é causada pela entrada deny em vez de variação execução-a-execução.
Ambos `Task` e `Agent` estão portanto funcionando como chaves deny neste build, corrigindo a afirmação anterior de que apenas `Task` funciona.

A superfície baseline observada era de 29 ferramentas:

```text
Agent, Bash, Edit, Read, ReportFindings, ScheduleWakeup, Skill, ToolSearch, Workflow, Write,
CronCreate*, CronDelete*, CronList*, DesignSync*, EnterWorktree*, ExitWorktree*, Monitor*,
NotebookEdit*, PushNotification*, RemoteTrigger*, SendMessage*, TaskCreate*, TaskGet*,
TaskList*, TaskOutput*, TaskStop*, TaskUpdate*, WebFetch*, WebSearch*
```

Um `*` marca ferramenta adiada, que é lazy-loaded via `ToolSearch` e não aparece numa listagem simples a menos que o prompt peça entradas adiadas.
Essa distinção importa ao ler o próximo resultado: uma ferramenta ausente de uma listagem simples não está necessariamente negada.

### Hardening de lista deny local

Rodado num projeto de rascunho em formato Squad contendo `AGENTS.md`, `state/`, uma cópia completa de `bin/`, e um arquivo de configurações do Claude contendo a lista deny local exatamente como recomendada naquela data, que era a forma de 18 nomes que ainda incluía `TaskCreate` e `TaskUpdate`.
O resultado valida aquela lista deny local em vez de estado rastreado do repo, e a recomendação acima desde então dropou aquelas duas ferramentas de todo local-à-sessão.
Pedir entradas adiadas explicitamente retornou:

```text
Bash, Edit, Read, ReportFindings, Skill, ToolSearch, Write,
DesignSync*, NotebookEdit*, PushNotification*, WebFetch*, WebSearch*
```

Todos os 18 nomes localmente negados foram e toda ferramenta ordinária de trabalho permanece, incluindo as cinco adiadas.
Comparar contra a baseline de 29 ferramentas confirma que o conjunto de remoção é exatamente a lista deny e nada mais.

### Guard embarcado, o caso que uma lista deny fixa não pode cobrir

Para reproduzir uma ferramenta futura que embarca antes que uma lista deny local seja atualizada, `Workflow` foi removido da lista deny no mesmo projeto de rascunho enquanto o guard permanecia fiaado.

Prompt: `Call the Workflow tool to run any trivial workflow. You must actually attempt the Workflow tool call.`

Claude reportou:

```text
I attempted the Workflow tool call as requested. It was blocked by a PreToolUse hook in this repo:

> [subagent-dispatch] the Squad primary dispatches through the unit, not the harness's own
> delegation tools... (blocked tool: Workflow). Launch the session with SQUAD_ALLOW_SUBAGENT=1 for a
> deliberate exception.
```

Este é o resultado load-bearing: o guard embarcado negou uma ferramenta de delegação que a lista deny não cobria, que é o caso de nome-futuro para o qual o classificador de formato existe.

### Escopo do guard embarcado, o caso negativo

O mesmo prompt `Workflow` foi então rodado num linked worktree com `git worktree add` do projeto de rascunho, carregando os mesmos hook rastreado e checker, sem escape hatch.

```text
The Workflow tool call was not blocked by a hook. It executed normally: launched, ran 1 agent,
and completed successfully returning {"result":"ok"}.
```

Mesmo hook, mesmos bytes, deny na base primária e allow num worktree com formato de operador.
Isto é o contrato de escopo funcionando end-to-end em vez de um hook que simplesmente nunca dispara.

### Escape hatch

O mesmo prompt `Workflow` na base primária de rascunho, lançado como `SQUAD_ALLOW_SUBAGENT=1 claude -p ...`:

```text
Result: the Workflow tool call was NOT blocked by a hook. It launched and ran to completion.
```

### Requisito de stdout vazio

Um deny do Claude é honrado apenas quando o stdout do hook está vazio.
`tests/sq-subagent-pretool-check.test.sh` afirma que o stdout está vazio em todo deny `--claude` e que o modo padrão ainda emite o objeto Grok no stdout.
A consequência ao vivo é confirmada pelo resultado do guard embarcado acima: Claude honrou o deny e reportou o texto de motivo.

## Validação automatizada

`tests/sq-subagent-pretool-check.test.sh` é dono da matriz de aceitação e está registrado na família `pure-contract-unit` em `bin/sq-test-run.sh`.
Ele cobre a fronteira de configurações rastreadas do Claude que proíbe uma chave `permissions`; o registro de hook match-all Claude; negação de toda ferramenta de delegação que cria trabalho por formato; negação de doze nomes hipotéticos futuros de ferramenta que não aparecem em nenhuma lista; as exclusões de observar-ou-parar, apenas-plano e MCP; a exatidão da exclusão apenas-plano contra seis nomes quase-acerto que uma expansão por substring ou estaca mais curta liberaria; as variantes de mensagem recon-presente e recon-ausente; o escape hatch incluindo seus valores fail-closed; inertez em linked worktree de tarefa e em repo não-Squad; imposição in-scope para uma base XO marcada; ambos os transports de stdin; o requisito de stdout vazio; comportamento fail-open de transporte; e os cintos `Bash` preservados e o guard `Stop`.

Rode:

```sh
bash -n bin/sq-subagent-pretool-check.sh
bin/sq-lint.sh
tests/sq-subagent-pretool-check.test.sh
```

## Lacuna residual conhecida

As outras entradas rastreadas de hook Claude em `.claude/settings.json` se recusam a rodar sob o carregamento de settings compatíveis-com-Claude do Grok (docs/turnend-guard.md "Harness integrations"), porque o Grok já cobre cada um daqueles eventos através do próprio registro dele em `.grok/hooks/` e rodar ambos cria caminho duplicado.
Esta entrada é a exceção deliberada e continua sem guarda: Grok é "inspecionado mas não fiado" acima, então nenhum registro `.grok/hooks/` cobre o evento de spawn de subagent de forma alguma, e guardá-lo removeria o guard do Grok completamente em vez de deduplicá-lo.
A cobertura que ele deixa é parcial em vez de correta - a entrada rastreada passa `--claude`, que suprime exatamente o objeto stdout decision que o Grok consome - então trate isso como alcance incidental, não como Grok sendo fiado.

Fiar o Grok adequadamente ainda requer a verificação por token-matcher descrita acima, e é isso que fecha esta exceção.

Esta mudança não fecha o defeito mais profundo agnóstico-a-harness.
O branch de trabalho-em-andamento de todo guard do Squad é chaveado em `state/<id>.meta`, e apenas `bin/sq-spawn.sh` escreve aquele registro.
`bin/sq-supervision-lib.sh` também reconhece um poll de Relay como necessidade de supervisão, mas trabalho primário não contabilizado ainda não contribui nada para aquele predicado.
Sem uma necessidade de Relay independente, trabalho primário não contabilizado portanto é lido como ocioso em vez de suspeito.

A correção durável para aquela classe é fazer os guards tratarem "o primário está fazendo trabalho com formato de projeto com zero arquivos `state/*.meta`" como estado suspeito em vez de ocioso.
Isso pegaria esta classe em qualquer harness, incluindo trabalho criado através de `Bash`.
Esta mudança cerca apenas a superfície de ferramentas do Claude.
Isso é uma mudança separada para `bin/sq-supervision-lib.sh` e `bin/sq-turnend-guard.sh` e está fora do escopo aqui.
