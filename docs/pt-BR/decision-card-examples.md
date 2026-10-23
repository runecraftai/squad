<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Exemplos de Decision Card

Três exemplos do bloco de prosa e do cartão por trás dele.
Os blocos de prosa abaixo são gerados por `bin/sq-ask.sh --render` a partir dos fixtures em `tests/fixtures/decision-prose/`, e um teste os mantém idênticos.
O schema e as regras ficam no [Padrão do Payload de Decision Card](decision-card-standard.md).

## Exemplo 1: Decisão chaveada de merge

Uma tarefa drill terminou a validação e precisa que o comandante escolha uma estratégia de merge.
O cartão é `tests/fixtures/decision-prose/merge.json`; texto livre desligado.

```text
D1 - Merge Strategy (ref: merge-strategy)
  How should we merge the authentication fix PR?
  Context: PR #42 fixes the OAuth token refresh bug. CI is green, 2 commits, time-sensitive.
  O1 - Squash & Merge: Combine into one clean commit on main (recommended)
  O2 - Rebase & Merge: Preserve both commits in history
  O3 - Create Merge Commit: Standard merge with a merge commit message
```

A linha de status do worker:

```
needs-decision [key=merge-strategy]: Merge Strategy | options: Squash & Merge|Rebase & Merge|Create Merge Commit | default: Squash & Merge
```

O comandante digita `d1 o2`.
O Squad resolve contra o cartão e responde com o rótulo, nunca com o código:

```bash
bin/sq-ask.sh --answer 'd1 o2' --format text < tests/fixtures/decision-prose/merge.json
sq-send <task> --resolve-key merge-strategy "Rebase & Merge"
```

## Exemplo 2: Gate de revisão do drill

O drill reporta dois findings ask-user e oferece apenas uma resposta no nível do gate.
O Squad cria o cartão a partir de `drill axi status`; o payload de cada opção guarda os argumentos exatos de `drill axi respond`.
O cartão é `tests/fixtures/decision-prose/gate.json`.

```text
F1 - review-1 src/a.go:10 - flags an intentional guard
F2 - review-2 src/b.go:44 - asks for a new compatibility layer

D1 - Review gate: 2 open findings (ref: review-gate-1)
  Accepted intent does not require the compatibility layer.
  O1 - Fix both findings: apply both as proposed (recommended)
  O2 - Accept as is: keep the code, finish this step
  O3 - Skip the step: do not run this check
  O0 - Your own words
```

O comandante digita `d1 o1`; o resultado carrega o payload sem alteração:

```json
{"decision_id":"review-gate-1","selected_option_id":"fix-all","selected_label":"Fix both findings",
 "selected_payload":{"action":"fix","step":"review","findings":["review-1","review-2"]},
 "free_text":null,"method":"prose"}
```

O Squad envia ao worker a chave da decisão, o passo, a ação, os ids dos findings e o comando de resposta exato, com `--resolve-key review-gate-1`.
Uma resposta digitada como `d1 o0 "fix only the first one"` é julgamento do Squad: ele reafirma os argumentos resolvidos antes de enviar.

## Exemplo 3: Escolha de escopo de produto

Um worker precisa que o comandante decida se amplia o escopo.
O cartão é `tests/fixtures/decision-prose/scope.json`; texto livre ligado.

```text
D1 - Dashboard Scope (ref: dashboard-scope)
  Should the user dashboard include analytics widgets in the initial release?
  Context: The basic dashboard is done. Analytics widgets were in the original spec but could move to v2 to ship faster; adding them now costs about 2 days.
  O1 - Ship Without Analytics: Release with profile and activity only (recommended)
  O2 - Include Analytics: Add analytics widgets before release (+2 days)
  O3 - Analytics Behind Flag: Include analytics but gate them behind a feature flag
  O0 - Your own words
```

Respostas: `d1 o2`, ou `d1 o0 "ship it Friday"`.
Várias decisões em uma resposta são respondidas juntas, `d1 o2 d2 o1`, e podem ser respondidas em parte; o resto continua aberto.
