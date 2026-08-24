<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Guardrails de loop e contexto para sessões Pi

Uma extensão Pi local ao projeto que impõe dois guardrails independentes em cada evento `tool_call`.
Ela se aplica a qualquer sessão Pi rodando dentro deste repo ou seus worktrees - tanto sessões primárias do Squad quanto sessões de operador.
A implementação vive em `.pi/extensions/sq-loop-context-guardrail.ts`.

## Guardrail A - Chamadas idênticas repetidas de ferramenta

Rastreia chamadas consecutivas idênticas de ferramenta (mesmo nome de ferramenta e mesmo input JSON canonizado).
O contador de sequência não zera sozinho nas fronteiras de turno - só quando uma chamada genuinamente diferente quebra a sequência.

**Limiares:**

| Sequência | Ação |
| --------- | ---- |
| 1-4 | Nenhuma ação. |
| 5 | Um único warning visível nomeando a ferramenta e a contagem. Não repete para chamadas 6-9. |
| 10+ | Bloqueado com um motivo explicando a contagem e recomendando uma abordagem diferente ou checagem de vitalidade do alvo. Bloqueia toda chamada a partir da 10 na mesma sequência. |

Um nome de ferramenta diferente ou input canonizado diferente zera a sequência e limpa a flag "já avisou".

## Guardrail B - Orçamento de contexto (baseado em percentual)

Lê `ctx.getContextUsage()` a cada `tool_call`.
O campo `percent` já vem normalizado 0-100 relativo à janela de contexto do modelo - sem teto fixo de tokens.

**Zonas:**

| Percentual | Zona | Ação |
| ---------- | ---- | ---- |
| 0-39 | Smart | Nenhuma ação. Voltar aqui reseta as flags de atenção e compactação. |
| 40-59 | Attention | Um aviso visível único nomeando o percentual e recomendando `/compact` em breve. Não repete enquanto dentro desta zona. |
| 60-100 | Dumb | Bloqueado. A primeira entrada nesta zona auto-dispara `ctx.compact()` como cortesia. Toda chamada subsequente enquanto ainda >= 60% continua bloqueando (o percentual é relido fresco a cada vez). |

Se `getContextUsage()` retornar undefined ou null (por exemplo logo após a compactação), o guardrail pula completamente.

## Fail-open

Qualquer erro interno na própria lógica do guardrail - como `ctx.getContextUsage()` lançando exceção - nunca derruba a sessão nem bloqueia chamadas de ferramenta.
A chamada passa e o erro é registrado.

## Escopo

- Extensão local ao projeto em `.pi/extensions/` - descoberta automaticamente por qualquer sessão Pi neste repo ou seus worktrees.
- Não toca em `bin/sq-breaker-lib.sh` nem em `bin/sq-breaker.sh` (circuit breaker separado voltado a operadores).
- Os dois guardrails são máquinas de estado independentes avaliadas a cada chamada de ferramenta.
- Sem novas dependências de runtime.
