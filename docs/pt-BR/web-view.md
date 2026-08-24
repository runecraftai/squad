<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Dashboard web (sq-web-view)

O `bin/sq-web-view.sh` serve ou renderiza um dashboard web somente leitura do estado dos operadores de uma base Squad: um card por operador com a classificação ao vivo de ocupado, o último evento de acordar, a janela, o projeto e o log de status completo.
É o equivalente mantido mais próximo do dashboard web do herdr para operadores rodando em painéis tmux, visualizável de outra máquina ou celular na LAN.

O cabeçalho do script é dono da referência completa de comando, ambiente e comportamento.
Esta página cobre setup e o contrato operacional.

## Rodar

```sh
bin/sq-web-view.sh serve
```

O subcomando `serve` roda um pequeno servidor HTTP sem framework em primeiro plano (apenas biblioteca padrão do Python 3) que re-renderiza a página a cada request, então a página está sempre atualizada.
Ctrl-C o para; não há daemon.
Por padrão ele faz bind em `127.0.0.1:8080` e imprime sua URL.

A página recarrega a si mesma; `SQ_WEB_VIEW_REFRESH` define os segundos entre reloads (padrão 10).

## Acesso remoto

Use `--bind` para escolher o endereço de escuta e `--port` para escolher a porta:

```sh
bin/sq-web-view.sh serve --bind 0.0.0.0 --port 8080
```

Fazer bind em `0.0.0.0` torna o dashboard alcançável por outros dispositivos da LAN no endereço LAN da máquina.
Não há framework de autenticação, por design: o dashboard é somente leitura e revela apenas status de operadores, eventos de acordar, caminhos de projeto, nomes de janela e os metadados de harness, modo, esforço e modelo em cada card.
Decida conscientemente antes de expô-lo além da interface loopback, e mantenha o bind padrão `127.0.0.1` a menos que acesso remoto seja realmente desejado.
Se autenticação real for necessária, isso está fora do escopo desta ferramenta; mantenha o viewer no loopback ou atrás de um proxy autenticado.

## Exportação estática

`render` imprime o mesmo HTML no stdout e não precisa de Python:

```sh
bin/sq-web-view.sh render > /tmp/squad-view/index.html
```

Sirva o arquivo com qualquer servidor de arquivos estáticos, por exemplo `python3 -m http.server --bind 127.0.0.1 -d /tmp/squad-view 8080`; o servidor stdlib faz bind em todas as interfaces por padrão, então passe `--bind 127.0.0.1` a menos que acesso via LAN seja intencional.
Uma exportação estática é um snapshot: regenere para atualizar a página.

## O que mostra

Um card por registro `state/<id>.meta`, atividade mais recente primeiro:

- A classificação ao vivo de ocupado lida de `state/<id>.busy-state` via `bin/sq-busy-lib.sh`, com o motivo quando desconhecida (ausente, malformada ou geração obsoleta).
- O último evento de acordar do final de `state/<id>.status`, com o log completo expansível inline.
- A janela, projeto, harness, modo, esforço e modelo do registro meta.

O formato do registro busy-state é de propriedade de `bin/sq-busy-lib.sh`, o vocabulário de eventos de status de `bin/sq-classify-lib.sh`, e o layout de estado da base de `docs/configuration.md`; esta página não os repete.
A página mostra o último evento de acordar de cada operador, que é histórico, não estado atual reconciliado; `bin/sq-crew-state.sh` é dono dessa reconciliação.

## Somente leitura

O viewer nunca escreve na base: `render` só imprime HTML, e `serve` só lê registros de estado e responde requests HTTP.
Os testes afirmam que os checksums do diretório de estado ficam inalterados após ambos os modos.

## Limites

- `serve` requer `python3` com a biblioteca padrão; `render` funciona em qualquer bash POSIX (bash 3.2 incluso).
- A página cobre uma base por vez; aponte `--state` para o diretório `state/` de outra base para observar aquela.
- Uma base vazia renderiza uma página de estado vazio, não um erro.

## Ponto de entrada de regressão

```sh
tests/sq-web-view.test.sh
```
