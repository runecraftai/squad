<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Cinto PreToolUse cd-guard

Este documento é o contrato autoritativo legível por humanos do cinto PreToolUse cd-guard.
`bin/sq-cd-command-policy.mjs` é o único dono das decisões.
`bin/sq-cd-pretool-check.sh` é o transporte estável de harness, escopo de checkout primário e renderizador de saída.
Os adaptadores rastreados de harness encaminham o texto do comando sem classificá-lo.

É o terceiro membro de uma família de guards de sessão primária que compartilham a mesma maquinaria de hook cross-harness:
o cinto PreToolUse do sentry-arm (`bin/sq-arm-pretool-check.sh`, `docs/arm-pretool-check.md`) e o guard de supervisão turn-end (`bin/sq-turnend-guard.sh`, `docs/turnend-guard.md`).

## Propósito e fronteira

O shell primário do Squad persiste seu diretório de trabalho entre chamadas de ferramenta.
Um `cd projects/<clone>` persistente e perdido no nível superior portanto realoca silenciosamente o shell, então o próximo comando controlado pelo Squad - uma escrita no backlog, uma chamada `sq-*` de ciclo de vida, o `sq-tasks` - roda dentro de um clone de projeto em vez da base.
Isso realmente aconteceu: um `cd` persistente de nível superior fez uma escrita no backlog controlada pelo Squad executar dentro de um clone de projeto em vez da base.
O cinto nega exatamente aquele formato de comando - uma mudança de cwd que persiste no shell primário - antes de rodar.

Este guard não é uma sandbox geral.
Ele classifica apenas posições de comando shell; nunca avalia, expande, carrega via source nem roda qualquer byte do comando submetido.
Seu modelo de ameaça são erros do agente, o mesmo do cinto sentry-arm: um `cd projects/foo` puro acidental, não um bypass deliberadamente ofuscado.

## Escopo: apenas checkouts simples do Squad

O guard dispara apenas num checkout simples do Squad onde git-dir é igual a git-common-dir.
Ele é um no-op silencioso (exit 0, sem saída) em todo outro lugar, então nunca interfere com um operador ou recon que legitimamente trabalha dentro do próprio worktree de projeto ou tarefa Squad dele.

`bin/sq-cd-pretool-check.sh` é dono da detecção de checkout dele; o escopo ciente-de-marcadores do turn-end guard é um contrato separado (`docs/turnend-guard.md`).
Um checkout simples, não-worktree, tem `git rev-parse --git-dir` igual a `git rev-parse --git-common-dir`.
Um worktree de tarefa de operador ou recon - o formato que `bin/sq-spawn.sh` sempre entrega - é um git worktree linkado onde os dois divergem, então o guard fica inerte ali.
O checkout também precisa carregar `AGENTS.md` e `bin/`, e qualquer falha em confirmar o primário é tratada como inerte, nunca como bloqueio.

O cd-guard não inspeciona `.sq-xo-home`.
Ele portanto se aplica numa base XO clonada por git onde git-dir é igual a git-common-dir, mas permanece inerte numa base XO arrendada pelo fob que é ela própria um worktree linkado.
Worktrees filhos de crew e recon de XO são igualmente inertes sob o teste de linked-worktree.

## Bloquear vs permitir

O discriminador é a persistência no cwd do shell pai, não a mera presença do token `cd`.

O guard **bloqueia** um builtin `cd`, `pushd` ou `popd` que rode numa posição top-level executada no shell pai, porque tal comando muda persistentemente o diretório de trabalho do próprio shell primário.
Isso cobre um `cd projects/foo` puro, `cd ..`, `cd`, `cd -`, um `cd /some/path` absoluto (ainda uma realocação persistente do shell pai), `pushd <dir>`, `popd`, uma forma com assignment à esquerda como `X=1 cd foo`, fragmentos citados ou escapados de palavra de comando que cozinhem para um builtin puro, e qualquer forma de lista onde o builtin rode no shell pai (`cd x && cmd`, `cmd; cd x`, `cmd || cd x`, `command cd x`, `command -p cd x`, `command -- cd x`, `builtin cd x`, `command builtin cd x`, `cd x >/dev/null`, e listas separadas por newline).

O guard **permite** todo o resto, incluindo estas formas seguras delimitadas que nunca devem ser bloqueadas:

