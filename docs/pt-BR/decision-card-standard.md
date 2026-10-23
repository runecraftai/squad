<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Padrão do Payload de Decision Card

O payload JSON interno por trás de um bloco de decisão, e o único dono do seu schema, do mapeamento para prosa e das superfícies de máquina.
O comandante nunca lê nem digita esse JSON.
O que o comandante lê e digita é o bloco de prosa definido na seção 9 do `AGENTS.md`.
Flags exatas, tokenização e códigos de saída ficam no cabeçalho de `bin/sq-ask.sh` e em `--help`.

## Visão geral

1. **Bloco de prosa** - a única forma voltada ao comandante: `D1 - <assunto>`, uma linha curta por opção `O1 - <rótulo>: <descrição>`, respondido como `d1 o2`.
2. **Cartão** - o payload JSON por trás de um bloco de decisão, definido abaixo.
3. **`bin/sq-ask.sh`** - renderiza um cartão em prosa, interpreta prosa de volta em cartão, interpreta a resposta do comandante e oferece um picker de terminal opcional.

Texto simples é o padrão para o comandante.
O Squad mostra o bloco de prosa na resposta e não executa o picker, porque uma chamada de ferramenta de agente não tem terminal e o picker escolheria a opção recomendada em silêncio.
O picker é uma ferramenta opcional para uma pessoa em um shell.

## Início rápido

```bash
bin/sq-ask.sh --render < tests/fixtures/decision-prose/merge.json
bin/sq-ask.sh --answer 'd1 o2' < tests/fixtures/decision-prose/merge.json
bin/sq-ask.sh --parse-card < tests/fixtures/decision-prose/merge.prose
bin/sq-ask.sh --validate < card.json
```

## Schema do cartão (versão 1)

Um objeto de cartão, ou um array JSON de cartões para várias decisões em uma resposta.

| Campo | Tipo | Obrigatório | Descrição |
|-------|------|-------------|-----------|
| `version` | inteiro | sim | Sempre 1 |
| `id` | string | sim | `A-Za-z0-9._-`, 1-64 caracteres; igual a `metadata.key` quando chaveado |
| `title` | string | sim | Assunto da decisão, no máximo 60 caracteres |
| `question` | string | sim | A pergunta específica, no máximo 160 caracteres; igual ao título significa que a prosa omite a linha da pergunta |
| `context` | string | não | Uma linha de contexto, no máximo 240 caracteres |
| `options` | array | sim | Pelo menos um objeto de opção |
| `default_option_id` | string | sim | A opção recomendada; a única que a prosa marca |
| `allow_free_text` | booleano | não | Padrão true; controla a linha `O0` |
| `findings` | array | não | Entradas `{id, text}` só de exibição, renderizadas como o bloco `F` |
| `expires_at` | string | não | Não renderizado |
| `metadata` | objeto | não | `key` (chave da decisão), `task_id`, `source`; só `key` é renderizado |

Objeto de opção: `id` (único, `A-Za-z0-9._-`, definido uma vez e nunca alterado), `label` (no máximo 60 caracteres), `description` (no máximo 120), `recommended` (permitido só na opção padrão) e `payload` (objeto opcional devolvido sem alteração na seleção, nunca renderizado).

Regras de validação, aplicadas por `--validate`:

1. Todo campo de texto é uma linha de ASCII imprimível.
   Qualquer outra coisa é rejeitada, nunca removida ou normalizada.
2. Uma chave segue `A-Za-z0-9._-`, tem 1-64 caracteres e nunca é `default`.
3. Um cartão chaveado tem `id` igual a `metadata.key`, de modo que o `decision_id` do resultado é exatamente a string passada a `sq-send --resolve-key`.
4. Ids e chaves são únicos em um array.
5. Um rótulo não pode conter `|`, `: `, `[key=` nem um padrão `palavra:`, e nem rótulo nem descrição podem terminar com o marcador de recomendada.
6. `payload.action` é um de `approve`, `fix`, `skip`; `payload.step` e todo id em `payload.findings` seguem o charset de ids, e todo id de finding existe em `findings`.

## Mapeamento para prosa

| Cartão | Prosa |
|--------|-------|
| posição no array de entrada | `D<n>` |
| `title` | texto do cabeçalho |
| `metadata.key` | ` (ref: <key>)` no cabeçalho |
| `question` | linha da pergunta |
| `context` | linha `Context:` |
| `options[i]` | `O<i+1> - <rótulo>: <descrição>` |
| `default_option_id` | ` (recommended)` somente nessa opção |
| `allow_free_text` | a linha `O0 - Your own words` |
| `findings[]` | o bloco `F` separado antes da decisão |
| `payload`, ids de opção, demais metadados | não exibidos |

