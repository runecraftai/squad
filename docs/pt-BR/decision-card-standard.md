<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Padrão de Decision Card

Um padrão agnóstico ao harness para workflows específicos de decisão chaveada no Squad.
Reservado para findings ask-user do drill e decisões gated por pipeline que precisam de payloads JSON e do picker sq-ask.
Para respostas gerais multi-item ao comandante, use o formato de códigos de referência definido na seção 9 do `AGENTS.md`.

## Escopo

Este padrão cobre dois workflows:

1. **Findings ask-user do drill** - Decisões expostas pelo pipeline exigindo payloads estruturados de opções
2. **Decisões chaveadas** - Linhas de status específicas `needs-decision [key=<slug>]:` com conjuntos explícitos de opções

Para todas as outras respostas multi-item (findings, riscos, perguntas, ações, opções), use códigos de referência (`F1`, `D1`, `O1`, `R1`, `Q1`, `A1`) conforme definido na seção 9 do `AGENTS.md`.
Não apresente um cartão genérico de resposta como formato normal de escalação.

## Visão geral

O padrão de decision card define:

1. **Schema** - Formato JSON legível por máquina para cartões de decisão
2. **Formato textual** - Renderização canônica para exibição em chat e terminal
3. **Ferramenta picker** - Picker interativo de terminal que qualquer harness pode invocar
4. **Pontos de integração** - Como os cartões fluem pelas superfícies específicas de decisão

## Começo rápido

### Renderizar um decision card

```bash
echo '{"version":1,"id":"test","title":"Test","question":"Pick one?","options":[{"id":"a","label":"Option A"},{"id":"b","label":"Option B"}],"default_option_id":"a"}' | bin/sq-ask.sh --render
```

### Validar um decision card

```bash
cat card.json | bin/sq-ask.sh --validate
```

### Picker interativo (usos não interativos recebem o padrão)

```bash
cat card.json | bin/sq-ask.sh --format id
```

## Documentação

- [Referência de schema](decision-card-schema.md) - JSON schema e regras de validação
- [Formato textual](decision-card-format.md) - Especificações da renderização canônica
- [Exemplos](decision-card-examples.md) - Três exemplos reais de decisão

## Integração com as superfícies de decisão do Squad

### 1. Linhas de status (state/<id>.status)

Quando um worker precisa de uma decisão, appenda uma linha de status seguindo o formato de decisão chaveada:

```
needs-decision [key=<slug>]: <título> | options: <rótulo1>|<rótulo2>|<rótulo3> | default: <rótulo_padrão>
```

Isto se integra ao ciclo de vida existente de decisão:
- `sq-classify-lib.sh` reconhece `needs-decision [key=<slug>]:` como abertura de uma decisão chaveada
- `sq-send.sh --resolve-key` fecha a decisão no momento da resposta
- `decision-hold-lifecycle` gerencia holds duráveis no backlog para decisões não resolvidas

### 2. Apresentações no chat do comandante

Ao apresentar uma decisão chaveada ao comandante no chat, renderize o formato de cartão:

```
━━━ DECISION: <título> ━━━
<pergunta>

<contexto>

Options:
  1. <rótulo> - <descrição>  ← recommended
  2. <rótulo> - <descrição>
  3. <rótulo> - <descrição>

Your call [<rótulo_padrão>]: _
```

Este formato é reservado para decisões chaveadas com conjuntos explícitos de opções.
Para respostas multi-item sem opções chaveadas, use códigos de referência (`F1`, `D1`, `O1`, `R1`, `Q1`, `A1`) conforme definido na seção 9 do `AGENTS.md`.
Não apresente este formato de cartão como formato padrão de escalação para respostas gerais multi-item.

### 3. Findings ask-user do drill

Quando o drill expõe um finding ask-user, apresente-o como um cartão de decisão:

1. Inclua o JSON do cartão de decisão no finding
2. Renderize usando `sq-ask.sh --render` para chat
3. O comandante responde pelo fluxo normal
4. A resposta é devolvida via `drill axi respond`

O pipeline drill cuida da mecânica; este padrão define o formato de apresentação.

## Agnosticismo ao harness

O padrão de decision card funciona em todos os harnesses do Squad:

- **pi**: Pode usar a extensão rpiv para diálogos interativos nativos, ou recuar ao sq-ask.sh
- **claude**: Renderiza cartões no chat, comandante responde via texto
- **codex**: Igual ao claude - renderiza e recebe respostas como texto
- **opencode**: Igual a claude/codex
- **grok**: Igual a claude/codex/opencode

A ferramenta picker (`sq-ask.sh`) detecta ferramentas de terminal disponíveis e degrada graciosamente:
- fzf (preferido) → whiptail → dialog → bash read → default (não interativo)

## Arquivos de implementação

| Arquivo | Propósito |
|------|---------|
| `bin/sq-ask.sh` | Ferramenta picker interativa |
| `docs/decision-card-schema.md` | Referência do JSON schema |
| `docs/decision-card-format.md` | Especificações do formato textual |
| `docs/decision-card-examples.md` | Exemplos reais |
| `docs/decision-card-standard.md` | Este arquivo - visão geral e integração |
| `tests/sq-ask.test.sh` | Testes de validação e renderização |

## Compatibilidade retroativa

Este padrão é aditivo e não quebra fluxos existentes de decisão:

- Linhas existentes `needs-decision: <resumo>` sem opções continuam funcionando
- O fechamento existente `resolved [key=<slug>]:` continua funcionando
- O formato de cartão é uma camada de apresentação sobre a semântica existente
- O parsing de chaves do `sq-classify-lib.sh` está inalterado
- Códigos de referência (`F1`, `D1`, `O1`, `R1`, `Q1`, `A1`) são o padrão para toda resposta multi-item ao comandante; o formato de cartão é reservado para workflows de decisão chaveada

## Decisões de design

1. **JSON schema para legibilidade por máquina** - Habilita tooling, validação e automação futura
2. **Formato textual para legibilidade humana** - Consistente, conciso, termina com prompt claro de "your call"
3. **Sempre permitir texto livre** - Preserva flexibilidade do comandante; nunca trava apenas nas opções escritas
4. **Opção padrão sempre visível** - Torna a recomendação explícita, reduz carga cognitiva
5. **Picker agnóstico ao harness** - Funciona de qualquer shell, degrada graciosamente, sem bindings específicos de harness
6. **Integração com ciclo de vida existente** - Usa sq-send --resolve-key, decision-hold-lifecycle, sq-classify-lib.sh

## Extensões futuras (fora do escopo)

Notadas por completude mas não fazem parte deste padrão:

- **Diálogo nativo pi** - A extensão rpiv pode fornecer UX interativo mais rico para sessões pi
- **Picker Web UI** - Um picker baseado em navegador para ambientes não terminais
- **Histórico de decisões** - Rastreamento de padrões de decisão ao longo do tempo
- **Auto-expiração** - Resolução automática quando cartões expiram