- Um comando que alcança um alvo sem mudar o próprio cwd do shell: `git -C <dir> ...`, `make -C <dir> ...`, ou um caminho absoluto no próprio comando.
- Uma mudança de diretório que não persiste no shell pai: um subshell `(cd x && ...)`, um payload `bash -c 'cd ...'` / `sh -c` / `zsh -c`, um `env -C <dir> ...`, um runner `find ... -execdir`, um estágio de pipeline (`cd x | cmd`), ou um `cd x &` em segundo plano.
- Um `cd` atrás de um wrapper que faz fork ou exec (`env`, `sudo`, `nohup`, `timeout`, `gtimeout`, `exec`), que roda num filho e nunca persiste (e geralmente só falha, já que `cd` é um builtin sem programa externo).
- Um comando externo qualificado por caminho nomeado `cd`, `command` ou `builtin`, como `./cd`, `/usr/bin/cd`, `./command`, `/usr/bin/command` ou `./builtin`, porque roda como processo filho e não pode mudar o cwd do shell pai.
- Uma consulta `command` como `command -v cd`, `command -V cd`, ou forma agrupada como `command -pv cd`, porque reporta resolução de comando sem executar o builtin nomeado.
- O token `cd` aparecendo como dado: texto citado (`echo "cd projects/foo"`), um comentário, substring de outra palavra (`cdk`, `abcd`, `record`), um payload `printf`, ou qualquer palavra de argumento posterior.

Um `cd` com caminho absoluto é bloqueado de propósito: o carve-out ALLOW para caminhos absolutos vale para comandos que endereçam um alvo por caminho absoluto, não para `cd`, que realoca o próprio shell independentemente de seu argumento ser relativo ou absoluto.
Bloquear um `cd` top-level é seguro no sentido forte: o estado estacionário do guard é "sempre na base", então um `cd` de volta à base é redundante em vez de necessário, e o bloqueio nunca causa escrita em diretório errado.

### Não-objetivos aceitos

Consistente com o modelo de ameaça de erro-do-agente, o guard deliberadamente não persegue todo bypass ofuscado:

- Um `cd` reconstruído por command substitution (`$(echo c)d x`) ou escondido num brace group (`{ cd x; }`) não é bloqueado. A recursão em brace group é evitada porque este classificador não consegue distinguir com confiança um brace group `{ cd; }` de brace expansion `{cd,foo}`, e um falso bloqueio ali é pior que o bypass exótico perdido.
- Sintaxe malformada ou não tokenizável falha aberta (allow). Diferente do cinto sentry-arm, que fecha com segurança sobre comandos protegidos não classificáveis, o cd-guard prioriza zero falsos bloqueios sobre capturar um bypass malformado, porque um write no backlog bloqueado é um risco de correção enquanto um `cd` exótico perdido é apenas o status quo pré-existente.

Se for encontrado um formato de comando genuinamente ambíguo que arrisque falso bloqueio, o guard não é estendido por palpite; a ambiguidade é escalada e o guard continua preciso em vez de excessivamente ansioso.

## Código estável de motivo

Toda negação carrega um código estável entre colchetes antes do motivo em prosa.

| Código | Significado |
| --- | --- |
| `persistent-cd` | Um `cd`/`pushd`/`popd` top-level mudaria persistentemente o diretório de trabalho do próprio shell primário. |

O motivo direciona o chamador a alcançar o alvo sem mover o shell usando `git -C <dir>`, colocando um caminho absoluto no próprio comando pretendido, ou delimitando o `cd` a um subshell.
Ele não permite `cd /home/project`, porque um `cd` com caminho absoluto continua sendo mudança persistente de diretório e é negado.

## Transporte e comportamento fail-open

`bin/sq-cd-pretool-check.sh` suporta todos os cinco formatos de entrada de engine de harness usados pelos adaptadores rastreados, com pi-signed compartilhando o formato do Pi:

- Claude envia JSON stdin em `.tool_input.command` e adiciona `--claude` para preservar o requisito de negação apenas-stderr do Claude.
- Codex envia JSON stdin em `.tool_input.command` sem `--claude`.
- Grok envia JSON stdin em `.toolInput.command`.
- OpenCode envia a string exata do comando via `--command <string exata>`.
- Pi e pi-signed enviam a string exata do comando via `--command <string exata>`.

