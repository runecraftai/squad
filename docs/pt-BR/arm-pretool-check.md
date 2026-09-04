<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Cinto PreToolUse do arm do watcher

Este documento é o contrato autoritativo legível por humanos do cinto PreToolUse do arm da sentinela.
`bin/sq-arm-command-policy.mjs` é o único dono semântico.
`bin/sq-arm-pretool-check.sh` é apenas o transporte estável de harness e renderizador de saída.
Os adaptadores rastreados de harness encaminham o texto do comando sem classificá-lo.
`bin/sq-arm-command-policy.mjs` também é o único dono da classificação shell do Squad: exporta o tokenizer e a análise de posição de comando, que os cintos irmãos cd-guard, backend e polling reutilizam em vez de duplicar lexing shell.

## Propósito e fronteira

Um primário Squad precisa armar `bin/sq-sentry-arm.sh` ou rodar `bin/sq-sentry-checkpoint.sh` através de uma chamada observável de harness.
Um operador shell em segundo plano, pipeline, redireção, wrapper ou lista de comandos não relacionados pode esconder falha ou deixar o filho da sentinela morrer com a chamada de ferramenta.
O cinto rejeita esses formatos de comando antes da execução.

Esta política não é garantia de vitalidade pós-arm.
`bin/sq-guard.sh` e `bin/sq-turnend-guard.sh` aplicam seus respectivos predicados pós-arm de supervisão ao lock e beacon da sentinela depois de uma chamada permitida.

O classificador nunca executa, carrega via source, avalia nem expande qualquer parte do comando submetido.
Ele tokeniza os bytes e classifica apenas posições léxicas de execução.

## Transporte e comportamento fail-open

`bin/sq-arm-pretool-check.sh` suporta estes formatos de entrada:

- JSON stdin em `.tool_input.command` para Claude e Codex.
- JSON stdin em `.toolInput.command` para Grok.
- `--command <string exata>` para OpenCode, Pi e pi-signed.
- `--background` como campo somente-de-compatibilidade que nunca muda a decisão.
- `--claude` para preservar o requisito de negação apenas-stderr do Claude.

O wrapper descobre a raiz de código a partir da própria localização dele.
A base Squad ativa é `${SQUAD_BASE:-<raiz-do-código>}`.
Ele passa ambas as raízes e a string exata do comando ao dono da política em Node.

O wrapper fast-allows um comando sem invocar o dono da política em Node apenas quando o comando não pode conter a sequência de bytes `sq-sentry` mesmo após os decodificadores do classificador rodarem.
O fast path pode permitir apenas quando ambos valerem:

1. O texto despojado carece da substring de sentinela `sq-sentry`, depois de espelhar as normalizações mais baratas de bytes do classificador - descartar backslashes de continuação de linha e escape, aspas e newlines.
2. O comando bruto não carrega marcador decodificador de citação: um `$` imediatamente seguido de aspa simples (ANSI-C `$'...'`) ou aspa dupla (locale bash `$"..."`).

Qualquer match de `sq-sentry` ou qualquer marcador decodificador de citação delega ao classificador.
Normalizar primeiro mantém isto strict superset: um caminho protegido de sentinela ofuscado como `sq-watc\<newline>h-arm.sh` ou `sq-"watch"-arm.sh` ainda delega, e despajar apenas aqueles bytes não alfanuméricos nunca pode destruir uma execução `sq-sentry` existente.
O marcador decodificador de citação fecha o caso que o strip de bytes não consegue: `bin/sq-$'\x77'atch-arm.sh` e `bin/sq-$"watch"-arm.sh` só resolvem para `bin/sq-sentry-arm.sh` depois que o classificador decodifica o caractere codificado, então um strip barato de bytes perderia os bytes `sq-sentry` e fast-allows eles.
Este conjunto de marcadores é acoplado ao conjunto de decodificadores do classificador em `bin/sq-arm-command-policy.mjs`: adicionar qualquer nova forma de citação ou expansão que o classificador decode exige estender este conjunto na mesma mudança, senão o prefilter deixa de ser strict superset.
O prefilter não possui exceção semântica: ele só pode fast-allow um comando definitivamente não-sentinela, então nunca vira uma classificação e o classificador permanece único dono de toda decisão.

