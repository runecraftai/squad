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
  A linha nativa não pode ser ocultada, então `--payload` recusa um cartão com `allow_free_text: false` com código 2 e informa o motivo, sem emitir payload; use o bloco de prosa canônico.

## A oferta

`bin/sq-bootstrap.sh` oferece a extensão apenas a um primário Pi (`pi`, `pi-signed`), como uma linha no digest de início de sessão:

- instalada: `BOOTSTRAP_INFO: pi extension @juicesharp/rpiv-ask-user-question installed`.
- ausente: `OPTIONAL: pi extension @juicesharp/rpiv-ask-user-question not installed (offer: pi install npm:@juicesharp/rpiv-ask-user-question, then start a fresh pi session)`.

`OPTIONAL` é uma oferta, não uma ferramenta obrigatória ausente: ela nunca passa pelo caminho de consentimento de instalação de ferramentas obrigatórias e nunca bloqueia despacho.
`.agents/skills/bootstrap-diagnostics` é o dono do tratamento dessa linha.
Instalar é a ação explícita do comandante.
O bootstrap lê o `settings.json` do usuário em `PI_CODING_AGENT_DIR` (por padrão, `~/.pi/agent`), sem iniciar o Pi nem chamar um gerenciador de pacotes. Ele procura a origem npm exata e verifica se o diretório do módulo existe em `npm/node_modules` no mesmo diretório do agente. Ele nunca lê as configurações do projeto. Se a origem ou o diretório do módulo estiver ausente, ele emite a oferta; se as configurações estiverem ilegíveis ou malformadas, fica silencioso.
A origem pode não ter sufixo ou usar `@` seguido de uma versão exata de três componentes (como `2.15.0`, com pré-lançamento e metadados de build opcionais) ou de uma dist-tag simples (letras, dígitos, pontos, hífens e sublinhados, começando com letra ou dígito). Um sufixo com intervalo de versões é inconclusivo: o bootstrap fica silencioso mesmo que a extensão esteja instalada, então siga o comando de instalação acima para configurar a extensão.
O bootstrap também fica silencioso quando `pi` não está no `PATH` ou quando o harness não é identificado como Pi. Um marcador `PI_CODING_AGENT=true` herdado pode fazer uma sessão de outro harness ser identificada como Pi e receber a oferta.
A alternativa em Perl do utilitário compartilhado de timeout pode perder o estado de sinal do processo filho, mas uma consulta que não emite um resultado reconhecido fica silenciosa.
`SQUAD_PI_ASK_USER_OFFER=0` silencia a oferta para uma base que não a queira.

## O mapeamento

`bin/sq-card-pi-dialog.sh` converte um payload de cartão (um objeto ou um array) no payload do diálogo e de volta.
Ele valida o cartão por `bin/sq-ask.sh --validate` primeiro, então o esquema mantém exatamente um dono, e não precisa de `pi` nem da extensão em runtime.

| Cartão | Diálogo |
|--------|---------|
| `question` | `questions[].question`, depois uma linha `F<n> - <id> <text>` por finding e, por fim, uma linha `Context: <context>` quando o cartão tem contexto |
| `title` | `questions[].header`, sem os espaços em branco iniciais e cortado no limite de 16 caracteres, sem cortar uma palavra quando possível |
| `options[].label` | `options[].label`, inalterado |
| `options[].description` | `options[].description`; a opção recomendada ganha um ` (recommended)` no final, para que a recomendação apareça em sua própria linha |
| `allow_free_text` | não é criado: a linha de texto livre do próprio diálogo é a saída `O0` |
| `payload`, ids de opção, metadata | não são exibidos |

Um cartão é uma pergunta de diálogo, porque uma pergunta comporta 2-4 opções:

