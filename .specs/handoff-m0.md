# Handoff — Execução do Squad (M0 em diante)

> Cole este prompt numa sessão nova do Pi (ou use `/new` e cole). A sessão nova
> deve rodar a partir de `/home/rehem/Projects/squad/`.

---

Você está assumindo a execução do projeto **Squad** — um harness "agent distro" (fork rebrandado do firstmate) com tema militar. A sessão anterior completou TODO o planejamento; a implementação NÃO começou. Seu trabalho: **executar os specs até a conclusão, usando a skill `spec-loop` + tlc-spec-driven**.

## Contexto (decisões já fechadas — não re-consultar)

- **Produto:** Squad — fork completo do firstmate (MIT) retematizado: human = *commander*, ponto de contato único = *sergeant at arms*, crewmates = *operators*, secondmates = *XOs*. Prefixo `sq-`, env `SQUAD_*`. Tagline: "Talk to one agent. Deploy with a squad."
- **Local:** `/home/rehem/Projects/squad/` — monorepo Bun + TS + Turborepo; distro na raiz, deps forked em `packages/` (fob=Go, no-mistakes=Go, tasks-axi=TS), integração `@runecraft/pr-review` (v1) e `@runecraft/goal-loop-audit` (v1.1) no fluxo Pi.
- **Língua:** specs e produto em inglês; você pode conversar com o commander em português.
- **Licença/atribuição:** MIT mantido, porém **remoção total de menções ao autor upstream** (decisão do commander; desvio legal documentado como RISK-01 nos specs — não reabrir).
- **Harness primário:** Pi. Adaptadores não-Pi (claude/codex/opencode/grok) mantidos funcionando.

## Onde está o plano (leia ANTES de executar)

```
.specs/project/PROJECT.md      # visão, metas G1–G5
.specs/project/ROADMAP.md      # milestones M0→M5 com exit criteria
.specs/features/squad-inception/context.md   # decisões AD-001..15 (FINAIS)
.specs/features/squad-inception/design.md    # arquitetura + tabela de vocabulário §2 (fonte da verdade) + guards §8
.specs/features/squad-inception/spec.md      # requisitos REQ-M0-01..REQ-M5-01 com acceptance criteria
.specs/features/squad-inception/tasks.md     # tarefas atômicas T-M0-01..T-M5-03 com critérios "Verificar:"
```

## Como executar (obrigatório)

1. **Carregue a skill `spec-loop`** (instruções do loop) e siga a skill `tlc-spec-driven` para a disciplina de fases/tarefas/commits.
2. Rode o loop: ROADMAP → milestones pendentes → tasks.md → **uma tarefa por vez**, na ordem, respeitando dependências.
3. Para cada tarefa: execute, rode os critérios `**Verificar:**` de fato, commit atômico com REQ-ID/ID da tarefa, atualize o progresso.
4. Milestone só é `done` com exit criteria do ROADMAP + grep guards do design.md §8 verdes.
5. Crie/atualize `.specs/project/STATE.md` (se não existir) registrando progresso, decisões, blockers e lições.

## Comece por (M0 — Import & Scaffold)

- T-M0-01: `git init` em `/home/rehem/Projects/squad/` + `.gitignore` copiado do upstream (ref `/tmp/firstmate-ref/.gitignore`)
- T-M0-02: commit do corpus `.specs/` (já presente)
- T-M0-03: import squashado do firstmate (ref `/tmp/firstmate-ref`, excluir `.git/`, preservar symlinks `CLAUDE.md`→`AGENTS.md` e `.claude/skills`→`.agents/skills`); 1 commit único, sem co-autores
- T-M0-04: tooling presence (shellcheck pin, tasks-axi, treehouse)
- T-M0-05: baseline da suite herdada via `bin/fm-test-run.sh` em `FM_HOME` descartável — registrar pass/fail; NÃO corrigir nada ainda

## Constraints duras

- **NUNCA** modificar os clones de referência (`/tmp/firstmate-ref`, `/tmp/dep-treehouse`, `/tmp/dep-no-mistakes`, `/tmp/dep-tasks-axi`) nem o repo `/home/rehem/Projects/harness` (referência Runecraft, read-only).
- **NUNCA** tocar decisões AD-* (context.md) — qualquer conflito = registrar como risco e escalar, não decidir sozinho.
- Safety valve: se uma tarefa revelar >5 passos inesperados, PARE e estenda tasks.md.
- Blocker real → pare e reporte ao commander com evidência.
- Cada linha mudada deve rastrear a uma tarefa do tasks.md; nada de refactors drive-by.
- Commits: atômicos por tarefa; mensagem curta com ID (ex.: `task(M0): T-M0-01 repo init + gitignore`).

## Critérios de sucesso desta sessão

- M0 completo e verificado (baseline da suite registrado, import squashado limpo, `.specs/` commitado).
- Progresso registrado em `.specs/project/STATE.md` (crie se necessário).
- Se M1 iniciou: tabela §2 congelada (design.md), sweep do AGENTS.md em andamento — siga a ordem de 12 passos do design.md §4.

## Reporte ao commander

Ao final da sessão (ou num blocker), reporte em português: milestones concluídos, verificação rodada, commits feitos, próximos passos, riscos novos.
