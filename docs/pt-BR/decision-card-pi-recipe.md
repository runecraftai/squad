<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Receita Pi para Decision Card (opcional)

Este documento descreve como sessões pi poderiam opcionalmente usar a extensão rpiv para diálogos interativos mais ricos de decisão enquanto todo o resto permanece agnóstico ao harness.

## Visão geral

A extensão pi `@juicesharp/rpiv-ask-user-question` fornece diálogos nativos de terminal com:
- Até 4 perguntas por diálogo
- 2-4 opções escritas com descrições
- Linha tipada de texto livre
- Previews Markdown
- Resumo na aba submit

É mais rico que o picker básico `sq-ask.sh`, então sessões pi podem querer usá-lo quando disponível.

## Abordagem de integração

### Opção 1: Renderização ciente-da-extensão (recomendada)

O JSON do decision card pode ser transformado para o formato da extensão rpiv:

```bash
# Transformar decision card para o formato rpiv
cat decision-card.json | bin/sq-ask-pi-bridge.sh | pi --tool ask_user_question
```

O script bridge:
1. Lê o JSON do decision card
2. Transforma para o formato esperado do rpiv
3. Invoca o pi com a ferramenta da extensão
4. Captura o resultado estruturado
5. Produz saída no formato padrão de resultado de decision card

### Opção 2: Abordagem baseada em skill

Criar uma skill pi que envolve a apresentação do decision card:

```markdown
---
name: decision-card
description: Present decision cards using rpiv extension when available
---

When presenting a decision card to the commander:
1. Check if rpiv extension is available
2. If yes, transform card JSON to rpiv format and use ask_user_question
3. If no, render using sq-ask.sh --render and accept text answer
```

### Opção 3: Fallback transparente

A abordagem mais simples: sempre usar sq-ask.sh, mas documentar que usuários pi podem instalar rpiv para UX mais rico.

## Referência do formato da extensão rpiv

A extensão rpiv espera:

```json
{
  "questions": [
    {
      "question": "How should we merge?",
      "options": [
        {"label": "Squash", "description": "Combine commits"},
        {"label": "Rebase", "description": "Preserve history"}
      ],
      "notes": "Choose carefully",
      "required": true
    }
  ]
}
```

Mapeamento a partir do decision card:
- `card.question` → `questions[0].question`
- `card.options[].label` → `questions[0].options[].label`
- `card.options[].description` → `questions[0].options[].description`
- `card.context` → `questions[0].notes`
- `card.allow_free_text` → rpiv sempre permite texto livre

## Notas de implementação

Esta é uma melhoria opcional. O núcleo do padrão de decision card funciona sem ela:

- `sq-ask.sh` funciona de qualquer shell
- O formato textual funciona em qualquer chat
- O formato JSON habilita tooling futuro

A receita pi é documentada aqui por completude mas não deve ser construída a menos que:
1. O comandante explicitamente peça
2. A extensão rpiv já esteja instalada nos ambientes alvo
3. O bridge adicione valor claro sobre respostas textuais

## Recomendação

Comece pela abordagem agnóstica ao harness (sq-ask.sh + renderização textual). Monitore se usuários pi frequentemente querem diálogos interativos mais ricos. Se a demanda surgir, implemente o script bridge como tarefa separada.
