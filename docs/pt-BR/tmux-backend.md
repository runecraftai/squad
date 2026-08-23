<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Backend de runtime tmux

O tmux é o backend de runtime de referência verificado do Squad e a baseline totalmente suportada para bases XO.
[`configuration.md`](../configuration.md#runtime-backend-configbackend--squad_backend) é dona da semântica compartilhada de seleção de backend e metadados.

## Setup

Instale o tmux com `brew install tmux` ou o gerenciador de pacotes da sua plataforma.
Os requisitos universais de harness e toolchain estão em [`configuration.md`](../configuration.md#toolchain).

O tmux é o padrão rígido quando nenhuma configuração explícita ou auto-detecção de runtime seleciona outro backend.
Selecione-o explicitamente com o `config/backend` local contendo `tmux`, com `SQUAD_BACKEND=tmux` para um único lançamento, ou pedindo ao Squad para usar tmux.
Uma seleção explícita também é o opt-out da auto-detecção de runtime Herdr ou cmux.

Nenhum provisionamento é exigido antes da primeira tarefa.

## Assistindo ao operador

Para a melhor experiência visível, lance o harness primário dentro de uma sessão tmux:

```sh
tmux new -s Squad
```

Tarefas da crew viram janelas nessa sessão.
`tmux display-message -p '#S'` imprime seu nome.
Se o harness primário roda fora do tmux, o Squad cria ou reutiliza uma sessão detached chamada `Squad`:

```sh
tmux attach -t Squad
```

Cada janela de tarefa é nomeada `sq-<id>`.

```sh
tmux list-windows -t <nome-da-sessao>
tmux select-window -t <nome-da-sessao>:sq-<id>
```

Digitar numa janela de tarefa anexada é intervenção direta autoritativa.
A supervisão rotineira não exige attach: `bin/sq-peek.sh <id>` captura uma cauda limitada e `SQUAD_BASE=<home> bin/sq-send.sh <id> '<texto>'` direciona o endpoint registrado.

Verifique o setup spawnando uma tarefa pequena e confirmando que sua janela `sq-<id>` aparece na sessão selecionada.

## Ground truth da sidebar

O `bin/sq-window-state.sh` publica o estado atual (working / awaiting-decision / blocked / done / idle / failed / unknown) de cada janela tmux de tarefa em `state/window-states` para a sidebar tmux ground-truth ([`sq-sidebar.md`](../sq-sidebar.md)) consumir.
O cabeçalho desse script é dono do contrato do arquivo e da tradução de verbo-para-rótulo; `bin/sq-crew-state.sh` permanece dono da reconciliação de estado atual que ele publica.
É uma derivação one-shot (sem daemon): um consumidor roda `publish` na própria cadência de refresh dele.

## Comportamento e segurança atuais

### Sonda de vitalidade do agente

Uma checagem de existência do alvo prova apenas que o pane existe.
A sonda mais profunda de vitalidade do agente no tmux primeiro verifica a pertença exata à janela, depois lê nomes de processo para distinguir um harness rodando de um shell ocioso puro.
Ela classifica nomes reconhecidos de processos Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi e Muse como `alive`, shells comuns como `dead`, uma janela autoritativamente ausente como `missing`, estado ilegível como `unreadable`, e todo outro processo como `ambiguous`.
Apenas `dead` e `missing` autorizam recuperação porque um falso resultado dead poderia lançar um agente duplicado.

Para atribuição positiva, a sonda combina duas fontes independentes de nomes em vez de tornar qualquer uma delas load-bearing.
`#{pane_current_command}` e os valores kernel de `comm` do grupo de processo em foreground da tty do pane expõem campos de nome diferentes, e qual deles retém identidade executável depende da plataforma.
A sonda de foreground também lê argv[0] para que um componente exato de caminho de instalação do harness possa carregar o veredito quando os outros campos expõem um nome de processo reescrito.
Qualquer fonte nomeando um harness verificado basta para `alive`, porque um falso `dead` é o único veredito que pode iniciar um agente duplicado num worktree vivo, enquanto um grupo de processo de foreground legível decide os vereditos negativos.

Limitar a segunda fonte ao grupo de processo em foreground em vez dos descendentes do pane é deliberado: um processo com nome de harness deixado rodando em segundo plano de um painel de outra forma ocioso não pode ser lido como um agente.
O mesmo escopo cobre launchers multiprocesso sem caso especial, então o caminho Pi Launcher é atribuído pelo wrapper `pi-signed` e engine `pi` mesmo que seu título seja o comando exato em foreground `pi-launcher`.
As identidades executáveis diretas `pi`, `pi-signed` e `Pi` continuam aceitas exatamente, e nomes similares ou prefixados não são aceitos por essas entradas exatas da família Pi.
O Muse igualmente se ancora na identidade exata do launcher `muse` ou no prefixo instalado `muse-bin-<versão>`, então nomes não relacionados como `musescore` e `amuse` continuam ambíguos.

A regressão portátil imposta pelo CI e o guard opt-in de drift com harness real seguem a divisão de propriedade de `.agents/skills/squad-coding-guidelines/SKILL.md`.
Rode o guard com harness real depois de qualquer upgrade de harness e antes de confiar em evidência atualizada.

### Composer, estado ocupado e entrega

Vitalidade do agente e segurança do composer são checagens separadas.
Para um composer com borda, o leitor tmux localiza a caixa completa estruturalmente e classifica cada linha de conteúdo pelo tratamento compartilhado de ANSI e ghost em `bin/sq-composer-lib.sh`.
Texto real em qualquer linha de conteúdo é pendente, enquanto só uma caixa inequívoca com todas as linhas vazias está provada vazia.
Caixas ilegíveis, incompletas ou estruturalmente ambíguas param com segurança, e panes sem composer com borda mantêm a classificação compatível por linha de cursor.
O classificador compartilhado aceita um glifo de shell como composer vazio de agente apenas dentro de um composer verificado com borda.
Um prompt de shell puro é `unknown`, então escalação do modo ausente nunca é injetada num shell morto.

O estado ocupado não é lido de texto renderizado neste backend.
O veredito busy, idle, unknown ou dead de uma tarefa vem do contrato semântico de busy-state de propriedade de `bin/sq-busy-lib.sh`; [architecture](../architecture.md#busy-state-is-semantic-per-adapter) é dona das fronteiras dele.
O único leitor restante de cauda renderizada é o fallback isolado do Grok dentro daquele contrato, que só consegue classificar uma tarefa Grok.
O reconhecimento de submit e o guard de painel-do-supervisor ocupado do modo ausente abaixo ainda consultam saída renderizada, mas apenas para decidir se input pode ser entregue, nunca para decidir estado registrado da tarefa.
O guard do supervisor seleciona apenas a assinatura do harness primário detectado em vez de uma união global de padrões de vendors.

`bin/sq-tmux-lib.sh` é dono da mecânica exata de digitar-e-enviar.
Ele digita uma mensagem uma vez e repete o Enter apenas até o composer liberar.
Só um composer provado vazio é um reconhecimento positivo de entrega.
Texto deixado em estrutura estabelecida permanece `pending`, texto em estrutura ambígua fica não provado, e estado ilegível ou inseguro permanece unknown.
O `sq-send.sh` reporta todo veredito não confirmado como falha em vez de redigitar ou assumir a entrega.

OpenCode 1.18.4 tem uma exceção de fila-ocupado.
Enquanto o OpenCode está no meio do turno, o Enter coloca a mensagem na fila mas deixa seu texto visível até o turno completar.
Depois do orçamento normal de retries, apenas texto estruturalmente provado pendente num pane provadamente ocupado é aceito como enfileirado, enquanto um pane ocioso continua `pending` como Enter genuinamente engolido.
Texto pendente ambíguo nunca recebe a conversão de fila-ocupado.
`tests/sq-tmux-submit-busy.test.sh` cobre panes ocupados e ociosos com composers provados, ambíguos e limpos.

## Limites e pontos de entrada de regressão

- O tmux é o caminho de referência e suporta bases XO.
- A exceção de fila-ocupado do OpenCode é específica do tmux; o Herdr mantém sua lacuna documentada separadamente.

```sh
tests/sq-backend-tmux-smoke.test.sh
tests/sq-tmux-agent-liveness.test.sh
tests/sq-harness-liveness-drift-live-e2e.test.sh
tests/sq-composer-ghost.test.sh
tests/sq-kimi-harness.test.sh
tests/sq-muse-harness.test.sh
tests/sq-tmux-submit-busy.test.sh
tests/sq-bootstrap.test.sh
```

[`verification/runtime-backends.md`](../verification/runtime-backends.md#tmux) registra a evidência ativa de foreground-process e submit.