O modelo de ameaça do cinto são erros de agente: ninguém escreve acidentalmente um caminho de sentinela ofuscado em ANSI-C ou locale, e ofuscação deliberada é território do guard de vitalidade pós-arm.
O guard de marcadores fecha a lacuna estática de qualquer forma porque é barato e provável por classe de encoding.
Tripwire: se uma terceira lacuna strict-superset for encontrada depois desta generalização de marcadores, isso falsifica a alegação "provável por classe de encoding" e a decisão vira Opção B - derrubar o prefilter e sempre invocar o classificador.
Ofuscação mais profunda exigindo decode além do conjunto acoplado de marcadores continua responsabilidade do classificador e dos guards de vitalidade pós-arm.

Stdin malformado ou vazio, JSON inválido, `jq` ausente no transporte stdin, Node ausente, classificador ausente ou resposta inválida do classificador falham abertos com exit 0 e nenhuma saída.
Esse comportamento de transporte impede que um hook quebrado negue toda chamada de ferramenta shell.
Sintaxe shell malformada ou não suportada que contenha um comando protegido é resultado semântico de classificação e fecha com segurança.

## Classificação por posição de comando

O tokenizer reconhece cooked words com proveniência de citação, comentários, corpos heredoc, operadores de lista shell, pipelines, redireções, command e process substitutions, subshells parentetizados, brace groups e payloads literais aninhados de execução.
Texto citado, comentários, corpos heredoc e palavras de argumento posteriores são posições de dados a menos que um sink de execução reconhecido os execute recursivamente.

Uma palavra de comando em posição executada é execução protegida quando seu sufixo de caminho normalizado casa com um dos scripts protegidos de sentinela:

```text
bin/sq-sentry-arm.sh          (arm; entrypoint abençoado)
bin/sq-sentry-checkpoint.sh   (checkpoint; entrypoint abençoado)
bin/sq-sentry.sh              (watch; protegido mas nunca abençoado)
```

A forma relativa, a forma absoluta ancorada em `<raiz-do-código>`, e qualquer palavra terminando em `/bin/<script>` todas resolvem para aquela identidade.
Suffix matching reconhece estaticamente prefixo de caminho expandido, então `$SQUAD_BASE/bin/sq-sentry-arm.sh`, `$HOME/Squad/bin/sq-sentry-arm.sh` e `~/Squad/bin/sq-sentry-arm.sh` são a identidade arm.
O classificador nunca expande variável nem til; casa com os bytes literais apenas.
Formas estáticas de citação são cozinhadas antes do match de sufixo, então uma palavra de comando partida por aspas ordinárias (`sq-"watch"-arm.sh`), quoting ANSI-C (`sq-$'\x77'atch-arm.sh`) ou string de locale bash (`sq-$"watch"-arm.sh`) todas resolvem à mesma identidade; isso lê os bytes literais fixos como o shell os cozinharia e nunca roda expansão ou comando.
Isto cobre palavras literais visíveis estaticamente em posição de comando; dataflow dinâmico opaco como `bash -lc "$WHOLE_COMMAND"` permanece fora do escopo.

`bin/sq-sentry.sh` é protegido mas não é entrypoint abençoado.
Uma execução direta de `bin/sq-sentry.sh` - relativa, ancorada em `<raiz-do-código>`, prefixada com `$VAR` ou `~` - sempre nega com `sentry-direct`, cujo motivo aponta o chamador para `bin/sq-sentry-arm.sh` e `bin/sq-sentry-checkpoint.sh`.

Os mesmos bytes num argumento, comentário, asserção, consulta de documentação, string Python, `printf` ou payload `tmux send-keys` são dados e não tornam o comando externo relevante.

Payloads literais de `sh`, `bash` ou `zsh` `-c` e payloads literais de `eval` são recursivamente classificados.
Um payload literal aninhado que só roda um comando portador de dados é permitido.
Um payload literal aninhado que executa um comando protegido é negado como `sentry-nested`, mesmo quando aquela chamada protegida interna seria permitida no nível superior.

