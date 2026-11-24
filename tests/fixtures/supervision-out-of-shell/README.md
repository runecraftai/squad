# Away-mode supervision incident fixtures

Pinned evidence for the `squad-supervision-out-of-shell` migration. These files
are the oracle for the state-owner steps, not a description of desired
behaviour: they record what a real absence produced so a later step can prove a
different result on the same input.

Provenance: `data/squad-supervision-out-of-shell/report.md` in the primary
base, and the preserved return log `/tmp/pi-bg/34545-bg23.log` from the
2026-11-24 return.

## `closed-window-notice.txt`

The exact repeated ledger item from that return. One line, byte-identical to the
body the presentation printed 25,028 times.

## Measured counts from that one return

The presentation's own counts line reported:

```
counts: escalation=1 routine=25087 daemon-notice=1
```

Distinct routine bodies, measured with
`awk '/\[routine\]/{sub(/^ *[0-9]+\. [0-9-]+ [0-9:]+ \[routine\] /,""); print}' "$LOG" | sort | uniq -c | sort -rn`:

| Occurrences | Routine body |
| --- | --- |
| 25028 | the pinned closed-window notice |
| 58 | `signal: <state>/<task>.turn-ended -> routine signal:` |
| 1 | the mission's real conclusion |

So 25,028 of 25,087 routine rows, 99.7% of the ledger, are one notification
about a window the classifier already knew was closed.

Two honest corrections to the dossier's summary, because the fixtures must be
the measured numbers rather than a rounded story:

- The dossier says 25,089 ledger entries. The presentation reports 25,087 routine
  plus 1 escalation, which is 25,088 ledger rows. The extra presented row is a
  drained `afk-*` queued record (`daemon-notice`), which is not a ledger row.
- The dossier reports a 39-minute return. The log is the durable record of that
  run; the wall time itself is not reconstructible from it, so the timing bound
  in the follow-up must be measured again on a replay rather than inherited.

## Fixture matrix state

The recon's step 0 asks for a matrix of adversarial cases. What this change
pins, and where each case lives:

| Case | Pinned now | Owner |
| --- | --- | --- |
| second process group | `tests/sq-op-contain.test.sh` (`group` variant) | containment |
| own session | `tests/sq-op-contain.test.sh` (`session` variant) | containment |
| TERM-ignoring child | `tests/sq-op-contain.test.sh` (both variants trap TERM) | containment |
| inherited stdout holding the bound open | `tests/sq-op-contain.test.sh` (`session` and `group` variants: the resisting descendant inherits the relayed streams and the operation still returns inside its bound) | containment |
| runner killed mid-operation | `tests/sq-op-contain.test.sh` | containment |
| manager unavailable | Go test `TestMissingManagerRefusesBeforeLaunch` | containment |
| reply lost after the backend accepted the action | Go test `TestUnknownResultIsNotRetried` | containment |
| neighbouring queue consumed | not pinned | state owner (recon steps 2 and 5) |
| clock rollback | not pinned | state owner (recon step 3) |
| display-limit reduction re-exposing a row | not pinned | state owner (recon step 3) |
| unreadable or rotated status file | not pinned | state owner (recon steps 3 and 4) |
| append during the final fold | not pinned | state owner (recon step 4) |
| failed fsync | not pinned | state owner (recon step 2) |
| broken presentation pipe | not pinned | state owner (recon step 3) |

A case marked not pinned has no owning implementation yet. Pinning it before its
step exists would assert today's defect as expected behaviour, which is the
opposite of an oracle.
