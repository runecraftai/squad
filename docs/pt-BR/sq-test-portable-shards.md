<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Shards portáteis de teste do Squad

`bin/sq-test-run.sh` é dono da composição e execução portátil de lanes.
`bin/sq-test-isolation-proof.sh` é dono do conjunto candidato provadamente isolado.

## Insumos de verificação

As durações atuais de candidatos vieram da prova concorrente de 2026-11-03 registrada em [sq-test-isolation-proof.md](sq-test-isolation-proof.md).
A prova rodou 23 candidatos com quatro workers e nenhuma falha.

| duration_ms | script |
|---:|---|
| 56122 | `tests/sq-decision-hold-lifecycle.test.sh` |
| 51141 | `tests/sq-arm-pretool-check.test.sh` |
| 34945 | `tests/sq-test-run.test.sh` |
| 32255 | `tests/sq-backend-herdr.test.sh` |
| 29727 | `tests/sq-cd-pretool-check.test.sh` |
| 28431 | `tests/sq-spawn-batch.test.sh` |
| 25426 | `tests/sq-crew-state.test.sh` |
| 14717 | `tests/sq-pr-merge.test.sh` |
| 11922 | `tests/sq-lint.test.sh` |
| 9606 | `tests/sq-brief.test.sh` |
| 9487 | `tests/sq-herdr-lab.test.sh` |
| 7930 | `tests/sq-grok-harness.test.sh` |
| 5753 | `tests/sq-send-settle.test.sh` |
| 2724 | `tests/sq-composer-ghost.test.sh` |
| 2402 | `tests/sq-send-popup-settle.test.sh` |
| 2143 | `tests/sq-send-strict.test.sh` |
| 2032 | `tests/sq-review-diff.test.sh` |
| 1750 | `tests/sq-tmux-submit-busy.test.sh` |
| 331 | `tests/sq-ensure-agents-md.test.sh` |
| 250 | `tests/sq-supervision-instructions.test.sh` |
| 153 | `tests/sq-transition-lib.test.sh` |
| 128 | `tests/sq-composer-lib.test.sh` |
| 28 | `tests/sq-pi-primary-types.test.sh` |

## Lanes paralelas

As duas lanes paralelas mantêm uma partição fixa daquele conjunto provado, então a estimativa de uma lane é a soma dos seus scripts medidos, não uma divisão longest-processing-time recém-rebalanceada.
A tabela abaixo registra as somas das pertenças atuais.

| Lane | Contagem de scripts | Duração estimada |
|---|---:|---:|
| `portable-parallel-1` | 10 | 155189 ms (~155.2 s) |
| `portable-parallel-2` | 13 | 174214 ms (~174.2 s) |
| desbalanceamento | | 19025 ms (~19.0 s) |

`bin/sq-test-run.sh` contém as pertenças exatas ordenadas em `list_portable_parallel_1` e `list_portable_parallel_2`.

## Resto serial portátil

`portable-serial` inclui todo `tests/*.test.sh` que não é nem provadamente isolado nem `real-herdr-gated`.
Ele mantém sentinela, lock, AFK, tmux real, daemon, ciclo de vida XO, bootstrap, opt-in live-harness, backend GUI e outro trabalho não provado serial.
A pertença é derivada em vez de enumerada, então um teste recém-adicionado cai aqui por padrão.

## Shards CI serial portáteis

Numa execução CI verde da suíte herdada, esse resto acumulou cerca de 19 minutos de tempo de script contra um timeout de job de 20 minutos (medido no CI do fork; o repositório Squad remede suas próprias durações de shard no M4).
O resto serial pode se aproximar do timeout do job, que é exatamente por isso que a divisão abaixo existe.
`portable-serial-<k>of<n>` divide-o entre `n` runners separados de CI.
Cada shard continua estritamente serial nele mesmo, e runners separados significam que dois desses scripts stateful nunca compartilham uma máquina, então a divisão não precisa de prova de isolamento de concorrência.

`bin/sq-test-run.sh` é dono de `n` e recusa qualquer lane cujo `of<n>` discorde dele.
`.github/workflows/ci.yml` deriva o mesmo `n` de `strategy.job-total` em vez de literal, então mudar a contagem de shards em qualquer um dos arquivos sem o outro falha a lane ruidosamente em vez de deixar parte da suíte exigida sem rodar.

A atribuição é bin packing longest-processing-time sobre dicas de duração por script embutidas em `bin/sq-test-run.sh`.
As dicas vieram do artefato `sq-test-timing-portable-serial` daquela execução em 2026-08-02, onde a lane rodou 69 scripts em 1143762 ms de trabalho serial.
Um script sem dica recebe o default conservador `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS`.
Dicas afetam apenas balanceamento: o guard de cobertura mantém a partição completa e disjunta digam elas o que disserem, então uma dica obsoleta custa um shard mais lento em vez de cobertura perdida.

| Lane | Contagem de scripts | Duração estimada |
|---|---:|---:|
| `portable-serial-1of4` | 15 | 285945 ms (~285.9 s) |
| `portable-serial-2of4` | 18 | 285944 ms (~285.9 s) |
| `portable-serial-3of4` | 17 | 285929 ms (~285.9 s) |
| `portable-serial-4of4` | 19 | 285944 ms (~285.9 s) |
| desbalanceamento | | 16 ms |

O único script mais longo, `tests/sq-pr-check-security.test.sh` a 199573 ms, é o piso para qualquer contagem de shards.

Atualize as dicas baixando os artefatos de timing por shard de uma execução CI verde, substituindo a tabela `portable_serial_weight_hints` em `bin/sq-test-run.sh` pelos pares medidos `path`/`duration_ms`, e atualizando a tabela acima:

```sh
gh run download <run-id> -R runecraftai/squad --pattern 'sq-test-timing-portable-serial-*' -D /tmp/sq-serial  # placeholder OQ-03
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/sq-serial/*.json | LC_ALL=C sort
bin/sq-test-run.sh --check-coverage
```

## Guard de cobertura

`bin/sq-test-run.sh --check-coverage` verifica que ambas as lanes paralelas particionam o conjunto provadamente isolado.
Ele também verifica que as lanes paralelas, a lane serial portátil, e a família real-Herdr são disjuntas e cobrem todo script `tests/*.test.sh`.
Ele verifica separadamente que os shards CI serial portáteis são não vazios, disjuntos e juntos iguais à lane serial portátil.

## Artefatos de timing

Shards portáteis, cada shard serial portátil, e a lane Herdr fazem upload de JSON de timing gerado pelo runner.
`bin/sq-test-run.sh --aggregate-json` cria o artefato combinado de sumário.
`.github/workflows/ci.yml` é dona dos nomes exatos de artefatos e da fiação de agregação.

## Pontos de entrada locais

[CONTRIBUTING.md](../../CONTRIBUTING.md) é dono da política local de testes e pontos de entrada comuns.
`bin/sq-test-run.sh --help` é dono dos nomes exatos de lanes, flags de seleção e mecânica limitada de `--jobs`.

## Timeouts

| Job | timeout-minutes | Racional |
|---|---:|---|
| portable parallel 1/2 | 10 | As somas medidas de shards ficam perto de três minutos e o timeout é um tripwire de travamento. |
| portable serial 1-4 | 15 | Cada shard balanceado fica perto de cinco minutos, deixando margem de aproximadamente 3x de tripwire de travamento. |
| Herdr | 40 | A lane real-Herdr mantém seu timeout dedicado. |

Timeouts são tripwires de travamento em vez de durações saudáveis esperadas.
