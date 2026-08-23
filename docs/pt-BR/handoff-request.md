<!-- Portuguese translation. The English original is authoritative; report discrepancies rather than editing the original. -->

# Requests duráveis de handoff de nova sessão

Este é o contrato atual autoritativo para o hook determinístico de sugestão de
nova sessão.
A preferência do comandante (2026-08-10) exige: no fechamento de um marco (um PR de
marco mesclado ou uma fila de voos drenada), o Squad roda a varredura debrief e
apresenta um cartão de handoff, então PERGUNTA ao comandante se deve iniciar uma nova
sessão; o comandante é dono da decisão `/new` e ela nunca pode auto-iniciar.
Esse mecanismo torna a sugestão determinística em vez de ad hoc.
O contrato operacional do lado do Squad no fluxo é a skill
[`session-handoff`](../../.agents/skills/session-handoff/SKILL.md), e a própria varredura
debrief continua de propriedade da skill `debrief`.

## Fila durável

`state/.handoff-queue` é uma fila por base append-only de fechamentos de marcos,
um registro por linha, separado por TAB:

```
ts<TAB>seq<TAB>kind<TAB>key<TAB>state<TAB>payload
```

- `ts` é o segundo epoch em que o registro foi escrito.
- `seq` é um contador monotônico por base (`state/.handoff-queue.seq`) que nunca
  é reutilizado.
- `kind` é o motivo do fechamento de marco: `pr-merged` ou `queue-drained`.
- `key` é um slug único de marco (`[A-Za-z0-9_.-]`). O `add` nunca cria um segundo
  registro para o mesmo `kind`+`key` em qualquer estado, então a garantia
  uma-por-marco vale na fonte.
- `state` é o ciclo de vida do registro: `pending` -> `surfaced` -> `resolved`.
- `payload` é o contexto do marco (tabs, newlines e carriage returns são colapsados
  em espaços pelo writer, para que o formato wire TAB não quebre).

Toda mutação roda sob o lock compartilhado `state/.handoff-queue.lock` (os helpers
portáveis de lock de `bin/sq-stand-to-lib.sh`), então um surfaver concorrente nunca
pode observar ou marcar duas vezes uma transição parcial.
Cada base tem sua própria fila: uma base XO registra e expõe apenas os próprios
fechamentos de marco dela no próprio `state/`, exatamente como todo outro registro
durável local à base.

## Writer

`bin/sq-handoff-request.sh` é o único dono do formato wire e da máquina de estados.

```sh
bin/sq-handoff-request.sh add <kind> <key> <payload...>
bin/sq-handoff-request.sh resolve <key>
bin/sq-handoff-request.sh list [--all|--pending|--surfaced|--open]
```

- `add` escreve um registro `pending` e é idempotente por `kind`+`key`: uma duplicata
  deixa o registro existente intacto, não imprime nada e sai 0, então uma escrita de
  fechamento de marco repetida não pode duplicar o cartão.
- `resolve` move o registro de `key` para `resolved`; o Squad o executa quando o
  comandante responde, seja sim ou não.
- `list` imprime registros do mais novo para o mais antigo; o filtro padrão `--open`
  (pendentes e expostos, tudo ainda não resolvido) é o conjunto ainda acionável que um
  início de sessão precisa ver.

## Surfacer e a garantia uma-por-marco

`bin/sq-handoff-surface.sh` é a única autoridade de exposição.
Sob o lock da fila ele move atomicamente todo registro `pending` para `surfaced`
e imprime o cartão de handoff para cada registro que acabou de expor.
Uma segunda chamada não encontra nada pendente e não imprime nada.
Essa marcação atômica é o que faz o cartão aparecer exatamente uma vez por marco,
não importa quantas superfícies corram em paralelo.
O surfacer delimita-se a um checkout primário real com
`bin/sq-primary-scope-lib.sh`, então um worktree de operador ou recon que rode o mesmo
arquivo rastreado fica silencioso.

O cartão nomeia o marco, o motivo e o contexto, e carrega o comando exato
`sq-handoff-request.sh resolve <key>` para que o registro possa ser fechado
duravelmente depois que o comandante responder.

## Superfícies de hook

Duas superfícies primárias chamam o surfacer; a que rodar primeiro apresenta o cartão,
e toda chamada posterior fica silenciosa.

- **Digest de início de sessão** (`bin/sq-session-start.sh`): a seção de estado da
  unidade emite uma subseção `HANDOFF REQUESTS` que roda o surfacer (marcando e
  imprimindo qualquer cartão pendente) e depois lista os registros ainda abertos, para
  que uma pergunta apresentada-mas-sem-resposta continue visível entre restarts.
  Uma sessão read-only nunca roda o surfacer; ela só lista.
- **Extensão turn-end do Pi** (`.pi/extensions/sq-primary-turnend-guard.ts`): o handler
  `agent_settled` roda o surfacer após cada execução do agente e entrega um cartão
  impresso como acordo operacional tipado `handoff-request` via
  `pi.sendUserMessage(..., { deliverAs: "followUp" })`, exatamente como o turn-end guard
  entrega seu banner.
  O acordo é tipado estruturalmente através de `bin/sq-operational-input.sh`, então o
  Reporting não trata um cartão injetado como mensagem do comandante.

Outros harnesses primários herdam a superfície de início de sessão, que é
agnóstica ao harness: seus adaptadores de abertura de sessão já rodam o digest.

## Kind de acordo operacional

`handoff-request` é um kind atual de construção do protocolo canônico de input
operacional, de propriedade de `bin/sq-operational-input.sh` e espelhado em
`.pi/extensions/lib/sq-operational-input.ts`.
Ele existe para que o cartão injetado seja tipado estruturalmente e nunca confundido com
texto escrito pelo comandante.
A skill `session-handoff` é dona de tratar o acordo e fechar o registro.

## Cobertura de regressão

`tests/sq-handoff-queue.test.sh` cobre o formato do registro, a idempotência e validação
do writer, a marca atômica uma-por-marco do surfacer (incluindo corrida de surfacers
concorrentes), o silêncio do escopo primário e a sanitização do payload.
`tests/sq-turnend-guard.test.sh` prova que a extensão Pi injeta um cartão pendente
exatamente uma vez como follow-up tipado `handoff-request`, e `tests/sq-session-start.test.sh`
prova que o digest expõe um cartão pendente uma vez e mantém a pergunta aberta listada
em inícios posteriores.
`tests/sq-operational-input.test.sh` fixa `handoff-request` como kind atual de
construção, e `tests/sq-pi-primary-types.test.sh` faz typecheck da mudança na extensão.
