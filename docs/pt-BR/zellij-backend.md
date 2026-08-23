<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Backend de runtime Zellij

O Zellij é um backend experimental explicit-only de sessão.
Ele fornece a sessão de terminal enquanto o FOB continua fornecendo os worktrees das tarefas.
[`configuration.md`](configuration.md#runtime-backend-configbackend--squad_backend) é dona da semântica compartilhada de seleção e metadados.

## Setup

Escolha o Zellij quando você já o usa como multiplexador de terminal e aceita seus limites atuais de foco, vitalidade e polling.

Pré-requisitos:

- Zellij 0.44 ou mais novo.
- `jq` para respostas JSON.
- Os requisitos universais de harness e toolchain em [`configuration.md`](configuration.md#toolchain).

Selecione-o com o `config/backend` local contendo `zellij`, `SQUAD_BACKEND=zellij` para um único lançamento, ou um pedido explícito ao Squad.
Ele nunca é auto-detectado.
Um spawn para antes de criar uma sessão ou adquirir um worktree quando o Zellij ou `jq` está ausente ou o Zellij está abaixo da 0.44.

O Squad usa uma sessão compartilhada chamada `Squad` por padrão.
`SQUAD_ZELLIJ_SESSION` pode selecionar outro nome para verificação isolada.
Anexe-se com:

```sh
zellij attach <nome-da-sessao>
```

A supervisão rotineira não exige attach.
Use `bin/sq-peek.sh <id>` e `SQUAD_BASE=<home> bin/sq-send.sh <id> '<texto>'` contra o endpoint roteado pelos metadados.

Verifique o setup spawnando uma tarefa pequena e confirmando que os metadados contêm `backend=zellij`, `zellij_session=`, `zellij_tab_id=` e `zellij_pane_id=`.

## Formato de tarefa e isolamento de base

Toda tarefa recebe uma aba na sessão compartilhada do Zellij.
O rótulo voltado ao chamador continua `sq-<id>`, enquanto o título visível tem escopo de base como `sq-<rótulo-da-home>-<id>`.
O rótulo da base é `Squad` ou `xo-<id>` mais um hash curto e estável da raiz Squad resolvida.
Isso previne colisões de task-id entre um primário, XOs e instalações separadas do Squad compartilhando uma mesma sessão.

O Zellij não impõe unicidade de nome de aba, então o adaptador faz sua própria checagem de duplicata contra o título com escopo.
Os caminhos de create, recover, list e cleanup usam todos o mesmo dono de título com escopo em `bin/sq-backend-hometag-lib.sh`.
Mover uma instalação do Squad muda seu hash de caminho e deixa títulos antigos sem correspondência, consistente com os caminhos de worktree também ficando obsoletos depois de uma mudança.

Uma tarefa anterior à tag de base permanece alcançável pelos metadados registrados apenas quando exatamente uma aba viva tem o título antigo sem escopo.
Múltiplas abas antigas com o mesmo título causam uma recusa em vez de um palpite.
A recuperação em massa nunca adota abas legadas sem escopo porque não tem identidade segura de base para elas.

```text
backend=zellij
window=<sessão>:<pane-id>
zellij_session=<sessão>
zellij_tab_id=<tab-id>
zellij_pane_id=<pane-id>
```

Ids de pane registrados são numéricos e nunca são confiáveis sozinhos após uma recriação de sessão.
Operações roteadas por metadados também verificam o título esperado - com escopo ou legado não ambíguo - da aba dona.
Um alvo bruto explícito `session:pane` permanece uma válvula de escape do operador que só confere existência do pane.

## Operação e segurança atuais

Os comandos de ação da CLI do Zellij devolvem exit 0 mesmo para sessões ou panes ausentes.
O adaptador portanto verifica sessão, pane de terminal e título esperado antes de uma operação e valida formatos de resposta JSON ou inteiro depois.
Um pane ainda pode desaparecer entre a verificação e a operação; o submit downstream, descoberta de worktree e detecção de obsolescência reportam essa corrida estreita em vez de tratar exit 0 como sucesso.

Toda operação de pane passa um `--pane-id` explícito porque uma nova sessão pode focar seu pane do plugin de release notes, cujo id numérico de plugin está em um namespace separado dos ids de pane de terminal.

`pane_cwd` segue um `cd` de shell no nível superior mas não o subshell em primeiro plano aberto pelo `fob get`.
A descoberta de worktree então envia marcadores de início e fim ao redor do `pwd`, captura o bloco marcado e junta linhas de caminho quebradas.
Essa sonda ativa tem escopo na descoberta de worktree no momento do spawn e não é anunciada como uma API geral de cwd ao vivo.

`new-tab` não tem flag de no-focus e foca temporariamente a aba criada nos clientes anexados.
O adaptador registra a aba ativa anterior e imediatamente a restaura com `go-to-tab-by-id`.
Existe uma corrida visível estreita entre essas chamadas que nenhuma flag atual do Zellij consegue remover.

Envio literal usa bracketed paste seguido de um Enter explícito separado.
O adaptador suporta `Enter`, `Esc` e a expressão de tecla de um argumento `Ctrl c` pelo vocabulário compartilhado de teclas.
O Zellij expõe nenhum sinal nativo de linha de cursor, estilo de composer ANSI ou estado do agente, então o reconhecimento de submit continua baseado em delta de conteúdo.
Isso distingue nenhuma mudança de tela alterada, mas é menos preciso que o leitor estrutural de caixas do tmux ou o estado nativo do Herdr mais classificador estrutural.

A captura de viewport não tem opção de limite de linhas.
Leituras rotineiras usam `dump-screen` e peeks maiores usam `dump-screen --full`, seguidos de trim local.
Um viewport curto pode expor menos linhas que as pedidas.

Fechar um pane deixa uma aba vazia.
A limpeza resolve e verifica a aba dona e então usa `close-tab-by-id` para que tanto o pane da tarefa quanto a aba desapareçam.
A limpeza real de testes usa apenas uma sessão isolada diferente de `Squad` e o guard em `tests/zellij-test-safety.sh`; ela nunca chama comandos de deleção de todas as sessões.

## Limites ativos

- O Zellij é experimental e explicit-only.
- Todas as bases compartilham uma sessão e barra de abas; títulos com escopo previnem colisões de identidade entre bases mas não criam contêineres visuais por base.
- Não há sinal nativo de ocupado ou push-event, então a supervisão usa polling de captura/hash para mudanças de tela e o ciclo de vida semântico de cada adaptador de harness para o estado do worker.
  Apenas o Grok mantém seu fallback isolado de cauda renderizada.
- Não há sinal verificado de vitalidade do processo do agente, então um XO Zellij morto é reportado como inconclusivo em vez de auto-respawned.
- A restauração de foco no new-tab tem uma corrida visível estreita.
- O status de saída da CLI não é significativo; um alvo pode desaparecer depois das checagens estruturais de prontidão.
- A descoberta de cwd de worktree exige a sonda de marcadores no momento do spawn.
- Um título legado ambíguo sem escopo exige limpeza manual e respawn.

## Pontos de entrada de regressão

```sh
tests/sq-backend-zellij.test.sh
tests/sq-backend-zellij-smoke.test.sh
```

O teste de smoke real usa uma sessão única e deleção protegida.
[`verification/runtime-backends.md`](../verification/runtime-backends.md#zellij) registra a matriz ativa de CLI e evidência de ciclo de vida.
