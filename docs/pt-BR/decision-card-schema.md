<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Schema de Decision Card v1

Um decision card é uma representação estruturada de um request de decisão do comandante.
Ele padroniza como o Squad apresenta escolhas ao comandante em todos os harnesses.

## JSON Schema

```json
{
  "version": 1,
  "id": "<unique-id>",
  "title": "<short title>",
  "question": "<the question being asked>",
  "context": "<brief context, 1-3 sentences>",
  "options": [
    {
      "id": "<option-id>",
      "label": "<display label>",
      "description": "<one-line description>",
      "recommended": false
    }
  ],
  "default_option_id": "<id of default option>",
  "allow_free_text": true,
  "expires_at": "<ISO-8601 timestamp or null>",
  "metadata": {
    "task_id": "<squad task id>",
    "key": "<decision key slug>",
    "source": "<where this decision originated>"
  }
}
```

### Campos

| Campo | Tipo | Obrigatório | Descrição |
|-------|------|----------|-------------|
| `version` | integer | sim | Versão do schema (atualmente 1) |
| `id` | string | sim | Identificador único da decisão (UUID ou slug) |
| `title` | string | sim | Título curto da decisão |
| `question` | string | sim | A pergunta específica sendo feita |
| `context` | string | não | Contexto breve (máximo 1-3 frases) |
| `options` | array | sim | Array de objetos de opção (recomendado 2-4) |
| `default_option_id` | string | sim | ID da opção recomendada/padrão |
| `allow_free_text` | boolean | não | Se input de texto livre é permitido (padrão: true) |
| `expires_at` | string | não | Timestamp ISO-8601 quando a decisão expira |
| `metadata` | object | não | Contexto adicional (task_id, key, source) |

### Objeto Option

| Campo | Tipo | Obrigatório | Descrição |
|-------|------|----------|-------------|
| `id` | string | sim | Identificador único da opção |
| `label` | string | sim | Rótulo curto de exibição (2-4 palavras) |
| `description` | string | não | Descrição de uma linha desta opção |
| `recommended` | boolean | não | Se esta é a escolha recomendada (deve bater com default_option_id) |

### Objeto Metadata

| Campo | Tipo | Descrição |
|-------|------|-------------|
| `task_id` | string | ID da tarefa Squad à qual esta decisão pertence |
| `key` | string | Slug da chave de decisão (para sq-send --resolve-key) |
| `source` | string | Origem: "ask-user", "blocked", "needs-decision", "manual" |

## Regras de validação

1. `version` deve ser 1
2. `id` deve ser não vazio
3. `title` deve ser não vazio
4. `question` deve ser não vazio
5. `options` precisa ter pelo menos 1 entrada
6. `default_option_id` deve referenciar um id de opção existente
7. Cada `id` de opção deve ser único dentro do cartão
8. Cada `label` de opção deve ser não vazio
9. No máximo uma opção deve ter `recommended: true`

## Exemplo

```json
{
  "version": 1,
  "id": "merge-strategy-2025-01",
  "title": "Merge Strategy",
  "question": "How should we merge this PR?",
  "context": "The PR has 3 commits with logical separation. CI is green.",
  "options": [
    {
      "id": "squash",
      "label": "Squash & Merge",
      "description": "Combine all commits into one clean commit",
      "recommended": true
    },
    {
      "id": "rebase",
      "label": "Rebase & Merge",
      "description": "Preserve individual commits in history"
    },
    {
      "id": "merge-commit",
      "label": "Create Merge Commit",
      "description": "Standard merge with merge commit"
    }
  ],
  "default_option_id": "squash",
  "allow_free_text": false,
  "expires_at": null,
  "metadata": {
    "task_id": "fix-auth-bug",
    "key": "merge-strategy",
    "source": "ask-user"
  }
}
```