- um cartão elegível com 2-4 opções vira exatamente uma pergunta `ask_user_question`, com cada opção em sua própria linha e a recomendada marcada;
- vários cartões em uma resposta viram um diálogo por cartão, na ordem dos cartões, cada um renderizado como sua própria chamada `ask_user_question`;
- um cartão com mais de quatro opções mantém o bloco de prosa: o mapeamento sai com 2 informando o motivo, então nenhuma opção é descartada, dobrada ou truncada.

Um mapeamento dividido não é usado para este caminho de payload: a extensão responde uma entrada por pergunta, então um cartão espalhado por duas ou mais perguntas voltaria como várias respostas para a mesma decisão e só poderia ser registrado adivinhando uma escolha.
Recusar o cartão mantém o bloco de prosa autoritativo exatamente para os cartões que precisam de mais de uma pergunta, em vez de deixá-los com um diálogo cuja resposta não pode ser mesclada.

Um cartão que o diálogo não consegue representar sem descartar ou deturpar uma opção mantém o bloco de prosa, e o mapeamento sai com 2 informando o motivo: um rótulo de diálogo reservado, um rótulo compartilhado por duas opções do cartão, um cartão com uma única opção, um cartão com mais de quatro opções, qualquer descrição de opção ausente, nula ou em branco, ou qualquer rótulo ou descrição de opção que termine em `(recommended)` depois de remover os espaços em branco finais, inclusive na própria opção recomendada. A verificação considera apenas o marcador em minúsculas; uma variante como `(Recommended)` continua sendo exibida e não é recusada.

O cabeçalho do diálogo (pergunta, findings, contexto e linha da impressão digital) está limitado a 6 linhas e 600 caracteres, incluindo as quebras de linha. Se ultrapassar qualquer um dos limites, o comando sai com código 2 (`dialog heading exceeds`); use o bloco de prosa.

## Respostas

O resultado do diálogo é a forma publicada da versão 2.15.0, cujos nomes de campo são definidos pela seção "Result" de `docs/tool-schema.md` do pacote: as entradas de `details.answers[]` carregam `questionIndex`, `question`, `kind` e `answer`, com os opcionais `notes`, `selected` e `preview`, e o resultado carrega `details.cancelled`.
O mapeamento confere `questionIndex` e o `question` devolvido com o diálogo indicado por `--dialog` antes de resolver `kind` e `answer`. Toda pergunta termina com o ID do cartão e uma impressão digital determinística de todo o cartão validado. Se a pergunta devolvida não corresponder a essa versão do cartão, o comando sai com código 4, mesmo que o ID e o rótulo escolhido permaneçam iguais.

Para recuperar o resultado, use o comando `/session` do Pi para localizar o arquivo JSONL da sessão atual. No ramo atual da conversa, passe como `--call` a entrada `toolCall` inteira, salva no conteúdo da mensagem do assistente que chamou `ask_user_question`, sem alterar `id` nem `arguments`. Localize a entrada da sessão com `type: "message"`, `message.role: "toolResult"`, `message.toolName: "ask_user_question"` e `message.toolCallId` igual a esse ID. Passe o objeto `message` inteiro, incluindo `details`, como `--result`, sem a entrada externa da sessão. O `content` apresentado ao modelo não basta e não deve ser usado para reconstruir `details`. Se a chamada salva ou o resultado estruturado correspondente não estiver disponível (por exemplo, se a sessão não foi salva), siga o caminho de prosa canônico abaixo.

Use `--resolve` para registrar a decisão em um único comando. Depois de conferir a pergunta devolvida com a versão do cartão, ele compara o `toolCallId` do resultado com o ID da chamada salva. Se o ID do resultado estiver ausente ou for diferente, o comando sai com código 4 e informa o motivo; siga o caminho de prosa canônico. Se os IDs coincidirem, o comando gera novamente o payload do diálogo e o compara com os argumentos salvos como JSON: a ordem das chaves e a formatação não importam, mas todos os campos e itens dos arrays devem corresponder. Se houver divergência, o comando sai com código 2 e o erro `--call arguments do not match`; siga o caminho de prosa canônico. Se houver correspondência, ele executa `bin/sq-ask.sh --answer` com os mesmos bytes do cartão que passaram pelas verificações e devolve a saída e o código de saída do parser sem alterações:

