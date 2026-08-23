<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Backend de runtime Orca

O Orca é um backend experimental no macOS e Linux em que o app Orca controla tanto o worktree da tarefa quanto o endpoint de terminal.
O harness do operador continua sendo o processo de agente lançado dentro desse endpoint.
Os agentes do Squad carregam [`squad-orca`](../../.agents/skills/squad-orca/SKILL.md) antes de operar ou recuperar este backend.

## Setup

Escolha o Orca quando você já usa o app Orca e quer worktrees e terminais gerenciados pelo Orca em vez de FOB mais um multiplexador de sessão.
O Orca roda no macOS e Linux, é explicit-only, e não suporta spawns de XO.

Pré-requisitos:

- macOS: `/Applications/Orca.app` instalado, rodando e pronto, com a CLI instalada via `brew install orca`.
- Linux: o asset de release do Orca instalado (`orca-linux.AppImage`, ou `orca-ide_<versão>_amd64.deb`) com uma CLI `orca` no PATH - seja um symlink para o AppImage (por exemplo `~/.local/bin/orca -> orca-linux.AppImage`) ou o binário nativo `orca-ide` que o `orca serve` auto-instala.
- Runtime Linux: inicie o runtime headless suportado com `orca serve` (por exemplo `orca serve --port 6768 --json`) em vez de abrir o app desktop; um processo `serve` pronto satisfaz exatamente o mesmo gate de prontidão abaixo.
- Os requisitos universais de harness e toolchain em [`configuration.md`](../configuration.md#toolchain).

Selecione o Orca com o `config/backend` local contendo `orca`, `SQUAD_BACKEND=orca` para um único lançamento, ou um pedido explícito ao Squad.
Ele nunca é auto-detectado.

Antes que qualquer spawn mute o estado do repositório, o Squad exige que `orca status --json` reporte `reachable=true` e `state="ready"`.
A primeira tarefa de um projeto registra aquele repositório com `orca repo add --path` quando necessário.
Nenhum registro manual de repositório é exigido.

Abra o app Orca para assistir ao terminal de uma tarefa.
A supervisão rotineira usa o endpoint registrado via `bin/sq-peek.sh <id>` e `SQUAD_BASE=<home> bin/sq-send.sh <id> '<texto>'`.
Enter e Ctrl-C são suportados; Escape não é.

## Formato de tarefa e metadados

Cada tarefa tem um worktree git gerenciado pelo Orca e um terminal Orca.
O `sq-spawn.sh` não chama o FOB para tarefas Orca.
As regras normais de isolamento e recusa de trabalho não-landado continuam valendo.

```text
backend=orca
window=sq-<id>
terminal=<handle do terminal orca>
orca_worktree_id=<id do worktree orca>
worktree=<caminho absoluto do worktree Orca>
```

`window=` permanece o alias do Squad voltado ao chamador.
`terminal=` e `orca_worktree_id=` são a autoridade do backend usada pelos caminhos de operação e limpeza.
Em builds macOS o `orca_worktree_id=` registra um átomo simples (UUID).
Em builds Linux (verificado contra v1.4.188) ele registra a forma composta `<repo-id>::<caminho-absoluto>`, que a limpeza aceita junto da forma simples e valida estruturalmente.

## Ciclo de vida e segurança atuais

O spawn registra o repositório, cria um worktree independente, reutiliza apenas o `result.terminal.handle` verificado devolvido pelo Orca ou cria um terminal explicitamente, instala os hooks do harness, grava metadados e lança o harness selecionado.
Flags exatas de comando e parsing de resposta são de propriedade do `bin/backends/orca.sh` e do help do script.

O `sq-peek.sh` lê com `orca terminal read`.
O `sq-send.sh` digita e verifica a liberação do composer, segue o `oldestCursor` quando o Orca devolve uma página limitada, e repete o Enter sem redigitar quando um popup de slash primeiro preenche um placeholder de argumento.
Uma linha de shell puro é `unknown`, não um composer vazio do agente.
Operadores pi lançados a partir de um brief posicional completam seu turno e saem para o shell em vez de ficarem ociosos num composer, então no Linux eles nunca renderizam a linha de composer com borda contra a qual o classificador de clearance verifica.
Um steer enviado enquanto tal operador está no meio do turno é entregue e colocado na fila - verificado ao vivo na v1.4.188, o terminal mostra a mensagem na fila e o operador depois age sobre ela - mas a verificação ainda devolve `unknown` e o `sq-send.sh` sai reportando entrega não confirmada.
Esse veredito fica genuinamente não confirmado nos dois casos: dê peek no terminal antes de agir sobre ele, e nunca reenvie às cegas, porque o mesmo `unknown` também cobre texto estacionado no prompt de shell puro de um operador que já saiu.
A sentinela não tem sinal nativo de ocupado do Orca, então o ciclo de vida semântico de cada adaptador de harness fornece o estado do worker.
Apenas o Grok mantém seu fallback isolado de cauda renderizada.

A limpeza mantém todas as checagens compartilhadas de segurança do Squad.
Um recon ainda exige seu relatório e inventário completo de decisões.
Um ship ainda recusa trabalho sujo ou não-landado.
Antes do release, a limpeza resolve o id de worktree Orca registrado e verifica se o caminho dele bate com o caminho de worktree registrado.
Uma identidade ausente, ilegível ou divergente preserva os metadados e para em vez de deletar qualquer coisa.
Depois dessas checagens, o Squad fecha o terminal exato e libera o worktree exato com o comando de worktree do Orca.
Ele nunca faz raw-delete de um worktree do Orca.

## Limites ativos

- O Orca é explicit-only no macOS e Linux.
- O runtime Orca precisa reportar pronto: o app desktop no macOS, ou `orca serve` no Linux.
- Spawns de XO não são suportados.
- Escape não é suportado.
- O Orca expõe nenhum marcador estável de versão de CLI ou protocolo, então a prontidão é o gate de compatibilidade em vez de um piso de versão.
- Apenas os campos verificados de resultado de terminal-handle e worktree são aceitos; formatos especulativos de resposta são rejeitados.

## Pontos de entrada de regressão

```sh
tests/sq-backend-orca.test.sh
tests/sq-backend.test.sh
tests/sq-bootstrap.test.sh
```

[`verification/runtime-backends.md`](../verification/runtime-backends.md#orca) registra o smoke real de prontidão e formato de resposta.
