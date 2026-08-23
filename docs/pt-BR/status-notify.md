<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Notificações de status no desktop (sq-status-notify)

O `bin/sq-status-notify.sh` posta uma notificação de desktop (notify-send, em Linux/mako) quando um operador appenda um evento de acordar `done:`, `needs-decision:`, `blocked:` ou `failed:` em `state/<id>.status`.
Ele espelha o comportamento de notificação "blocked/done" do herdr para operadores rodando em painéis tmux, para que o comandante não precise ficar de olho em cada janela de tarefa.

O cabeçalho do script é dono da referência completa de comando, ambiente e comportamento.
Esta página cobre setup e o contrato operacional.

## Requisitos

- notify-send da libnotify (o daemon de notificações é o mako ou qualquer outro servidor compatível com notify-send).
- tmux, o backend de runtime que hospeda as janelas dos operadores que a notificação foca.

## Instalar e rodar

O script roda in-place a partir do repo, então não há passo de build.
Para um serviço por usuário, aponte uma user unit do systemd para a cópia no repo e deixe-a comandar o subcomando `watch`:

```ini
[Unit]
Description=Squad operator status notifications (tmux -> mako)
After=graphical-session.target

[Service]
Type=simple
ExecStart=/home/voce/squad/bin/sq-status-notify.sh watch /home/voce/squad
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
```

O argumento BASE do `watch` é opcional; quando omitido, o script resolve `$SQUAD_BASE`, depois o legado `$SQUAD_HOME`, depois a raiz deste repo.
Uma base fora do layout padrão passa o caminho explicitamente, como na unit acima.
Ative o serviço com `systemctl --user enable --now sq-status-notify.service` e confira com `journalctl --user -u sq-status-notify.service`.
Cada notificação também registra `notify: <título>` no stderr, então o journal da unit mostra toda notificação que o watcher postou.

## O que notifica

Apenas linhas `done`, `needs-decision`, `blocked` e `failed` notificam por padrão, com título distinto por verbo.
Um arquivo de status visto pela primeira vez, ou seu histórico pré-existente, nunca notifica; apenas novas linhas appendadas depois do baseline disparam.
Arquivos de status truncados ou rotacionados resetam o offset sem re-notificar o histórico.
Sobreponha o conjunto de verbos com `SQ_NOTIFY_VERBS` (por exemplo `done blocked`) e o intervalo de polling com `SQ_NOTIFY_POLL` em segundos (padrão 5).
Uma notificação `done` (e qualquer outro verbo notificado) fica visível por 15 segundos; notificações `needs-decision`, `blocked` e `failed` persistem até serem dispensadas (notify-send -t 0).

## Foco e supressão

Uma notificação para um operador cujo meta registra `window=` carrega uma ação de clique que seleciona aquela janela do tmux.
Clicar no corpo foca o painel do operador; o handler de clique faz fork por notificação para que o watcher nunca bloqueie num popup não confirmado.
Quando a janela do operador já é a janela em foco, a notificação é suprimida completamente (supressão de aba ativa estilo herdr).

## Canal opcional de status line do tmux

Defina `SQ_NOTIFY_TMUX=1` para também dar flash de cada notificação no terminal do operador, além do popup de desktop.
O watcher roda `tmux display-message` na janela registrada do operador, ou na status line do cliente chamador quando nenhuma janela está registrada.
O canal é de melhor esforço: falha silenciosamente quando o tmux não está disponível ou a janela alvo se foi, e a supressão de janela-em-foco acima também vale para ele.
A ação de foco tmux na notificação de desktop não é afetada.

## Limites

- Apenas Linux/notify-send; particularidades do macOS estão fora do escopo.
- notify-send é de melhor esforço: quando falta, o watcher imprime um único warning no stderr e continua fazendo polling em vez de morrer.
- Os offsets de notificação por base vivem sob `$XDG_STATE_HOME/sq-status-notify/` (padrão `~/.local/state/sq-status-notify/`), um subdiretório por base; deletar esse diretório re-baselineia todo arquivo de status sem notificar o histórico.

## Ponto de entrada de regressão

```sh
tests/sq-status-notify.test.sh
```
