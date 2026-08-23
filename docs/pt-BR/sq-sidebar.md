<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Sidebar tmux do Squad (workmux)

A sidebar tmux do Squad é fornecida pelo workmux, um gerenciador de workspace tmux com integração Squad embutida, vendado neste repo sob `packages/operation-board/sidebar/` (MIT, upstream [raine/workmux](https://github.com/raine/workmux) via o fork Runecraft [runecraftai/workmux](https://github.com/runecraftai/workmux)).

## Como funciona

A sidebar do workmux lê dos arquivos ground-truth de estado do Squad:

- `state/window-states` - estado por janela do operador (publicado por `bin/sq-window-state.sh`)
- `state/<id>.meta` - metadados da tarefa (modelo, esforço, kind, projeto, worktree)
- `state/<id>.busy-gen` - mtime usado para exibição de tempo decorrido

A sidebar sempre usa tracking nativo do tmux para descobrir panes automaticamente.
Nenhuma variável de ambiente é necessária para habilitar a integração Squad; a sidebar lê
do diretório de estado do Squad quando `SQUAD_BASE` ou `SQUAD_HOME` está definido, mas isto
agora é comportamento padrão em vez de modo opt-in.

## Instalar

O binário da sidebar é compilado da fonte vendada neste repo, nunca instalado de repositório externo.
Compile uma vez com:

```bash
bin/sq-install-workmux-sidebar.sh
```

O script compila `packages/operation-board/sidebar` com `cargo build --release` e instala o binário no `target/release/workmux` daquela árvore, o caminho exato que o plugin tmux executa.
Ele exige toolchain Rust (`cargo`) e acesso à rede na primeira compilação para baixar crates.

`bin/sq-bootstrap.sh` detecta binário ausente em backends tmux e imprime `MISSING: workmux-sidebar (install: ...)` até ser compilado.
Aceite a oferta do bootstrap, ou rode o script acima, com consentimento do comandante; a compilação nunca é silenciosa.

## Carregar o plugin tmux

Adicione ao `~/.config/tmux/tmux.conf`:

```conf
run-shell "/caminho/para/squad/tmux/workmux-sidebar.tmux"
```

O plugin vincula `C-M-s` ao toggle da sidebar, e exige o binário vendado da sidebar compilado como descrito acima.

## Uso

| Tecla | Ação |
| --- | ------ |
| `C-M-s` | Alternar painel da sidebar (global em todas as janelas) |

A sidebar aparece automaticamente em toda janela tmux, e novas janelas ganham o painel via hooks do tmux.

## Mapeamento de dados

| Fonte Squad | Campo Workmux |
|-------------|---------------|
| `state/window-states` col 1 (window) | session + window_name, pane_id (alvo real `session:window`) |
| `state/window-states` col 2 (id) | id puro da tarefa (apenas lookups read_meta / read_busy_gen_mtime, não um alvo tmux) |
| `state/window-states` col 3 (label) | status (mapeado para AgentStatus) |
| `state/window-states` col 4-5 (state/detail) | pane_title |
| `state/<id>.meta` model + effort | agent_command |
| `state/<id>.meta` kind | agent_kind |
| `state/<id>.busy-gen` mtime | status_ts (tempo decorrido) |

## Mapeamento de status

| Rótulo Squad | Status Workmux | Exibição |
|-------------|----------------|---------|
| `working` | Working | spinner |
| `done` | Done | checkmark |
| `blocked` / `awaiting-decision` | Waiting | ícone de mensagem |
| `failed` | Done | cor de perigo |
| `idle` / outro | None | vazio |

## Configuração

A sidebar do Workmux pode ser configurada via `~/.workmux.yaml`:

```yaml
sidebar:
  position: left       # "left" or "top"
  width: 40            # columns, or "15%" for percentage
  layout: tiles        # "compact" or "tiles" (default)
```

## Ground truth

A sidebar é consumidora pura do contrato ground-truth do Squad.
`bin/sq-window-state.sh` é dono da tradução verbo-para-rótulo e publica em `state/window-states`.
A sidebar nunca lê telas.

O plugin tmux inicia um loop de publicação em segundo plano que chama `bin/sq-window-state.sh publish` a cada 2 segundos (substituindo o run loop da sidebar antiga, que era o único chamador).
O loop sai quando o servidor tmux morre.

Veja o cabeçalho de `bin/sq-window-state.sh` para o contrato de formato do arquivo.

## Limites

- A sidebar mostra apenas janelas de tarefa do backend tmux; tarefas orca, herdr, zellij, cmux e XO não têm janela tmux para mostrar.
- A sidebar lê do diretório de estado do Squad; ela não escreve de volta ao Squad.

## Ponto de entrada de regressão

Os testes da fonte de dados Squad do workmux vendado cobrem a integração:

```bash
cd packages/operation-board/sidebar
cargo test squad
```

## Veja também

- [README do workmux vendado](../../packages/operation-board/sidebar/README.md) - documentação completa da sidebar
- [workmux upstream](https://github.com/raine/workmux) - projeto original
- [bin/sq-window-state.sh](../../bin/sq-window-state.sh) - publicador ground-truth
- [docs/tmux-backend.md](../tmux-backend.md) - documentação do backend tmux