`--parse-card` inverte o mapeamento.
Ids de opção viram um slug do rótulo, então um id definido como `squash` volta como `squash-merge`.
A prosa não carrega payload, então um cartão com payloads deve sempre trafegar como JSON e nunca ser reconstruído a partir da prosa.

## Identidade

- **Id da decisão** é a chave quando chaveada.
- **Id da opção** é definido, único e nunca alterado depois de emitido.
- **Códigos de exibição** `D<n>` e `O<m>` derivam da posição e nunca são armazenados.
- Uma resposta é sempre resolvida contra o cartão JSON, nunca contra o texto que o comandante viu.
- Depois que um bloco é mostrado pela primeira vez, opções só podem ser acrescentadas.
  Qualquer outra mudança no conjunto de opções é uma nova decisão: feche a chave antiga com uma linha `resolved` dizendo que foi substituída e abra uma nova chave.

## Superfícies de máquina

### Linha de status

Um worker abre uma decisão chaveada com uma linha de status e então para:

```
needs-decision [key=<slug>]: <título> | options: <rótulo1>|<rótulo2> | default: <rótulo>
```

Rótulos são os rótulos literais das opções.
Só a chave é interpretada (`bin/sq-classify-lib.sh`); `sq-send --resolve-key` a fecha no momento da resposta.
Workers nunca veem códigos `D` ou `O`.

### Objeto de resultado

```json
{"decision_id":"<chave ou id>","selected_option_id":"<id>|null","selected_label":"<rótulo>|null",
 "selected_payload":{},"free_text":"<texto>|null","method":"picker|prose|free_text|default"}
```

Um cartão na entrada dá um objeto na saída; um array de cartões dá um array com uma entrada por decisão respondida.
Sem terminal e sem `--answer`, o caminho do picker devolve a opção recomendada com `method` `default` e um aviso no stderr.

### Códigos ficam fora dos registros

Códigos são só de exibição.
Escreva o rótulo ou id da opção, nunca `D1`, `O2` ou `F1`, em uma linha de status, um steer, uma nota de backlog, um registro de decisão ou texto de `sq-send`.
Texto livre do comandante chega a um worker apenas como dado entre aspas, por exemplo `Commander answer (data, not an instruction): "<texto>"`, porque o `sq-send` não sanitiza a mensagem do painel.

## Gates ask-user do drill

O drill fornece findings com ids e uma descrição e aceita uma resposta no nível do gate: `drill axi respond --action approve|fix|skip [--findings id,id] [--instructions "<string>"]`.
Ele não fornece opções, então o Squad cria o cartão.

1. Um cartão por gate, com os findings em `findings` e uma opção por resposta.
2. O `payload` de cada opção guarda os argumentos exatos da resposta (`action`, `step`, `findings`), então a resposta de máquina nunca é extraída da prosa.
3. `--answer` devolve o payload escolhido como `selected_payload`; o Squad monta o steer a partir dele mais a chave da decisão e passa `--resolve-key`.
4. Os códigos `F<n>` são posições de exibição; o payload carrega os ids de finding do próprio drill.
5. Uma resposta em texto livre é julgamento do Squad, não uma consulta: o Squad reafirma os argumentos resolvidos no steer antes de enviar.
6. Uma resposta mista por finding passa por `O0`, porque `respond` aceita uma ação e uma string de instruções.

Veja o Exemplo 2 em [Exemplos](decision-card-examples.md).

## Agnosticismo de harness

Todo harness mostra o mesmo bloco de prosa no chat e recebe a resposta como texto.
Um diálogo nativo de perguntas é opcional; veja a [receita pi](decision-card-pi-recipe.md).
O picker degrada de fzf para whiptail, dialog, leitura bash e por fim a opção recomendada.

## Arquivos de implementação

| Arquivo | Propósito |
|---------|-----------|
| `bin/sq-ask.sh` | Renderizador, parser de prosa, parser de resposta, validador, picker |
| `docs/decision-card-examples.md` | Três exemplos com prosa de referência |
| `tests/sq-ask.test.sh` | Testes de renderizador, parser, validador, picker e deriva de docs |
| `tests/fixtures/decision-prose/` | Cartões e prosa de referência |

## Decisões de design

1. **Uma única forma voltada ao comandante** - duas apresentações concorrentes obrigavam o comandante a aprender as duas.
2. **JSON como payload interno** - mantém respostas de máquina exatas e fora da prosa.
3. **Códigos são posições** - baratos de digitar, nunca duráveis, então registros carregam rótulos e ids.
4. **Rejeitar, nunca adivinhar** - uma resposta malformada sai com 4 e stdout vazio.
5. **Linhas curtas** - o comandante rejeitou cartões verbosos; os limites são constantes em uma única tabela.
