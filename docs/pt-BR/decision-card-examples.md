<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Exemplos de Decision Card

Três exemplos reais de cartões de decisão para workflows de decisão chaveada.
Para respostas gerais multi-item, use o formato de códigos de referência definido na seção 9 do `AGENTS.md`.

## Exemplo 1: Decisão de autoridade de merge

**Cenário**: Uma tarefa drill completou a validação e precisa que o comandante decida como fazer o merge.

### JSON do decision card

```json
{
  "version": 1,
  "id": "merge-auth-fix-auth",
  "title": "Merge Strategy",
  "question": "How should we merge the authentication fix PR?",
  "context": "PR #42 fixes the OAuth token refresh bug. CI is green, 2 commits with logical separation. The fix is time-sensitive.",
  "options": [
    {
      "id": "squash",
      "label": "Squash & Merge",
      "description": "Combine into one clean commit on main",
      "recommended": true
    },
    {
      "id": "rebase",
      "label": "Rebase & Merge",
      "description": "Preserve both commits in history"
    },
    {
      "id": "merge-commit",
      "label": "Create Merge Commit",
      "description": "Standard merge with merge commit message"
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

### Formato da linha de status
```
needs-decision [key=merge-strategy]: Merge Strategy | options: Squash|Rebase|Merge-commit | default: Squash
```

### Renderização do cartão no chat
```
━━━ DECISION: Merge Strategy ━━━
How should we merge the authentication fix PR?

PR #42 fixes the OAuth token refresh bug. CI is green, 2 commits with logical separation.
The fix is time-sensitive.

Options:
  1. Squash & Merge - Combine into one clean commit on main  ← recommended
  2. Rebase & Merge - Preserve both commits in history
  3. Create Merge Commit - Standard merge with merge commit message

Your call [Squash & Merge]: _
```

---

## Exemplo 2: Finding ask-user do drill

**Cenário**: Durante a validação do drill, o linter achou um problema de estilo que poderia ir para qualquer lado. O pipeline drill expõe isso como finding ask-user.

### JSON do decision card

```json
{
  "version": 1,
  "id": "ask-user-import-style",
  "title": "Import Style",
  "question": "Should we use named imports or wildcard imports for the utility module?",
  "context": "The linter flagged mixed import styles in utils.ts. Both are valid; the codebase uses both patterns. This is a style preference that should be consistent.",
  "options": [
    {
      "id": "named",
      "label": "Named Imports",
      "description": "import { func1, func2 } from './utils'",
      "recommended": true
    },
    {
      "id": "wildcard",
      "label": "Wildcard Import",
      "description": "import * as utils from './utils'"
    },
    {
      "id": "default",
      "label": "Default Import",
      "description": "import utils from './utils'"
    }
  ],
  "default_option_id": "named",
  "allow_free_text": true,
  "expires_at": null,
  "metadata": {
    "task_id": "refactor-utils",
    "key": "import-style",
    "source": "ask-user"
  }
}
```

### Formato da linha de status
```
needs-decision [key=import-style]: Import Style | options: Named|Wildcard|Default | default: Named
```

### Renderização do cartão no chat
```
━━━ DECISION: Import Style ━━━
Should we use named imports or wildcard imports for the utility module?

The linter flagged mixed import styles in utils.ts. Both are valid; the codebase uses
both patterns. This is a style preference that should be consistent.

Options:
  1. Named Imports - import { func1, func2 } from './utils'  ← recommended
  2. Wildcard Import - import * as utils from './utils'
  3. Default Import - import utils from './utils'
  0. Type something (free text)

Your call [Named Imports]: _
```

---

## Exemplo 3: Escolha de escopo de produto

**Cenário**: Durante uma implementação de feature, o escopo precisa ser esclarecido. O worker precisa que o comandante decida entre expandir o escopo ou mantê-lo mínimo.

### JSON do decision card

```json
{
  "version": 1,
  "id": "scope-user-dashboard",
  "title": "Dashboard Scope",
  "question": "Should the user dashboard include analytics widgets in the initial release?",
  "context": "The basic dashboard (profile, recent activity) is complete. Analytics widgets were in the original spec but could be deferred to v2 to ship faster. Adding analytics now would add ~2 days.",
  "options": [
    {
      "id": "minimal",
      "label": "Ship Without Analytics",
      "description": "Release dashboard with profile and activity only",
      "recommended": true
    },
    {
      "id": "full",
      "label": "Include Analytics",
      "description": "Add analytics widgets before release (+2 days)"
    },
    {
      "id": "feature-flag",
      "label": "Analytics Behind Flag",
      "description": "Include analytics but gate behind feature flag"
    }
  ],
  "default_option_id": "minimal",
  "allow_free_text": true,
  "expires_at": "2025-02-01T00:00:00Z",
  "metadata": {
    "task_id": "user-dashboard",
    "key": "dashboard-scope",
    "source": "needs-decision"
  }
}
```

### Formato da linha de status
```
needs-decision [key=dashboard-scope]: Dashboard Scope | options: Ship-Without|Include-Analytics|Feature-Flag | default: Ship-Without
```

### Renderização do cartão no chat
```
━━━ DECISION: Dashboard Scope ━━━
Should the user dashboard include analytics widgets in the initial release?

The basic dashboard (profile, recent activity) is complete. Analytics widgets were in
the original spec but could be deferred to v2 to ship faster. Adding analytics now would
add ~2 days.

Options:
  1. Ship Without Analytics - Release dashboard with profile and activity only  ← recommended
  2. Include Analytics - Add analytics widgets before release (+2 days)
  3. Analytics Behind Flag - Include analytics but gate behind feature flag
  0. Type something (free text)

Your call [Ship Without Analytics]: _
```

---

## Integração com sq-send

Quando o comandante responde uma decisão, a resposta flui pelo sq-send com --resolve-key:

```bash
# Comandante seleciona opção 1 (Squash & Merge)
sq-send.sh fix-auth-bug --resolve-key merge-strategy "answer: Squash & Merge"

# Comandante entra texto livre
sq-send.sh refactor-utils --resolve-key import-style "answer: Use barrel exports from index.ts"
```

A flag --resolve-key do sq-send appenda automaticamente o fechamento `resolved [key=<chave>]: answered: <extrato>` ao arquivo de status, encerrando a decisão no ledger.

## Integração com findings ask-user do drill

Quando o drill expõe um finding ask-user, a apresentação deve seguir este formato de cartão:

1. O texto do finding inclui o JSON do decision card ou faz referência a ele
2. O Squad renderiza o cartão usando `sq-ask.sh --render` para apresentação no chat
3. O comandante responde pelo fluxo normal de decisão
4. A resposta é devolvida ao drill via `drill axi respond`

O próprio pipeline drill cuida da mecânica de exposição dos findings; este padrão apenas define o formato de apresentação para garantir consistência em todas as superfícies de decisão.
