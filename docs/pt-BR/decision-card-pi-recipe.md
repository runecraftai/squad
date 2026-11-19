<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Receita Pi para Decision Card (opcional)

Como uma sessão Pi pode apresentar um decision card como diálogo nativo sem mudar o formato de decisão que o Squad possui.
O esquema do cartão tem um único dono, [decision-card-standard.md](decision-card-standard.md), e o bloco de prosa continua sendo a forma canônica que o comandante lê e responde.
Um diálogo nativo é uma superfície de apresentação: é opcional, nunca se torna dono do formato, e todo caminho aqui degrada para o bloco de prosa atual quando a extensão está ausente.

## A extensão

`@juicesharp/rpiv-ask-user-question` é uma extensão Pi que expõe uma ferramenta, `ask_user_question`, e renderiza seu payload como um diálogo nativo de terminal.
Ela nunca é uma dependência de runtime do Squad: nada em `bin/`, nos testes ou no CI a importa, a exige ou a instala.

Seu payload publicado (`docs/tool-schema.md` do pacote, verificado na versão 2.15.0) é:

```ts
ask_user_question({
  questions: [{
    question: string,        // texto completo da pergunta
    header: string,          // rótulo do chip, no máximo 16 caracteres
    options: [{ label: string, description: string, preview?: string }], // 2-4 opções
    multiSelect?: boolean,   // padrão false
  }],                        // 1-4 perguntas por diálogo
})
```

Dois fatos guiam o mapeamento:

- Não há campo `notes` por pergunta, então o contexto e os findings do cartão viajam dentro do texto da pergunta em vez de serem descartados.
- O diálogo acrescenta sua própria linha de texto livre (`Type something.`), então `O0 - Your own words` continua alcançável sem criar uma opção para ela.
  Os rótulos `Other`, `Type something.` e `Next` são reservados e rejeitados, por isso um cartão que use um deles mantém o bloco de prosa.
  Essa linha não pode ampliar a regra do próprio cartão: um cartão com `allow_free_text: false` ainda a mostra, e uma resposta digitada é rejeitada por `bin/sq-ask.sh --answer` porque o cartão, e não o diálogo, decide o que aceita.

## A oferta

`bin/sq-bootstrap.sh` oferece a extensão apenas a um primário Pi (`pi`, `pi-signed`), como uma linha no digest de início de sessão:

- instalada: `BOOTSTRAP_INFO: pi extension @juicesharp/rpiv-ask-user-question installed`.
- ausente: `OPTIONAL: pi extension @juicesharp/rpiv-ask-user-question not installed (offer: pi install npm:@juicesharp/rpiv-ask-user-question, then start a fresh pi session)`.

`OPTIONAL` é uma oferta, não uma ferramenta obrigatória ausente: ela nunca passa pelo caminho de consentimento de instalação de ferramentas obrigatórias e nunca bloqueia despacho.
`.agents/skills/bootstrap-diagnostics` é o dono do tratamento dessa linha.
Instalar é a ação explícita do comandante.
O bootstrap lê `pi list` e nada mais: nunca instala, nunca atualiza, fica silencioso em qualquer outro harness e fica silencioso quando `pi` não está no `PATH`.
A detecção cobre a instalação de escopo de usuário que `pi install` grava; uma instalação de escopo de projeto (`.pi/settings.json`) é protegida por confiança e fica deliberadamente fora de escopo, e uma listagem falha ou ilegível é reportada como nada, nunca como ausência.
`SQUAD_PI_ASK_USER_OFFER=0` silencia a oferta para uma base que não a queira.

## O mapeamento

`bin/sq-card-pi-dialog.sh` converte um payload de cartão (um objeto ou um array) no payload do diálogo e de volta.
Ele valida o cartão por `bin/sq-ask.sh --validate` primeiro, então o esquema mantém exatamente um dono, e não precisa de `pi` nem da extensão em runtime.

