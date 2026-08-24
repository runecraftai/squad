<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Backend de runtime cmux

O cmux é um backend experimental macOS GUI de terminal.
Ele fornece workspaces e superfícies de tarefa enquanto o FOB continua fornecendo git worktrees.
[`configuration.md`](configuration.md#backend-de-runtime-configbackend--squad_backend) é dona da semântica compartilhada de seleção e metadados.

## Setup

Escolha o cmux quando você já usa o app como terminal e quer workspaces de tarefa na sidebar dele.
O cmux é exclusivo de macOS, primeiro GUI, e inadequado para sessão Squad headless ou apenas-SSH.

Pré-requisitos:

- cmux 0.64 ou mais novo, instalado de [cmux.com](https://cmux.com) ou com `brew install --cask cmux`.
- `jq` para respostas JSON.
- Os requisitos universais de harness e toolchain em [`configuration.md`](configuration.md#toolchain).

A CLI nem sempre está instalada no `PATH` junto ao app.
O adaptador prefere `command -v cmux` e caso contrário usa `/Applications/cmux.app/Contents/Resources/bin/cmux`.

### Acesso a socket exigido

O cmux usa por padrão um modo de controle que rejeita shells externos, enquanto o Squad sempre o controla de um processo externo.
Abra Settings > Automation e escolha um modo viável de Socket Control antes do primeiro spawn com cmux.

| Setting | Valor | Suporte do Squad | Fronteira de segurança |
| --- | --- | --- | --- |
| Off | `off` | Não | O listener de socket está desabilitado. |
| cmux processes only | `cmuxOnly` | Não | Apenas descendentes do app cmux podem conectar. |
| Automation mode | `automation` | Sim, recomendado | O socket 0600 de só-dono admite processos do usuário macOS atual. |
| Password mode | `password` | Sim | O socket 0600 também exige handshake de autenticação. |
| Full open access | `allowAll` | Sim, não recomendado | O socket 0666 admite todo usuário local sem autenticação. |

O automation mode é a fronteira recomendada de mesmo-usuário.
`allowAll` pode executar comandos através de socket de controle world-writable e deve ser selecionado apenas como tradeoff de segurança explícito.

Para o Password mode, armazene a senha como a primeira linha do arquivo local gitignored `config/cmux-socket-password` ou forneça `CMUX_SOCKET_PASSWORD` no ambiente do Squad.
O adaptador lê o arquivo fresco do diretório de config efetivo e não sobrescreve uma senha ambiente quando o arquivo está ausente.
Configure o modo e a senha pela UI do cmux em vez de editar `cmux.json`; o app não retém uma chave de senha adicionada à mão, e reload baseado em socket não consegue consertar um socket que está rejeitando o chamador.

Selecione o cmux com o `config/backend` local contendo `cmux`, `SQUAD_BACKEND=cmux` para um único lançamento, ou um pedido explícito ao Squad.
Ele também pode ser auto-detectado pelo runtime quando o próprio Squad roda dentro do cmux.
Um spawn para com uma mensagem acionável de setup quando o app, versão mínima, `jq`, acesso a socket ou senha estão indisponíveis.
O adaptador pode lançar o app com `open -a cmux` apenas quando o socket está down; ele não relança o app para erros de acesso-negado ou autenticação.

A supervisão rotineira usa `bin/sq-peek.sh <id>` e `SQUAD_BASE=<home> bin/sq-send.sh <id> '<texto>'` sem trazer a janela cmux para frente.
Criação de workspace e superfície de tarefa usam `focus=false`.

Verifique o setup spawnando uma tarefa pequena e confirmando que os metadados contêm `backend=cmux`, `cmux_workspace_id=` e `cmux_surface_id=`.

## Detecção de runtime

`CMUX_WORKSPACE_ID` é o principal marcador de runtime do cmux.
`CMUX_SOCKET_PATH` não é suficiente porque operadores podem defini-lo fora do cmux.
A detecção confere tmux primeiro, depois Herdr, depois cmux, então um multiplexador aninhado dentro do cmux permanece o backend ativo.

O wrapper Claude embarcado do cmux pode remover toda variável `CMUX_*` quando sua sonda interna de socket falha, incluindo no Password mode.
Apenas no macOS, a detecção portanto recua primeiro para `__CFBundleIdentifier=com.cmuxterm.app`, depois para ancestralidade de processo alcançando o app cmux rodando.
Esses fallbacks são consultados apenas quando nem tmux nem Herdr já ganharam.
Um processo com ambiente sanitizado ou relançado pelo launchd sem marcador confiável não é auto-detectado.

A auto-detecção seleciona apenas o backend.
Ela nunca muda acesso a socket nem concede credenciais.
A recusa de spawn explica como completar o setup cmux ou optar de volta pelo tmux.

## Formato de tarefa e metadados

Cada tarefa tem um workspace cmux com uma superfície.
O rótulo voltado ao chamador continua `sq-<id>`, enquanto o título visível do workspace é `sq-<rótulo-da-home>-<id>`.
O rótulo da base é `Squad` ou `xo-<id>` mais um hash curto estável da raiz Squad resolvida.
O cmux não impõe unicidade de título, então caminhos de create, recovery, list e cleanup validam este título com escopo.
Mover a instalação do Squad muda o hash e deixa títulos antigos sem correspondência, consistente com caminhos de worktree registrados também ficando obsoletos.

```text
backend=cmux
window=<workspace-uuid>:<surface-uuid>
cmux_workspace_id=<workspace-uuid>
cmux_surface_id=<surface-uuid>
```

O par UUID é a autoridade do endpoint ativo dentro de uma execução do app.
UUIDs de workspace não são estáveis entre relançamentos do app, então recovery busca pelo título com escopo e depois resolve o id de superfície atual.

## Operação e segurança atuais

Uma superfície genuinamente nova retorna um erro interno de `read-screen` até que algo tenha sido escrito.
Prontidão do alvo portanto usa a resposta estrutural `list-panes` em vez de leitura de conteúdo.
Captura permanece limitada e trimada localmente depois que `read-screen` fica disponível.

`current_directory` segue um `cd` de shell no nível superior mas não o subshell em primeiro plano aberto pelo `fob get`.
Descoberta de worktree no momento de spawn envia marcadores de início e fim ao redor do `pwd`, captura o bloco marcado e junta linhas de caminho quebradas.

Send literal e Enter são chamadas separadas.
Enter, Escape e Ctrl-C são suportados.
O verificador de composer localiza a última linha de composer com borda e delega a decisão de conteúdo para `bin/sq-composer-lib.sh`.
Um prompt de shell puro é `unknown`, e um placeholder de popup de slash permanece `pending`, então apenas Enter é retentado e texto nunca é redigitado.
O cmux não expõe nenhum sinal nativo genérico de ocupado do agente, então a supervisão usa polling capture/hash para mudanças de tela e o ciclo de vida semântico de cada adaptador de harness para estado do worker.
Apenas o Grok mantém seu fallback isolado de cauda renderizada.

O último workspace de uma tarefa não pode ser fechado diretamente.
O cleanup controla o workspace inteiro e usa `close-workspace`.
O cmux também recusa remover o único workspace numa janela macOS devolvendo uma resposta de sucesso enganosa.
Quando a tarefa é a última na janela, o Squad cria um workspace irmão sem foco e sem nome na mesma janela, fecha o workspace da tarefa e deixa a janela com o workspace padrão novo do cmux.
O irmão nunca carrega título `sq-` e é ignorado pelo recovery.

A pertença exata à janela é relida antes desta operação.
Um workspace selecionado que não é o último fecha normalmente; a seleção em si não é o gatilho.
O Squad não tenta fechar a janela macOS porque o socket do cmux não consegue fechar uma janela segurando um terminal vivo.

Testes reais compartilham o app rodando do comandante em vez de criar uma sessão cmux isolada.
`tests/cmux-test-safety.sh` permite cleanup apenas para um workspace `sq-test-` listado atualmente exato e nunca enumera e fecha workspaces não relacionados ou relança o app.

## Limites ativos

- O cmux é experimental, exclusivo de macOS, primeiro GUI, e requer o app rodando.
- Acesso a socket exige mudança manual one-time em Settings.
- Spawns de XO não são suportados até que um design de ciclo de vida por base seja verificado.
- Não há sinal nativo de ocupado ou push-event.
- Um alvo pode desaparecer depois de prontidão estrutural e antes da operação.
- O caminho de cleanup de único-workspace deixa um workspace padrão novo e não consegue fechar a janela.
- Lookup por rótulo e recovery estão atualmente limitados à janela cmux atual, então uma tarefa movida para uma janela não-atual é um ponto cego conhecido de recovery.
- IDs de workspace não sobrevivem a relançamento do app e nunca são autoridade de recovery.

## Pontos de entrada de regressão

```sh
tests/sq-backend-cmux.test.sh
tests/sq-backend-cmux-smoke.test.sh
```

[`verification/runtime-backends.md`](../verification/runtime-backends.md#cmux) registra a fonte ativa e evidência ao vivo, incluindo modos de socket e cleanup last-in-window.