A ordem de processamento é mais-barato-primeiro: um prefilter strict-superset, depois o escopo de checkout primário, depois o dono da política em Node.
O prefilter remove aspas simples ordinárias, aspas duplas, backslashes, carriage returns e newlines antes de fast-allowing qualquer comando que não carregue substring `cd`, `pushd` ou `popd` e nenhum marcador decodificador de citação (`$'` ANSI-C ou `$"` locale), então fragmentos citados ou escapados de palavra de comando delegam à política enquanto a maioria dos comandos nunca paga pelas chamadas de escopo git nem pelo processo Node.
O conjunto de marcadores decodificadores de citação é acoplado ao conjunto de decodificadores do classificador em `bin/sq-arm-command-policy.mjs`: adicionar qualquer nova forma de citação ou expansão que o classificador decode exige estender o conjunto de marcadores do prefilter na mesma mudança, senão ele deixa de ser strict superset.

Stdin vazio, JSON não parseável, `jq` ausente no caminho stdin, Node ausente, dono de política ausente ou resposta inválida da política todos falham abertos com exit 0 e nenhuma saída.
Um hook quebrado nunca deve negar toda chamada de ferramenta shell.

## Contrato de saída

Idêntico em formato ao `docs/arm-pretool-check.md`:

- Allow (e inerte-fora-do-primário) retorna exit 0 com ambos os streams vazios.
- Deny retorna exit 2 e escreve `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[persistent-cd] reason"}` no stderr.
- O modo deny padrão também escreve `{"decision":"deny","reason":"[persistent-cd] reason"}` no stdout para o Grok.
- `--claude` suprime completamente o stdout porque o Claude ignora uma negação PreToolUse quando o stdout não está vazio.
- O Codex bloqueia no exit 2 e exibe o stderr.
- O OpenCode lança exceção apenas quando o checker sai 2.
- Pi e pi-signed retornam `{block: true}` apenas quando o checker sai 2.

## Posse compartilhada do classificador

`bin/sq-cd-command-policy.mjs` importa o tokenizer shell e a análise de posição de comando (`Lexer`, `splitProgram`, `commandPosition`) de `bin/sq-arm-command-policy.mjs`, único dono da classificação shell do Squad.
`basename` permanece helper privado do classificador arm compartilhado porque a política cd identifica builtins shell por identidade exata de cooked-word.
O cd-guard nunca duplica lexing shell; adiciona apenas a decisão específica de cd sobre aquele classificador compartilhado.
`bin/sq-arm-command-policy.mjs` roda seu próprio entrypoint CLI apenas quando invocado diretamente, nunca no import, para que as duas políticas fiquem CLIs independentes sobre um parser.

## Fiação por harness

| Harness | Entrada | Comportamento do adaptador quando o checker sai 2 |
| --- | --- | --- |
| Claude | hook Bash PreToolUse do `.claude/settings.json` encaminhando stdin com `--claude` | Bloqueia a chamada de ferramenta; objeto de negação no stderr, stdout vazio. |
| Codex | hook PreToolUse do `.codex/hooks.json` que ancora de `pwd -P`, verifica a raiz Squad carregada pelo hook e encaminha o payload | Bloqueia no exit 2 e exibe stderr. |
| Grok | hook PreToolUse `.grok/hooks/sq-primary-cd-check.json` ancorado em `${GROK_WORKSPACE_ROOT:-}` | Consome o objeto stdout `decision=deny`. |
| OpenCode | `tool.execute.before` do `.opencode/plugins/sq-primary-cd-check.js` | Lança exceção, que aparece como resultado falho da ferramenta. |
| Pi | handler `tool_call` do `.pi/extensions/sq-primary-turnend-guard.ts` | Retorna `{block: true}`; aproveita a extensão primária já carregada para que nenhum flag `-e` extra seja preciso. |

Cada harness roda o cd-guard junto do cinto sentry-arm; os dois são checagens independentes, e a negação de qualquer um bloqueia o comando.
Toda referência de variável shell no comando do hook Grok carrega default inline (`${GROK_WORKSPACE_ROOT:-}`) porque o Grok expande o comando bruto do hook antes que `bash -lc` o execute, o mesmo requisito documentado em `docs/arm-pretool-check.md`.

## Validação automatizada