| Cartão | Diálogo |
|--------|---------|
| `question` | `questions[].question`, depois uma linha `F<n> - <id> <text>` por finding e por fim uma linha `Context: <context>`, na primeira pergunta do cartão |
| `title` | `questions[].header`, cortado no limite de 16 caracteres no último espaço do texto retido quando sobrar um, senão no próprio limite; o marcador `k/n` de uma pergunta dividida conta dentro dos 16 |
| `options[].label` | `options[].label`, inalterado |
| `options[].description` | `options[].description`; a opção recomendada ganha um ` (recommended)` no final, para que a recomendação apareça em sua própria linha |
| `allow_free_text` | não é criado: a linha de texto livre do próprio diálogo é a saída `O0` |
| `payload`, ids de opção, metadata | não são exibidos |

Divisões substituem o truncamento, porque um diálogo comporta 1-4 perguntas e uma pergunta 2-4 opções:

- mais de quatro opções em um cartão viram várias perguntas, balanceadas e na ordem do cartão (5 -> 3+2, 6 -> 3+3, 9 -> 3+3+3), cada uma numerada `(part k of n)` e `k/n` dentro do cabeçalho;
- mais de quatro perguntas em um cartão viram vários diálogos, cada um uma chamada `ask_user_question`;
- vários cartões em uma resposta viram um diálogo por cartão, na ordem dos cartões.

Um cartão que o diálogo não consegue representar sem descartar ou deturpar uma opção mantém o bloco de prosa, e o mapeamento sai com 2 informando o motivo: um rótulo de diálogo reservado, um rótulo compartilhado por duas opções do cartão, ou um cartão com uma única opção.

## Respostas

As respostas do diálogo voltam como `details.answers`, uma entrada por pergunta com um `kind` e o rótulo escolhido ou o texto digitado, junto com o `details.cancelled` do próprio resultado.
O mapeamento converte isso de volta para a gramática de resposta em prosa, então o parser existente continua sendo o único resolvedor:

```bash
bin/sq-card-pi-dialog.sh --payload < card.json
# uma chamada ask_user_question por elemento do array impresso
bin/sq-card-pi-dialog.sh --answer --dialog 1 --result '<tool result json>' < card.json
# um cartão que precisou de dois diálogos é mesclado em uma chamada, um fragmento por decisão:
bin/sq-card-pi-dialog.sh --answer --dialog 1 --result '<first>' --dialog 2 --result '<second>' < card.json
# -> "d1 o2", depois:
bin/sq-ask.sh --answer 'd1 o2' < card.json
```

`--answer` precisa do cartão de onde veio o diálogo, porque uma resposta é sempre resolvida contra o cartão JSON e nunca contra o texto que o comandante viu.
Ele recebe o resultado inteiro da ferramenta e nunca um array de respostas solto: só `details.cancelled` prova que o diálogo não foi cancelado, então `Esc` nunca vira uma decisão registrada.
Um cartão dividido mantém a numeração global de opções do próprio cartão entre diálogos, então uma opção escolhida no último diálogo continua sendo o código real do cartão e `d1 o15` continua válido.
A mesclagem é mecânica - sem dobra, sem renumeração, sem escolha adivinhada - e produz exatamente um fragmento por decisão.
Duas respostas para a mesma decisão, seja entre as perguntas de um diálogo ou entre dois diálogos, saem com 4 e um erro nomeado em vez de escolher uma, e uma resposta multi-select sai com 4 porque este mapeamento nunca cria uma pergunta multi-select.

## Fallback

Com a extensão ausente, nada muda:

- `bin/sq-ask.sh --render` imprime o mesmo bloco de prosa de sempre;
- `bin/sq-ask.sh --answer` resolve a resposta digitada exatamente como antes;
- o script de mapeamento nunca é chamado por nenhum caminho de decisão existente e não tem dependência de runtime própria.

## Arquivos

| Arquivo | Propósito |
|---------|-----------|
| `bin/sq-card-pi-dialog.sh` | Cartão para payload de diálogo, e respostas do diálogo de volta para o texto de resposta em prosa |
| `bin/sq-bootstrap.sh` | A oferta somente para Pi, incluindo o comando de instalação exato |
| `tests/sq-card-pi-dialog.test.sh` | Casos de mapeamento, divisão, recusa, ida e volta e fallback |
| `tests/sq-bootstrap.test.sh` | A oferta: somente Pi, comando exato, nunca instala, silenciosa em outros harnesses |
