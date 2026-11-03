<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Prova de isolamento de testes do Squad

Este registro é a prova de isolamento concorrente para o conjunto portátil de candidatos paralelos.
`bin/sq-test-isolation-proof.sh` é o harness autoritativo e `docs/sq-test-isolation-proof.json` é o resultado legível por máquina.
`bin/sq-test-run.sh` é dono da partição de lanes de produção.

## Verificação

- Data: 2026-11-03
- Comando: `bin/sq-test-isolation-proof.sh --jobs 4 --json docs/sq-test-isolation-proof.json`
- Resultado: `SQUAD_ISOLATION_SUMMARY total=23 failed=1 concurrency=4 duration_ms=100049`

| Campo | Valor |
|---|---|
| `run_id` | `sq-isolation-1793669267812-3667561` |
| `started_at` | `2026-11-03T01:27:47Z` |
| `finished_at` | `2026-11-03T01:29:27Z` |
| concorrência | 4 |
| candidatos | 23 |
| falhas | 1 |
| duração de parede | 100049 ms |

A única falha é `tests/sq-backend-herdr.test.sh`, cujo caso de recusa sem herdr não pode passar em um host que tem `herdr` no `PATH` (o host de gravação tinha `/usr/bin/herdr 0.9.1`); todos os outros candidatos passaram.

## Conjunto candidato

- `tests/sq-arm-pretool-check.test.sh`
- `tests/sq-backend-herdr.test.sh`
- `tests/sq-brief.test.sh`
- `tests/sq-cd-pretool-check.test.sh`
- `tests/sq-composer-ghost.test.sh`
- `tests/sq-composer-lib.test.sh`
- `tests/sq-crew-state.test.sh`
- `tests/sq-decision-hold-lifecycle.test.sh`
- `tests/sq-ensure-agents-md.test.sh`
- `tests/sq-grok-harness.test.sh`
- `tests/sq-herdr-lab.test.sh`
- `tests/sq-lint.test.sh`
- `tests/sq-pi-primary-types.test.sh`
- `tests/sq-pr-merge.test.sh`
- `tests/sq-review-diff.test.sh`
- `tests/sq-send-popup-settle.test.sh`
- `tests/sq-send-settle.test.sh`
- `tests/sq-send-strict.test.sh`
- `tests/sq-spawn-batch.test.sh`
- `tests/sq-supervision-instructions.test.sh`
- `tests/sq-test-run.test.sh`
- `tests/sq-tmux-submit-busy.test.sh`
- `tests/sq-transition-lib.test.sh`

## Durações

| duration_ms | exit | worker | script |
|---:|---:|---:|---|
| 43689 | 0 | 1 | `tests/sq-arm-pretool-check.test.sh` |
| 31331 | 0 | 8 | `tests/sq-decision-hold-lifecycle.test.sh` |
| 18245 | 0 | 4 | `tests/sq-cd-pretool-check.test.sh` |
| 18231 | 0 | 21 | `tests/sq-test-run.test.sh` |
| 16854 | 0 | 7 | `tests/sq-crew-state.test.sh` |
| 15733 | 0 | 3 | `tests/sq-brief.test.sh` |
| 11633 | 0 | 10 | `tests/sq-grok-harness.test.sh` |
| 6568 | 0 | 14 | `tests/sq-pr-merge.test.sh` |
| 6404 | 0 | 11 | `tests/sq-herdr-lab.test.sh` |
| 4709 | 0 | 17 | `tests/sq-send-settle.test.sh` |
| 1706 | 0 | 5 | `tests/sq-composer-ghost.test.sh` |
| 1450 | 0 | 12 | `tests/sq-lint.test.sh` |
| 1229 | 0 | 22 | `tests/sq-tmux-submit-busy.test.sh` |
| 1086 | 0 | 16 | `tests/sq-send-popup-settle.test.sh` |
| 1064 | 0 | 15 | `tests/sq-review-diff.test.sh` |
| 1048 | 0 | 18 | `tests/sq-send-strict.test.sh` |
| 1036 | 0 | 19 | `tests/sq-spawn-batch.test.sh` |
| 381 | 0 | 9 | `tests/sq-ensure-agents-md.test.sh` |
| 224 | 1 | 2 | `tests/sq-backend-herdr.test.sh` |
| 149 | 0 | 20 | `tests/sq-supervision-instructions.test.sh` |
| 74 | 0 | 6 | `tests/sq-composer-lib.test.sh` |
| 65 | 0 | 23 | `tests/sq-transition-lib.test.sh` |
| 15 | 0 | 13 | `tests/sq-pi-primary-types.test.sh` |

## Escopo

Cada worker usou uma raiz temporária modo-`0700` separada e `TMPDIR` e `TMP` privados.
O harness limpou valores ambiente de `SQUAD_BASE`, legado `SQUAD_HOME` e `SQUAD_*_OVERRIDE` para cada worker e verificou que a configuração global do Git ficou inalterada.
A falha de um candidato falha a execução agregada e exige investigação em vez de retry.

## Re-execução

```sh
bin/sq-test-isolation-proof.sh --list
bin/sq-test-isolation-proof.sh --jobs 4 --json /tmp/sq-isolation-proof.json
bin/sq-test-run.sh --check-coverage
```