Payloads dinâmicos como `bash -lc "$WATCHER_COMMAND"` não podem ser provados estaticamente e permanecem responsabilidade do guard pós-arm.
Se o comando submetido primeiro constrói um assignment literal protegido e depois alimenta um valor dinâmico a um sink reconhecido de shell ou `eval`, o classificador nega conservadoramente como `sentry-nested`.

Comentários e corpos heredoc são ignorados como sintaxe de execução.
Um comando protegido real com um heredoc ainda tem uma redireção e é negado.

## Árvore de sintaxe abençoada

Um programa de sentinela permitido é uma única lista linear externa de comandos com zero ou mais nós aprovados de setup seguidos de exatamente um nó protegido direto.
`bin/sq-sentry-arm.sh` e `bin/sq-sentry-checkpoint.sh` são os únicos nós finais abençoados, incluindo suas formas de caminho expandido; um nó final `bin/sq-sentry.sh` nunca é abençoado e nega com `sentry-direct`.

Nós aprovados de setup são:

- `cd <uma palavra de caminho>`.
- `export NOME=<uma palavra shell>` sem command substitution, process substitution ou redireção.
- `source <caminho x-mode>` ou `. <caminho x-mode>`.
- `[ -f <caminho x-mode> ] && source <caminho x-mode>` e a forma equivalente com ponto.

Os caminhos x-mode permitidos são `config/x-mode.env`, `./config/x-mode.env`, e um caminho absoluto que normalize para `<base-Squad-ativa>/config/x-mode.env`.
Um caminho x-mode absoluto fora da base ativa não é nó aprovado de setup.

Nós aprovados podem ser separados por `;`, newline real ou `&&`.
`&&` é aceito depois de setup para que um `cd`, `export` ou source falho impeça a chamada protegida de rodar sob o setup errado.

O nó protegido final pode ter um wrapper imediato `exec`.
Seus argumentos são palavras shell ordinárias e podem conter ponto-e-vírgulas citados ou nomes de sentinela.
Nenhum outro wrapper é aprovado.

Assignments inline de ambiente, `env`, `sudo`, `nohup`, shells aninhados, `eval`, grupos de subshell, substituições, redireções, pipelines, listas assíncronas, `disown`, nós de lista não relacionados e sintaxe composta não suportada não são abençoados.

## Kills amplos de sentinela

Um comando `pkill` realmente executado é negado quando seus argumentos padrão parseados miram `sq-sentry`.
`pkill` qualificado por caminho, `command pkill` e `sudo pkill` são reconhecidos.

`kill "$(pgrep -f '/bin/sq-sentry.sh')"` também é negado porque o `kill` executado consome uma substitution `pgrep` executada ampla de sentinela.
Um `pgrep` standalone read-only é permitido.
Texto citado como `echo 'pkill -f sq-sentry'` é dado e é permitido.

Gramática composta não suportada - loop, `case`, `if` ou outro constructo que o classificador não modela - falha fechada para kills amplos da mesma forma que para execuções protegidas.
Quando o comando carrega tal gramática e seus bytes brutos referenciam tanto um alvo `sq-sentry` quanto um verbo `pkill` ou `kill`, o classificador não consegue provar qual posição de comando o kill ocupa, então nega com `broad-sentry-kill` em vez de permitir.
Esse backstop espelha a regra fail-closed de execução protegida e cobre formas como `while true; do pkill -f sq-sentry; done`, `for x in 1; do pkill -f sq-sentry; done`, `case x in x) pkill -f sq-sentry ;; esac` e `until false; do kill $(pgrep -f sq-sentry); done`.
É condicionado à gramática ser não suportada: em gramática que o classificador modela, a análise de posição de comando é autoritativa, então menções de dados como `echo 'pkill -f sq-sentry'` e um loop que só nomeia a sentinela sem verbo kill como `for f in 1; do echo sq-sentry; done` permanecem permitidos.

## Códigos estáveis de motivo

Toda negação semântica inclui um código estável entre colchetes antes do motivo em prosa.

