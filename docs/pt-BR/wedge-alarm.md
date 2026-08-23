<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Alarme de travamento de injeção do modo ausente

O sub-supervisor do modo ausente (`bin/sq-supervise-daemon.sh`) armazena escalações em buffer e as injeta no próprio painel do Squad.
Quando a injeção não consegue confirmar um envio após `SQUAD_MAX_DEFER_SECS`, a `inject_wedge_alarm` dispara um alarme ruidoso e com taxa limitada para que a parada nunca fique invisível.
O alerta ativo é independente de painel porque um flash na status line do tmux não tem equivalente entre backends e não alcança um comandante ausente de forma confiável.
O marcador durável e o flash no tmux permanecem como sinais adicionais.

## Canais

O `config/wedge-alarm` é local e gitignored.
Ele lista diretivas de canal, uma por linha não vazia e não comentário, e todo canal listado diferente de `off` dispara em melhor esforço.
`SQUAD_WEDGE_ALARM_CHANNEL` sobrepõe o arquivo com uma diretiva para testes focados.

- `off` desativa todo alerta ativo mantendo o marcador durável e o flash no tmux.
- `auto` ou `default` resolve para `osascript` no macOS.
  Outras plataformas não têm canal nativo do sistema operacional, então configure `command:` quando só o marcador durável não for suficiente.
- `osascript` posta um banner no Notification Center do macOS fora do painel do terminal.
- `herdr` chama `herdr notification show` fora do painel supervisionado.
- `command:<cmd>` roda `<cmd>` via `sh -c` com o resumo do alarme como `$1` e no stdin, permitindo entrega para um celular ou serviço de pager.

Um `config/wedge-alarm` ausente se comporta como `auto`, que é padrão ligado no macOS.
Isso é deliberado porque o alarme dispara apenas depois de uma trava real de max-defer e tem taxa limitada a no máximo uma vez por janela de max-defer.

Cada canal é de melhor esforço.
Um binário ausente ou exit não zero registra um warning e segue para o próximo canal sem derrubar o loop do daemon.
Toda invocação é limitada por grupo de processo por `SQUAD_WEDGE_ALARM_TIMEOUT_SECS`, que tem padrão de 10 segundos, incluindo `command:`, `osascript`, `herdr` e o seam de teste.
Em timeout ou desligamento do daemon, o grupo de processos do notificador é terminado e o próximo canal configurado pode rodar.
O AppleScript recebe o resumo como um item de argv em vez de fonte interpolada, então texto do resumo não pode alterar o script.
Veja [`examples/wedge-alarm`](../examples/wedge-alarm) para uma config copiável.

## Segurança de teste

Todo notificador passa por `SQUAD_WEDGE_ALARM_EXEC` na `wedge_alarm_emit`.
Quando o daemon é carregado (source) como biblioteca, esse seam tem padrão `discard`, então um teste não pode acidentalmente postar uma notificação real.
O `tests/stand-to-helpers.sh` substitui o seam por um gravador quando uma suíte precisa afirmar seleção de canal e propagação do resumo.
A produção deixa o seam indefinido e usa os canais reais configurados.

O `tests/sq-daemon.test.sh` cobre parsing de diretivas, taxa limite, timeout e limpeza de grupo de processo, despacho seguro via argv, fallback de canal e entrega segura de resumo via `command:`.
[`verification/supervision.md`](../verification/supervision.md#wedge-alarm-channels) registra a prova manual limitada dos canais macOS e Herdr.
