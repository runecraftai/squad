# Knowledge pass template

Fill once per delivery, in the user's language.
Keep paths, symbols, commands, and identifiers verbatim.
Budget: 5-12 lines per section, about 120 lines total.

## Three-line summary

- **Problem:** one sentence, the symptom the user could observe.
- **Mechanism:** one sentence, how the change removes the symptom.
- **Outcome:** one sentence, what is true now that was not before, or `[unverified]`.

## 1. Problem solved

- **Symptom:** what was seen, by whom, where it surfaced.
- **Before:** behavior and its consequence - `path:line`.
- **After:** behavior now - `path:line`.
- **Not touched:** what the change deliberately leaves alone, and why that is safe.

## 2. Rules

One line per rule, each with its enforcement site.
Split domain rules from engineering constraints.

- `domain rule` - enforced at `path:line`.
- `invariant` - enforced at `path:line`.
- `compatibility / security / performance constraint` - `path:line` or `[unverified]`.

## 3. Flow

Numbered hops from entry to outcome:

1. `path:line` - what arrives, what it returns or decides.
2. `path:line` - ...
3. `path:line` - the branch that changed behavior.

**Failure path:** when `<condition>` fails, `<outcome>` at `path:line`.

## 4. Decisions

Repeat per decision that a reviewer would question:

- **Chose:** what, at `path:line`.
- **Rejected:** the alternative, and why it lost.
- **Would change if:** the condition under which the rejected option wins.
- **Cost accepted:** what the choice makes harder or slower.
- **Risk:** residual risk - `[inferred]` when reconstructed rather than observed.

## 5. Verification

| Proof | Command or test | Covers | Does not cover |
|---|---|---|---|
| ... | ... | ... | ... |

The last column is never empty.
State plainly anything that was not run.

## Understanding check plan

Pick 3-5, ordered by leverage. Ask one at a time, and only after the pass is delivered.

1. **Flow:** "If `<input or state>` arrives at `<path:line>`, what happens between there and `<outcome>`?"
2. **Rule or edge case:** "What stops `<bad case>`? Where is that enforced?"
3. **Decision:** "Why `<chosen>` instead of `<rejected>`? What breaks with the other?"
4. **Verification gap:** "What is the most likely regression this delivery does not catch?"

Grade each answer silently as understood, partial, or wrong; adapt the next question to the answer.
Close with: confirmed / weak / unverified.