| Código | Significado |
| --- | --- |
| `sentry-background` | Uma execução protegida está numa lista assíncrona ou usa `nohup` ou `disown`. |
| `sentry-pipeline` | Uma execução protegida participa de qualquer pipeline. |
| `sentry-redirection` | Uma execução protegida usa redireção shell. |
| `sentry-bundled` | A lista externa de comandos não é a árvore abençoada setup-mais-final. |
| `sentry-nested` | Um wrapper, grupo, substitution, shell aninhado, `eval` ou payload dinâmico construído executa o comando protegido. |
| `broad-sentry-kill` | Um kill real amplo de processos mira a sentinela. |
| `unclassifiable-protected-command` | Sintaxe malformada ou não suportada contém um comando protegido e não pode ser classificada com segurança. |
| `sentry-direct` | Uma execução direta de `bin/sq-sentry.sh`; a sentinela deve ser alcançada via `bin/sq-sentry-arm.sh` ou `bin/sq-sentry-checkpoint.sh`. |

Códigos de motivo são o contrato estável para testes e adaptadores.
Prosa pode melhorar sem mudar comportamento dos adaptadores.

## Contrato de saída

- Allow retorna exit 0 com ambos os streams vazios.
- Deny retorna exit 2 e escreve `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[code] reason"}` no stderr.
- O modo deny padrão também escreve `{"decision":"deny","reason":"[code] reason"}` no stdout para o Grok.
- `--claude` suprime completamente o stdout porque o Claude ignora uma negação PreToolUse quando o stdout não está vazio.
- O Codex bloqueia no exit 2 e exibe stderr.
- O OpenCode lança exceção apenas quando o checker sai 2.
- Pi e pi-signed retornam `{block: true}` apenas quando o checker sai 2.

## Fiação por harness

| Harness | Campo exato de comando | Comportamento do adaptador quando o checker sai 2 |
| --- | --- | --- |
| Codex | `.tool_input.command` | O comando do `.codex/hooks.json` encaminha o payload completo de stdin e o Codex bloqueia no exit 2. |
| Claude | `.tool_input.command` | O `.claude/settings.json` encaminha stdin com `--claude`, deixando stdout vazio e devolvendo o objeto de negação no stderr. |
| Grok | `.toolInput.command` | O `.grok/hooks/sq-primary-pretool-check.json` encaminha stdin e o Grok consome o objeto stdout `decision=deny`. |
| OpenCode | `output.args.command` | O `.opencode/plugins/sq-primary-pretool-check.js` passa um argumento `--command` e lança exceção apenas para exit 2. |
| Pi / pi-signed | `event.input.command` | O `.pi/extensions/sq-primary-turnend-guard.ts` passa um argumento `--command` e retorna `{block: true}` apenas para exit 2. |

Hooks de projeto Grok exigem confiança da pasta.
Toda referência de variável shell num comando de hook Grok precisa carregar default inline como `${GROK_WORKSPACE_ROOT:-}` porque o Grok expande o comando bruto do hook antes que `bash -lc` o execute.
O adaptador rastreado Grok portanto referencia `${GROK_WORKSPACE_ROOT:-}` diretamente em vez de atribuir e depois ler uma variável local `$root`.

## Registro de validação ao vivo, 2026-07-09

A validação rodou num projeto scratch em formato Squad inicializado com git sob este worktree de tarefa.
O projeto scratch continha cópias do checker e política modificados, adaptadores rastreados inalterados, um checkpoint dummy, um script arm dummy, um fixture inofensivo de captura de argumentos `tmux`, e um caminho privado de sentinela.
Nenhum arquivo modificado foi instalado no checkout primário ou numa configuração viva de harness.
Nenhuma sentinela viva, estado de unidade ou comando de ciclo de vida herdr foi usado.
A checagem interativa do OpenCode usou o socket tmux dedicado `sq-pretool-smoke`.

As versões dos harnesses eram:

```text
Claude Code 2.1.206
codex-cli 0.144.0
grok 0.2.93 (f00f96316d4b)
OpenCode 1.17.15
Pi 0.80.5
```

Todo harness recebeu instruções de emitir estas strings exatas de comando shell como chamadas de ferramenta separadas:

