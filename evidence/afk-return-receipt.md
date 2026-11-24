# Away-mode return regression evidence

The 2026-11-24 return took 39 minutes and produced 25,087 routine entries, including 25,028 repeats about a finished window.

The same three-wake fixture ran against base `44fadc58` and the fixed daemon:

```text
ok - baseline three-wake fixture: ledger rows=3, counted drops=0
ok - fixed three-wake fixture: ledger rows=0, counted drops=3
```

The return fixture reproduced the pathological routine ledger plus one escalation, with the escalation still listed:

```text
ok - 25,087 routine rows plus one escalation: 1s (15s deadline), 2,000 parsed, 23,088 not read
```

The crash fixture used both ledger evidence and a queue-only escalation:

```text
crash after build: presented=0 pending=catchup-1795523502-43dcdf7af82b-xPoSKQ
replay: presented=1 pending=catchup-1795523502-43dcdf7af82b-xPoSKQ
ack: consumed=catchup-1795523502-43dcdf7af82b-xPoSKQ (cleanup interrupted)
ok - post-ack cleanup and later return: presented=0
```
