<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Prova de isolamento de testes do Squad

Este registro é a prova de isolamento concorrente para o conjunto portátil de candidatos paralelos.
`bin/sq-test-isolation-proof.sh` é o harness autoritativo e `docs/sq-test-isolation-proof.json` é o resultado legível por máquina.
`bin/sq-test-run.sh` é dono da partição de lanes de produção.

## Verificação

- Data: 2026-11-03
- Comando: `unshare -m --map-root-user` em volta de `bin/sq-test-isolation-proof.sh --jobs 4 --json docs/sq-test-isolation-proof.json`, com `/usr/bin/herdr` escondido por um mount overlay de `/usr/bin`
- Resultado: `SQUAD_ISOLATION_SUMMARY total=23 failed=0 concurrency=4 duration_ms=160325`

| Campo | Valor |
|---|---|
| `run_id` | `sq-isolation-1793699744983-4020941` |
| `started_at` | `2026-11-03T09:55:44Z` |
| `finished_at` | `2026-11-03T09:58:25Z` |
| concorrência | 4 |
| candidatos | 23 |
| falhas | 0 |
| duração de parede | 160325 ms |

Todos os candidatos passaram, o que exige um `PATH` sem `herdr`: `tests/sq-backend-herdr.test.sh` tem um caso de recusa sem herdr que não pode passar enquanto o binário está instalado.
Esta execução, portanto, escondeu `/usr/bin/herdr` atrás de um mount overlay de `/usr/bin` num namespace de mount privado (`unshare -m --map-root-user`).
Mascarar o binário com `/dev/null` não é equivalente, porque o adaptador passa a relatar uma falha de permissão em vez de um CLI ausente.
As durações são de relógio de parede numa máquina de desenvolvimento compartilhada, então leia-as como limites superiores conservadores, não como uma base de máquina ociosa.

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
| 56122 | 0 | 8 | `tests/sq-decision-hold-lifecycle.test.sh` |
| 51141 | 0 | 1 | `tests/sq-arm-pretool-check.test.sh` |
| 34945 | 0 | 21 | `tests/sq-test-run.test.sh` |
| 32255 | 0 | 2 | `tests/sq-backend-herdr.test.sh` |
| 29727 | 0 | 4 | `tests/sq-cd-pretool-check.test.sh` |
| 28431 | 0 | 19 | `tests/sq-spawn-batch.test.sh` |
| 25426 | 0 | 7 | `tests/sq-crew-state.test.sh` |
| 14717 | 0 | 14 | `tests/sq-pr-merge.test.sh` |
| 11922 | 0 | 12 | `tests/sq-lint.test.sh` |
| 9606 | 0 | 3 | `tests/sq-brief.test.sh` |
| 9487 | 0 | 11 | `tests/sq-herdr-lab.test.sh` |
| 7930 | 0 | 10 | `tests/sq-grok-harness.test.sh` |
| 5753 | 0 | 17 | `tests/sq-send-settle.test.sh` |
| 2724 | 0 | 5 | `tests/sq-composer-ghost.test.sh` |
| 2402 | 0 | 16 | `tests/sq-send-popup-settle.test.sh` |
| 2143 | 0 | 18 | `tests/sq-send-strict.test.sh` |
| 2032 | 0 | 15 | `tests/sq-review-diff.test.sh` |
| 1750 | 0 | 22 | `tests/sq-tmux-submit-busy.test.sh` |
| 331 | 0 | 9 | `tests/sq-ensure-agents-md.test.sh` |
| 250 | 0 | 20 | `tests/sq-supervision-instructions.test.sh` |
| 153 | 0 | 23 | `tests/sq-transition-lib.test.sh` |
| 128 | 0 | 6 | `tests/sq-composer-lib.test.sh` |
| 28 | 0 | 13 | `tests/sq-pi-primary-types.test.sh` |

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
