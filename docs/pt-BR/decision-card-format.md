<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Formato textual de Decision Card

A renderização textual canônica de um cartão de decisão para workflows de decisão chaveada.
Reservado para findings ask-user do drill e decisões gated por pipeline que precisam de conjuntos explícitos de opções.
Para respostas gerais multi-item, use o formato de códigos de referência definido na seção 9 do `AGENTS.md`.

## Formato Chat/Cartão

Este formato é usado ao apresentar decisões ao comandante no chat ou terminal:

```
━━━ DECISION: {título} ━━━
{pergunta}

{parágrafo de contexto, se presente}

Options:
  1. {rótulo} - {descrição}  ← recommended
  2. {rótulo} - {descrição}
  3. {rótulo} - {descrição}

Your call [{rótulo_padrão}]: _
```

### Regras

1. **Linha de título**: Sempre começa com `━━━ DECISION:` e termina com `━━━`
2. **Pergunta**: Em sua própria linha, sem prefixo
3. **Contexto**: Opcional, linha em branco antes e depois
4. **Cabeçalho de opções**: Sempre `Options:` em sua própria linha
5. **Numeração de opções**: Índice iniciado em 1, cada uma em sua própria linha com indentação de 2 espaços
6. **Marcador de recomendada**: `  ← recommended` anexado à opção recomendada
7. **Dica de texto livre**: Se `allow_free_text: true`, adicionar após as opções:
   `  0. Type something (free text)`
8. **Linha Your call**: Sempre termina com o rótulo da opção padrão entre colchetes
9. **Cursor do terminal**: `_` ao final indicando entrada esperada

## Formato de linha de status

Para appendar em arquivos `state/<id>.status`:

```
needs-decision [key={chave}]: {título} | options: {rótulo1}|{rótulo2}|{rótulo3} | default: {rótulo_padrão}
```

### Regras da linha de status

1. Usa o prefixo existente `needs-decision [key=<slug>]:`
2. O título segue os dois-pontos
3. As opções são separadas por pipe depois de `options:`
4. O rótulo padrão segue `default:`
5. Mantenha sob 200 caracteres no total

### Exemplo de linha de status

```
needs-decision [key=merge-strategy]: Merge Strategy | options: Squash|Rebase|Merge-commit | default: Squash
```

## Formato inline no chat

Para decisões rápidas inline no chat (quando o cartão completo é verboso demais):

```
[{título}] {pergunta}? Options: {rótulo1}, {rótulo2}, {rótulo3} [default: {rótulo_padrão}]
```

### Exemplo inline

```
[Merge Strategy] How to merge PR #42? Options: Squash, Rebase, Merge-commit [default: Squash]
```

## Saída JSON (do picker)

A ferramenta picker produz a opção selecionada como JSON:

```json
{
  "decision_id": "<card id>",
  "selected_option_id": "<option id>",
  "selected_label": "<option label>",
  "free_text": null,
  "method": "picker"
}
```

Quando texto livre é inserido:

```json
{
  "decision_id": "<card id>",
  "selected_option_id": null,
  "selected_label": null,
  "free_text": "input customizado do usuário",
  "method": "free_text"
}
```

## Integração com sq-send

Ao responder um cartão de decisão via sq-send:

```bash
sq-send.sh <alvo> --resolve-key <chave> "answer: squash"
```

O formato da resposta é:
- Seleção de opção: `answer: <rótulo_da_opção>`
- Texto livre: `answer: <texto_customizado>`

Isso permite que o --resolve-key do sq-send feche a decisão no ledger de status.