```bash
bin/sq-card-pi-dialog.sh --payload < card.json
# uma chamada ask_user_question por elemento do array impresso
bin/sq-card-pi-dialog.sh --resolve --dialog 1 --call '<JSON da chamada salva>' --result '<resultado da ferramenta>' < card.json
# vários cartões respondidos em uma chamada:
bin/sq-card-pi-dialog.sh --resolve \
  --dialog 1 --call '<JSON da primeira chamada salva>' --result '<primeiro resultado>' \
  --dialog 2 --call '<JSON da segunda chamada salva>' --result '<segundo resultado>' < card.json
```

No script de mapeamento, `--answer` imprime apenas o fragmento com os códigos (como `d1 o2`); não resolva esse fragmento com um arquivo de cartão lido separadamente.
Os dois modos recebem o resultado inteiro da ferramenta, nunca um array de respostas solto: só `details.cancelled` prova que o diálogo não foi cancelado, então `Esc` nunca vira uma decisão registrada.
Os dois modos recusam um resultado que contenha `details.answers[].notes` ou `details.globalNote` com código 4 (`dialog notes cannot be recorded`). Também recusam com código 4 um resultado com `isError: true` ou com o campo `details.error`. Mantenha a decisão em aberto e confirme-a pelo caminho de prosa canônico, em vez de registrar a escolha sem a nota.
Responder vários cartões em uma chamada mescla seus diálogos em exatamente um fragmento por decisão, mecanicamente - sem dobra, sem renumeração, sem escolha adivinhada.
Cada resultado enviado deve conter exatamente uma resposta. Um resultado vazio ou duas respostas para a mesma decisão fazem o comando sair com código 4 sem emitir um fragmento. Uma resposta multi-select também sai com código 4 porque este mapeamento nunca cria uma pergunta multi-select.
Uma resposta malformada, como um rótulo escolhido ou texto digitado que não seja string, sai com 4 e um erro nomeado, nunca com um traceback.
A extensão não consegue validar previamente o texto livre digitado conforme a gramática de prosa. Texto com aspas duplas, barra invertida ou quebra de linha faz o comando sair com código 4 e o erro `free text must be …`; responda pelo bloco de prosa canônico. Cartões com `allow_free_text: false` são recusados antes da apresentação.
Se o parser canônico rejeitar um lote por exceder o limite de tamanho da resposta, tente novamente com menos diálogos por chamada e com o mesmo array de cartões para preservar os códigos `D`.
Um resultado inteiro que exceda o limite do sistema por argumento falha com `Argument list too long` (`E2BIG`) antes de chegar ao parser. Siga o caminho de prosa canônico; não corte o resultado nem o reconstrua a partir do texto apresentado ao modelo.

## Fallback

Se a extensão estiver ausente, o cartão for recusado ou o resultado estruturado correspondente não puder ser recuperado ou usado, siga o caminho de prosa original:

- `bin/sq-ask.sh --render` imprime o mesmo bloco de prosa de sempre;
- `bin/sq-ask.sh --answer` resolve a resposta digitada exatamente como antes;
- o script de mapeamento nunca é chamado por nenhum caminho de decisão existente e não tem dependência de runtime própria.

## Arquivos

| Arquivo | Propósito |
|---------|-----------|
| `bin/sq-card-pi-dialog.sh` | Cartão para payload de diálogo, e respostas do diálogo resolvidas pelo parser canônico |
| `bin/sq-bootstrap.sh` | A oferta somente para Pi, incluindo o comando de instalação exato |
| `tests/sq-card-pi-dialog.test.sh` | Casos de mapeamento, recusa, ida e volta e fallback |
| `tests/sq-bootstrap.test.sh` | A oferta: somente Pi, comando exato, nunca instala, silenciosa em outros harnesses |
