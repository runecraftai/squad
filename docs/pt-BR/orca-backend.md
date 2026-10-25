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
- Os requisitos universais de harness e toolchain em [`configuration.md`](configuration.md#toolchain).

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
Para alvos não-Pi, ou quando a entrega nativa do Pi está indisponível, o `sq-send.sh` digita e verifica a liberação do composer, segue o `oldestCursor` quando o Orca devolve uma página limitada, e repete o Enter sem redigitar quando um popup de slash primeiro preenche um placeholder de argumento.
Uma linha de shell puro é `unknown`, não um composer vazio do agente.
Operadores Pi lançados a partir de um brief posicional completam seu turno e saem para o shell em vez de ficarem ociosos num composer, então no Linux eles nunca renderizam a linha de composer com borda contra a qual o classificador de clearance verifica.
Quando a entrega nativa do Pi está indisponível, um steer enviado enquanto tal operador está no meio do turno é entregue e colocado na fila - verificado ao vivo na v1.4.188, o terminal mostra a mensagem na fila e o operador depois age sobre ela - mas a verificação ainda devolve `unknown` e o `sq-send.sh` sai reportando entrega não confirmada.
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

## Supervisão de away-mode

Um primário hospedado no Orca é explicit-only: inicie o primário com `SQUAD_SUPERVISOR_BACKEND=orca` e `SQUAD_SUPERVISOR_TARGET=<handle exato de terminal emitido pelo runtime>` já definidos.
O alvo precisa ser um terminal local conectado, gravável e não órfão cujo caminho de worktree seja o diretório físico `SQUAD_BASE`.
Essa seleção é independente de `config/backend`; mudar o posicionamento de tarefas não é exigido.
Não selecione uma aba ativa por nome, não anexe outro multiplexador como evidência de suporte mobile nativo e não inferira um primário do terminal do operador.

Apenas o receptor interativo **Pi** é habilitado inicialmente.
`pi-signed`, Claude, Codex, OpenCode, Grok, Kimi, Muse e harnesses desconhecidos são recusados pelo nome antes que qualquer estado de away-mode ou endpoint seja criado, porque a segurança de rascunho/modal nativo e o reconhecimento de mensagem consumida deles não foram comprovados para esta integração.
Carregue o `.pi/extensions/sq-primary-away-handoff.ts` distribuído no primário selecionado e deixe aquele primário adquirir a posse de sessão da base antes de entrar no away-mode.
Um registro de prontidão ausente, obsoleto, de processo estranho, de endpoint estranho ou de encarnação substituída recusa em vez de cair na digitação no terminal.
Um shell puro não consegue publicar prontidão nativa.

Use `bin/sq-afk-launch.sh start`, `status`, `stop` e `reconcile` para o ciclo de vida.
O Orca cria uma **aba de terminal sem foco**, não um terminal oculto; ele não divide nem foca o primário, não cria worktree, não deleta worktree e não para o runtime.
A intenção de criação é gravada antes da chamada da CLI, e a limpeza exige o handle exato do terminal, a encarnação do runtime e do terminal, a identidade/caminho do worktree e o título único.
Um processo de daemon vivo precisa ainda corresponder ao token de lançamento gravado e à identidade de processo do sistema operacional antes de poder ser sinalizado.
Criação incerta permanece gravada e bloqueia outra criação; a reconciliação pode recuperar somente o endpoint exato e unicamente titulado, nunca varrer outros terminais.
Alvos Orca remotos são recusados porque a prova local de posse do receptor/processo não se aplica a um host remoto.

O protocolo nativo em `bin/sq-supervisor-native.sh` vincula requisições e reconhecimentos de consumo a um objeto de endpoint neutro de backend, à identidade do processo receptor e a um nonce de sessão do receptor.
O receptor Pi em `.pi/extensions/lib/sq-away-native.ts` verifica o estado real de ociosidade, de rascunho no editor e de modal aberto antes de chamar a API de mensagem suportada.
Adicionar outro harness exige seu próprio receptor nativo igualmente comprovado, não outro dono de tarefa nem um redesenho da forma do endpoint.
Publicação, mensagens enfileiradas, envios ambíguos, morte de processo, substituição de sessão do receptor e reconexões nunca são tratados como consumo nem como permissão de replay.
Apenas um reconhecimento exato de consumo retira o prefixo de buffer coberto; uma requisição não resolvida permanece não resolvida, inclusive entre reinicializações.
Isso prioriza deliberadamente evitar efeitos duplicados em vez de recuperação automática: o stop reporta falha e preserva o estado do ciclo de vida enquanto a entrega ou a limpeza do endpoint é incerta.
Inspecione e reconcilie essa evidência antes de tentar de novo; não delete a requisição para forçar um reenvio.

A verificação é dividida explicitamente: o Orca no Linux **1.4.188** forneceu o schema somente-leitura de identidade de runtime/terminal; o **Pi 1.1.0** interativo forneceu prova real de editor/modal e de consumo nativo em um PTY isolado com uma **CLI de identidade Orca falsa**.
Nenhum ciclo de vida real combinado Orca + Pi supervisor/AFK, supervisor no macOS, elegibilidade de Chat UI ou aceitação física no Android é alegado por essas checagens separadas.
O host instalado tem terminais compartilhados ativos, e suas opções documentadas de `serve` não provam uma fronteira separada de dados de usuário/perfil; outra porta ou raiz de projeto sozinha não é isolamento.
Uma sonda real descartável no host exige, portanto, um perfil/runtime Orca comprovadamente independente antes do lançamento, sem reiniciar ou reconfigurar o host compartilhado.
[`verification/runtime-backends.md`](../verification/runtime-backends.md#orca) registra os comandos exatos de atualização e os limites de evidência.

## Limites ativos

- O Orca é explicit-only no macOS e Linux.
- O runtime Orca precisa reportar pronto: o app desktop no macOS, ou `orca serve` no Linux.
- Spawns de XO não são suportados.
- Escape não é suportado.
- O Orca expõe nenhum marcador estável de versão de CLI ou protocolo, então a prontidão é o gate de compatibilidade em vez de um piso de versão.
- Apenas os campos verificados de resultado de terminal-handle e worktree são aceitos; formatos especulativos de resposta são rejeitados.
- Expiração de busy não pode ser avaliada: a leitura completa da viewport não foi verificada, então uma declaração busy estática registra uma limitação nominal e nunca escala a partir de uma cauda ([arquitetura](architecture.md)).

## Pontos de entrada de regressão

```sh
tests/sq-backend-orca.test.sh
tests/sq-afk-orca.test.sh
tests/sq-afk-orca-live-optin.test.sh
tests/sq-backend.test.sh
tests/sq-bootstrap.test.sh
```

[`verification/runtime-backends.md`](../verification/runtime-backends.md#orca) registra o smoke real de prontidão e formato de resposta.