`tests/sq-cd-pretool-check.test.sh` é dono da matriz de aceitação.
Todo caso de block e allow roda através dos formatos de entrada stdin Codex, stdin Claude, stdin Grok, CLI OpenCode e CLI Pi.
A suíte também prova a regressão end-to-end de vazamento de cwd (uma escrita no backlog controlada pelo Squad vazando para um clone de projeto, então negada no comando exato), o escopo de checkout (dispara num fixture XO clonado por git, inerte num worktree linkado operador/recon, inerte fora de checkout Squad, inerte fora de repo git), o comportamento fail-open do transporte, o fast path do prefilter, o contrato de saída da CLI da política e a fiação por harness.

Rode:

```sh
bash -n bin/sq-cd-pretool-check.sh
shellcheck bin/sq-cd-pretool-check.sh tests/sq-cd-pretool-check.test.sh
node --check bin/sq-cd-command-policy.mjs
node --check bin/sq-arm-command-policy.mjs
tests/sq-cd-pretool-check.test.sh
tests/sq-arm-pretool-check.test.sh
```

## Registro de validação ao vivo, 2026-07-11

Cada harness rodou contra um checkout scratch em formato primário do Squad: um repo git simples com `AGENTS.md`, `bin/` contendo o real `sq-cd-pretool-check.sh`, `sq-cd-command-policy.mjs` e `sq-arm-command-policy.mjs` mais um dummy no-op `sq-arm-pretool-check.sh`, um clone substituto `projects/foo/`, e a config de hooks rastreada do harness.
Nenhuma sentinela viva, estado da unidade, ou o checkout primário real do comandante foi envolvido.
Cada harness recebeu instruções de rodar, como chamadas de ferramenta separadas, um `cd projects/foo && touch <abs>/BLOCKED` top-level (deve ser negado) e um subshell `(cd projects/foo && touch <abs>/ALLOWED)` (deve rodar), com os arquivos sentinelas como observáveis.

Versões dos harnesses e resultados:

- **Claude Code 2.1.207** - bloqueou. O Claude reportou o comando top-level "denied by the `PreToolUse` hook (`sq-cd-pretool-check.sh`)", o sentinela `BLOCKED` estava ausente, e a forma de subshell teve permissão para rodar. Um controle prévio de `touch` provou que o harness executava comandos.
- **codex-cli 0.144.0** - bloqueou. O Codex registrou `error=Command blocked by PreToolUse hook: {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"[persistent-cd] a persistent top-level directory change ..."}`, o sentinela `BLOCKED` estava ausente, e o sentinela `ALLOWED` do subshell foi criado. Ambos os hooks PreToolUse arm e cd rodaram por comando (duas linhas `hook: PreToolUse Completed`), confirmando que o Codex re-alimenta o payload a cada hook do array.
- **OpenCode 1.17.18** - bloqueou. `opencode run` imprimiu `✗ cd projects/foo && touch ... failed` com `Error: {"hookSpecificOutput":...,"permissionDecision":"deny"},"systemMessage":"[persistent-cd] ..."}`, o sentinela `BLOCKED` estava ausente, e o sentinela `ALLOWED` do subshell foi criado.
- **Pi 0.80.6** - bloqueou. O sentinela `BLOCKED` estava ausente enquanto o sentinela `ALLOWED` do subshell foi criado; esse diferencial (top-level negado, subshell rodado, na mesma sessão) só pode vir do guard.
- **grok 0.2.93** - execução ao vivo inconclusiva: a Grok Build API devolveu `402 Payment Required: Grok Build usage balance exhausted`, então o modelo nunca emitiu os comandos de sonda. O hook cd do grok (`.grok/hooks/sq-primary-cd-check.json`) é estruturalmente idêntico ao hook grok do cinto arm já validado ao vivo em 2026-07-09 (`docs/arm-pretool-check.md`) - mesma ancoragem `${GROK_WORKSPACE_ROOT:-}` e mesmo consumo de deny PreToolUse - e o caminho stdin em formato grok (`.toolInput.command` entra, `{"decision":"deny"}` sai) é coberto por `tests/sq-cd-pretool-check.test.sh`. Rode novamente assim que o saldo do Grok for restaurado para fechar a lacuna ao vivo.

Os comandos de lançamento espelharam a validação do `docs/arm-pretool-check.md`:

```sh
claude -p "$PROMPT" --dangerously-skip-permissions --output-format text
codex exec --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check "$PROMPT"
OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode run --print-logs --log-level INFO "$PROMPT"
pi -p -e .pi/extensions/sq-primary-turnend-guard.ts --no-context-files --no-session "$PROMPT"
grok --trust -p "$PROMPT" --permission-mode bypassPermissions --output-format plain
```