```sh
printf 'UNRELATED_EXECUTED\n'
pgrep -fl '/bin/sq-sentry.sh' || true
source '<projeto-scratch>/config/x-mode.env'; bin/sq-sentry-checkpoint.sh --seconds 180
tmux send-keys -t isolated-pi-lab "printf '%s\n' 'bin/sq-sentry-arm.sh &'"; tmux send-keys -t isolated-pi-lab Enter
bin/sq-sentry-arm.sh &
```

Os comandos reais de lançamento dos harnesses foram:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
GROK_HOME="$SCRATCH_GROK_HOME" RUST_LOG=xai_grok_hooks=debug GROK_LOG_FILE="$SCRATCH_LOG" grok --trust -p "$PROMPT" --permission-mode bypassPermissions --output-format plain
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO "$PROMPT"
pi -p -e .pi/extensions/sq-primary-turnend-guard.ts --no-context-files --no-session "$PROMPT"
```

A saída observada das quatro chamadas permitidas foi `UNRELATED_EXECUTED`, um `pgrep` read-only bem-sucedido, `CHECKPOINT_EXECUTED`, e duas linhas `TMUX_ARGS:` que preservaram o texto da sentinela como dado.
Cada harness bloqueou o comando final com exit 2 mapeado pelo comportamento nativo do adaptador dele.
O motivo estável foi `[sentry-background] a protected sentry command cannot run in an asynchronous shell list or through nohup/disown`.
O corpo dummy do arm teria criado `<harness>.sentinel` se o comando negado tivesse executado.
Todos os cinco arquivos sentinela permaneceram ausentes.

O transcript do Codex mostrou `PreToolUse Completed` para todos os três formatos originalmente reportados de falso positivo e `PreToolUse Blocked` apenas para o arm em segundo plano.
O transcript de debug do Grok mostrou quatro resultados exit-0 de `project/sq-primary-pretool-check`, depois exit 2 com 145 bytes stdout, 214 bytes stderr e `hook denied` para o arm em segundo plano.
O OpenCode exibiu as quatro saídas de comandos permitidos e depois `bin/sq-sentry-arm.sh & failed` com o objeto de negação no stderr.
Claude e Pi ambos reportaram que as chamadas um a quatro rodaram e a chamada final foi bloqueada.

Os caminhos nativos de supervisão também foram validados no mesmo projeto scratch:

- Claude rodou `bin/sq-sentry-arm.sh --restart` com sua opção rastreada nativa de segundo plano e produziu `sentry: started pid=<scratch> (scratch)`.
- Grok rodou o mesmo comando exato com `background: true`, seu hook devolveu exit 0, e o arm dummy produziu a mesma linha started.
- Codex rodou o checkpoint em primeiro plano acima e produziu `CHECKPOINT_EXECUTED`.
- OpenCode rodou numa TUI interativa em `tmux -L sq-pretool-smoke`, alcançou `session.idle`, e seu plugin sentry-arm inalterado criou o marcador scratch de automatic-arm.
- Pi carregou ambas as extensões primárias, chamou `sq_watch_arm_pi`, e criou o marcador scratch de automatic-arm.

Todo marcador automático de caminho nativo estava presente e todo sentinela de negação permaneceu ausente.

## Validação automatizada

`tests/sq-arm-pretool-check.test.sh` é dono da matriz adversarial de aceitação.
Toda linha roda através dos formatos de entrada stdin Codex, stdin Claude, stdin Grok, CLI OpenCode e CLI Pi.
A suíte também verifica bytes reais de newline, códigos de motivo diretos do classificador, comentários, dados heredoc, sintaxe protegida malformada e não suportada, payloads dinâmicos construídos, comportamento fail-open de transporte malformado, comportamento fail-open de runtime ausente, formatos de saída e encaminhamento exato de campos dos adaptadores mais mapeamento exit-2.

Rode:

```sh
bash -n bin/sq-arm-pretool-check.sh
shellcheck bin/sq-arm-pretool-check.sh tests/sq-arm-pretool-check.test.sh
node --check bin/sq-arm-command-policy.mjs
tests/sq-arm-pretool-check.test.sh
bin/sq-test-run.sh --all
```
