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
  Essa linha não pode ampliar a regra do próprio cartão: um cartão com `allow_free_text: false` ainda a mostra, e uma resposta digitada é rejeitada pelo mapeamento por meio de `bin/sq-ask.sh --answer` porque o cartão, e não o diálogo, decide o que aceita.

## A oferta

`bin/sq-bootstrap.sh` oferece a extensão apenas a um primário Pi (`pi`, `pi-signed`), como uma linha no digest de início de sessão:

- instalada: `BOOTSTRAP_INFO: pi extension @juicesharp/rpiv-ask-user-question installed`.
- ausente: `OPTIONAL: pi extension @juicesharp/rpiv-ask-user-question not installed (offer: pi install npm:@juicesharp/rpiv-ask-user-question, then start a fresh pi session)`.

`OPTIONAL` é uma oferta, não uma ferramenta obrigatória ausente: ela nunca passa pelo caminho de consentimento de instalação de ferramentas obrigatórias e nunca bloqueia despacho.
`.agents/skills/bootstrap-diagnostics` é o dono do tratamento dessa linha.
Instalar é a ação explícita do comandante.
O bootstrap lê `pi list` e nada mais: nunca instala, nunca atualiza, fica silencioso em qualquer outro harness e fica silencioso quando `pi` não está no `PATH`.
A detecção lê apenas a seção `User packages:` de `pi list` e para em `Project packages:`, então cobre exatamente a instalação de escopo de usuário que `pi install` grava; uma instalação de escopo de projeto (`.pi/settings.json`, protegida por confiança) fica fora de escopo e, portanto, é lida como ausente, nunca como instalada, e uma listagem falha ou ilegível é reportada como nada, nunca como ausência.
`SQUAD_PI_ASK_USER_OFFER=0` silencia a oferta para uma base que não a queira.

## O mapeamento

`bin/sq-card-pi-dialog.sh` converte um payload de cartão (um objeto ou um array) no payload do diálogo e de volta.
Ele valida o cartão por `bin/sq-ask.sh --validate` primeiro, então o esquema mantém exatamente um dono, e não precisa de `pi` nem da extensão em runtime.

| Cartão | Diálogo |
|--------|---------|
| `question` | `questions[].question`, depois uma linha `F<n> - <id> <text>` por finding e, por fim, uma linha `Context: <context>` quando o cartão tem contexto |
| `title` | `questions[].header`, cortado no limite de 16 caracteres no último espaço do texto retido quando sobrar um, senão no próprio limite |
| `options[].label` | `options[].label`, inalterado |
| `options[].description` | `options[].description`; a opção recomendada ganha um ` (recommended)` no final, para que a recomendação apareça em sua própria linha |
| `allow_free_text` | não é criado: a linha de texto livre do próprio diálogo é a saída `O0` |
| `payload`, ids de opção, metadata | não são exibidos |

Um cartão é uma pergunta de diálogo, porque uma pergunta comporta 2-4 opções:

- um cartão com 2-4 opções vira exatamente uma pergunta `ask_user_question`, com cada opção em sua própria linha e a recomendada marcada;
- vários cartões em uma resposta viram um diálogo por cartão, na ordem dos cartões, cada um renderizado como sua própria chamada `ask_user_question`;
- um cartão com mais de quatro opções mantém o bloco de prosa: o mapeamento sai com 2 informando o motivo, então nenhuma opção é descartada, dobrada ou truncada.

Um mapeamento dividido não é usado para este caminho de payload: a extensão responde uma entrada por pergunta, então um cartão espalhado por duas ou mais perguntas voltaria como várias respostas para a mesma decisão e só poderia ser registrado adivinhando uma escolha.
Recusar o cartão mantém o bloco de prosa autoritativo exatamente para os cartões que precisam de mais de uma pergunta, em vez de deixá-los com um diálogo cuja resposta não pode ser mesclada.

Um cartão que o diálogo não consegue representar sem descartar ou deturpar uma opção mantém o bloco de prosa, e o mapeamento sai com 2 informando o motivo: um rótulo de diálogo reservado, um rótulo compartilhado por duas opções do cartão, um cartão com uma única opção, ou um cartão com mais de quatro opções.

## Respostas

O resultado do diálogo é a forma publicada da versão 2.15.0, cujos nomes de campo são definidos pela seção "Result" de `docs/tool-schema.md` do pacote: as entradas de `details.answers[]` carregam `questionIndex`, `question`, `kind` e `answer`, com os opcionais `notes`, `selected` e `preview`, e o resultado carrega `details.cancelled`.
O mapeamento confere `questionIndex` e o `question` devolvido com o diálogo indicado por `--dialog` antes de resolver `kind` e `answer`. Toda pergunta termina com `Decision: <id do cartão>` para distinguir os resultados mesmo quando cartões com perguntas idênticas são apresentados separadamente.
Ele converte isso de volta para a gramática de resposta em prosa, então o parser existente continua sendo o único resolvedor:

```bash
bin/sq-card-pi-dialog.sh --payload < card.json
# uma chamada ask_user_question por elemento do array impresso
bin/sq-card-pi-dialog.sh --answer --dialog 1 --result '<tool result json>' < card.json
# vários cartões respondidos em uma chamada são mesclados em um fragmento por decisão:
bin/sq-card-pi-dialog.sh --answer --dialog 1 --result '<first>' --dialog 2 --result '<second>' < card.json
# -> "d1 o2", depois:
bin/sq-ask.sh --answer 'd1 o2' < card.json
```

`--answer` precisa do cartão de onde veio o diálogo, porque uma resposta é sempre resolvida contra o cartão JSON e nunca contra o texto que o comandante viu.
Ele recebe o resultado inteiro da ferramenta e nunca um array de respostas solto: só `details.cancelled` prova que o diálogo não foi cancelado, então `Esc` nunca vira uma decisão registrada.
Responder vários cartões em uma chamada mescla seus diálogos em exatamente um fragmento por decisão, mecanicamente - sem dobra, sem renumeração, sem escolha adivinhada.
Cada resultado enviado deve conter exatamente uma resposta. Um resultado vazio ou duas respostas para a mesma decisão fazem o comando sair com código 4 sem emitir um fragmento. Uma resposta multi-select também sai com código 4 porque este mapeamento nunca cria uma pergunta multi-select.
Uma resposta malformada, como um rótulo escolhido ou texto digitado que não seja string, sai com 4 e um erro nomeado, nunca com um traceback.
O mapeamento executa o analisador canônico de respostas antes de imprimir o fragmento. Se ele rejeitar um lote por exceder o limite de tamanho da resposta, tente novamente com menos diálogos por chamada e com o mesmo array de cartões para preservar os códigos `D`.

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
| `tests/sq-card-pi-dialog.test.sh` | Casos de mapeamento, recusa, ida e volta e fallback |
| `tests/sq-bootstrap.test.sh` | A oferta: somente Pi, comando exato, nunca instala, silenciosa em outros harnesses |
