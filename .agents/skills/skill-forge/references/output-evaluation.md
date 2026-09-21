# Output Quality Evaluation

> Read this in Phase 5 (OPTIMIZE) when you need to verify that a skill actually improves output quality, not just that it triggers. Workflow skills especially benefit from this loop.

You wrote a skill, tried it on a prompt, and it seemed to work. But does it work reliably — across varied prompts, in edge cases, better than no skill at all? Structured evaluations (evals) answer these and give you a feedback loop for systematic improvement.

## Designing test cases

A test case has three parts:

- **Prompt:** a realistic user message.
- **Expected output:** a human-readable description of what success looks like.
- **Input files** (optional): files the skill needs to work with.

Store test cases in `evals/evals.json` inside the skill directory:

```json evals/evals.json
{
  "skill_name": "csv-analyzer",
  "evals": [
    {
      "id": 1,
      "prompt": "I have a CSV of monthly sales data in data/sales_2025.csv. Can you find the top 3 months by revenue and make a bar chart?",
      "expected_output": "A bar chart image showing the top 3 months by revenue, with labeled axes and values.",
      "files": ["evals/files/sales_2025.csv"]
    },
    {
      "id": 2,
      "prompt": "there's a csv in my downloads called customers.csv, some rows have missing emails — can you clean it up and tell me how many were missing?",
      "expected_output": "A cleaned CSV with missing emails handled, plus a count of how many were missing.",
      "files": ["evals/files/customers.csv"]
    }
  ]
}
```

Tips for good test prompts:

- Start with 2-3. Don't over-invest before seeing the first round of results.
- Vary the prompts: different phrasings, detail levels, formality.
- Cover edge cases. Include at least one boundary condition — malformed input, unusual request, or a case where the skill's instructions might be ambiguous.
- Use realistic context. Real users mention file paths, column names, personal context.

Don't define specific pass/fail checks yet. Add detailed assertions after you see what the first run produces.

## Running evals

The core pattern: run each test case twice — once **with the skill**, once **without it** (or with a previous version). This gives a baseline to compare against.

### Workspace structure

Organize eval results in a workspace directory alongside the skill. Each pass through the full eval loop gets its own `iteration-N/` directory. Within that, each test case gets an eval directory with `with_skill/` and `without_skill/` subdirectories:

```
csv-analyzer/
├── SKILL.md
└── evals/
    └── evals.json
csv-analyzer-workspace/
└── iteration-1/
    ├── eval-top-months-chart/
    │   ├── with_skill/
    │   │   ├── outputs/       # Files produced by the run
    │   │   ├── timing.json    # Tokens and duration
    │   │   └── grading.json   # Assertion results
    │   └── without_skill/
    │       ├── outputs/
    │       ├── timing.json
    │       └── grading.json
    ├── eval-clean-missing-emails/
    │   ├── with_skill/
    │   │   └── ...
    │   └── without_skill/
    │       └── ...
    └── benchmark.json         # Aggregated statistics
```

The main file you author is `evals/evals.json`. The rest (`grading.json`, `timing.json`, `benchmark.json`) are produced during the eval process.

### Spawning runs

Each run should start with a clean context — no leftover state from previous runs or skill development. In environments with subagents (Claude Code, etc.) this isolation comes naturally; without subagents, use a separate session per run.

For each run, provide:

- The skill path (or no skill for the baseline)
- The test prompt
- Any input files
- The output directory

Example instructions for a single with-skill run:

```
Execute this task:
- Skill path: /path/to/csv-analyzer
- Task: I have a CSV of monthly sales data in data/sales_2025.csv. Can you find the top 3 months by revenue and make a bar chart?
- Input files: evals/files/sales_2025.csv
- Save outputs to: csv-analyzer-workspace/iteration-1/eval-top-months-chart/with_skill/outputs/
```

For the baseline, same prompt but no skill path, saving to `without_skill/outputs/`.

When improving an existing skill, use the previous version as baseline. Snapshot before editing (`cp -r <skill-path> <workspace>/skill-snapshot/`) and point the baseline run at the snapshot.

### Capturing timing data

Record the token count and duration per run:

```json timing.json
{
  "total_tokens": 84852,
  "duration_ms": 23332
}
```

A skill that dramatically improves output but triples token usage is a different tradeoff than one that's both better and cheaper.

## Writing assertions

Assertions are verifiable statements about what the output should contain. Add them after you see your first round of outputs — you often don't know what "good" looks like until the skill has run.

Good assertions:

- "The output file is valid JSON" — programmatically verifiable.
- "The bar chart has labeled axes" — specific and observable.
- "The report includes at least 3 recommendations" — countable.

Weak assertions:

- "The output is good" — too vague.
- "The output uses exactly the phrase 'Total Revenue: $X'" — too brittle; correct output with different wording would fail.

Not everything needs an assertion. Style, visual design, "feels right" — those are better caught in human review. Reserve assertions for things checkable objectively.

Add to each test case in `evals/evals.json`:

```json
{
  "id": 1,
  "prompt": "...",
  "expected_output": "...",
  "files": ["evals/files/sales_2025.csv"],
  "assertions": [
    "The output includes a bar chart image file",
    "The chart shows exactly 3 months",
    "Both axes are labeled",
    "The chart title or caption mentions revenue"
  ]
}
```

## Grading outputs

Evaluate each assertion against the actual outputs and record **PASS** or **FAIL** with specific evidence. The evidence should quote or reference the output, not just state an opinion.

Simplest approach: give outputs and assertions to an LLM and ask it to evaluate each one. For code-checkable assertions (valid JSON, correct row count, file exists with expected dimensions), use a verification script — more reliable than LLM judgment for mechanical checks, and reusable across iterations.

```json grading.json
{
  "assertion_results": [
    {
      "text": "The output includes a bar chart image file",
      "passed": true,
      "evidence": "Found chart.png (45KB) in outputs directory"
    },
    {
      "text": "The chart shows exactly 3 months",
      "passed": true,
      "evidence": "Chart displays bars for March, July, November"
    },
    {
      "text": "Both axes are labeled",
      "passed": false,
      "evidence": "Y-axis labeled 'Revenue ($)' but X-axis has no label"
    },
    {
      "text": "The chart title or caption mentions revenue",
      "passed": true,
      "evidence": "Chart title reads 'Top 3 Months by Revenue'"
    }
  ],
  "summary": {
    "passed": 3,
    "failed": 1,
    "total": 4,
    "pass_rate": 0.75
  }
}
```

### Grading principles

- **Require concrete evidence for a PASS.** Don't give the benefit of the doubt. If "includes a summary" and the output has a section titled "Summary" with one vague sentence, that's a FAIL.
- **Review the assertions themselves, not just results.** While grading, notice when assertions are too easy (always pass), too hard (always fail), or unverifiable.

For comparing two skill versions, try **blind comparison**: present both outputs to an LLM judge without revealing which is which. Judge scores holistic qualities — organization, formatting, polish — free from bias.

## Aggregating results

Once every run in the iteration is graded, compute summary statistics per configuration and save to `benchmark.json`:

```json benchmark.json
{
  "run_summary": {
    "with_skill": {
      "pass_rate": { "mean": 0.83, "stddev": 0.06 },
      "time_seconds": { "mean": 45.0, "stddev": 12.0 },
      "tokens": { "mean": 3800, "stddev": 400 }
    },
    "without_skill": {
      "pass_rate": { "mean": 0.33, "stddev": 0.10 },
      "time_seconds": { "mean": 32.0, "stddev": 8.0 },
      "tokens": { "mean": 2100, "stddev": 300 }
    },
    "delta": {
      "pass_rate": 0.50,
      "time_seconds": 13.0,
      "tokens": 1700
    }
  }
}
```

`delta` tells you what the skill costs (more time, more tokens) and what it buys (higher pass rate). A skill that adds 13 seconds for a 50-point pass-rate jump is probably worth it. A skill that doubles tokens for 2 points might not be.

Standard deviation is meaningful only with multiple runs per eval. In early iterations with 2-3 cases and single runs, focus on raw pass counts and delta.

## Analyzing patterns

Aggregate statistics can hide important patterns. After computing benchmarks:

- **Remove or replace assertions that always pass in both configurations.** They don't tell you anything.
- **Investigate assertions that always fail in both.** Either the assertion is broken, the test case is too hard, or the assertion checks the wrong thing.
- **Study assertions that pass with-skill but fail without.** That's where the skill is clearly adding value. Understand *why* — which instructions or scripts made the difference?
- **Tighten instructions when results are inconsistent.** High stddev means flaky eval or ambiguous skill instructions. Add examples or more specific guidance.
- **Check time and token outliers.** If one eval takes 3x longer, read its execution transcript to find the bottleneck.

## Reviewing results with a human

Assertion grading catches a lot, but only what you thought to check for. A human reviewer catches issues you didn't anticipate. For each test case, review the actual outputs alongside the grades.

Record feedback per test case in `feedback.json` next to the eval directories:

```json feedback.json
{
  "eval-top-months-chart": "The chart is missing axis labels and the months are in alphabetical order instead of chronological.",
  "eval-clean-missing-emails": ""
}
```

Empty feedback means the output looked fine. Actionable feedback ("missing axis labels") beats vague ("looks bad").

## Iterating on the skill

After grading and reviewing, three sources of signal:

- **Failed assertions** point to specific gaps.
- **Human feedback** points to broader quality issues.
- **Execution transcripts** reveal *why* things went wrong.

The most effective way to turn these into improvements: give all three — along with the current `SKILL.md` — to an LLM and ask it to propose changes. When prompting the LLM, include these guidelines:

- **Generalize from feedback.** Fixes should address underlying issues broadly, not narrow patches for specific examples.
- **Keep the skill lean.** Fewer, better instructions often outperform exhaustive rules. If pass rates plateau despite adding rules, the skill may be over-constrained — try removing instructions.
- **Explain the why.** Reasoning-based instructions ("Do X because Y tends to cause Z") work better than rigid directives.
- **Bundle repeated work.** If every test run independently wrote a similar helper script, that's the signal to bundle it.

### The loop

1. Give the eval signals and current `SKILL.md` to an LLM; ask it to propose improvements.
2. Review and apply changes.
3. Rerun all test cases in a new `iteration-<N+1>/` directory.
4. Grade and aggregate.
5. Review with a human. Repeat.

Stop when you're satisfied, feedback is consistently empty, or you're not seeing meaningful improvement between iterations.
