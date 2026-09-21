# Authoring Patterns

> Best practices for writing skill bodies. Read this when drafting a new skill and deciding between flexible guidance and prescriptive steps.

## Start from real expertise

A common pitfall: asking an LLM to generate a skill without providing domain-specific context. The result is vague, generic procedures ("handle errors appropriately", "follow best practices for authentication") rather than the specific API patterns, edge cases, and project conventions that make a skill valuable.

Effective skills are grounded in real expertise. Two ways to feed it in:

**Extract from a hands-on task.** Do the real work in a session with the agent, providing context, corrections, and preferences. Then extract the reusable pattern. Capture:

- Steps that worked (the successful sequence)
- Corrections you made ("use library X instead of Y", "check for edge case Z")
- Input/output formats (what data went in, what came out)
- Context you provided (project facts, conventions, constraints)

**Synthesize from existing project artifacts.** Feed the LLM the actual material, not generic articles. A data-pipeline skill built from your team's incident reports and runbooks will outperform one built from "data engineering best practices" because it captures your schemas, failure modes, and recovery procedures. Good sources:

- Internal documentation, runbooks, style guides
- API specifications, schemas, configuration files
- Code review comments and issue trackers
- Version control history, especially patches and fixes
- Real-world failure cases and their resolutions

## Refine with real execution

The first draft usually needs refinement. Run the skill against real tasks, then feed all results — not just failures — back into the creation process. Ask: what triggered false positives? What was missed? What could be cut?

Read execution traces, not just final outputs. Common causes of wasted steps:

- Instructions too vague (agent tries several approaches before finding one)
- Instructions that don't apply to the current task (agent follows them anyway)
- Too many options without a clear default

Even a single pass of execute-then-revise noticeably improves quality. Complex domains often benefit from several.

## Spending context wisely

Once a skill activates, its full `SKILL.md` body loads into the agent's context window alongside conversation history, system context, and other active skills. Every token in your skill competes for the agent's attention.

### Add what the agent lacks, omit what it knows

Focus on what the agent wouldn't know without your skill: project conventions, domain procedures, non-obvious edge cases, the particular tools or APIs to use. Don't explain what a PDF is, how HTTP works, or what a database migration does.

```markdown
<!-- Too verbose — the agent already knows what PDFs are -->
## Extract PDF text

PDF (Portable Document Format) files are a common file format that contains
text, images, and other content. To extract text from a PDF, you'll need to
use a library. pdfplumber is recommended because it handles most cases well.

<!-- Better — jumps to what the agent wouldn't know -->
## Extract PDF text

Use pdfplumber for text extraction. For scanned documents, fall back to
pdf2image with pytesseract.
```

Ask: "Would the agent get this wrong without this instruction?" If no, cut it. If unsure, test it. If the agent handles the whole task well without the skill, the skill may not be adding value.

### Design coherent units

Skills are functions: encapsulate a coherent unit of work that composes well with other skills.

- Too narrow → multiple skills must load for one task (overhead, conflicting instructions).
- Too broad → hard to activate precisely.

A skill for "query a database and format results" is one coherent unit. A skill that also covers database administration is doing too much.

### Aim for moderate detail

Comprehensive skills can hurt — the agent struggles to extract what's relevant, may pursue unproductive paths from instructions that don't apply. Concise, stepwise guidance with a working example outperforms exhaustive documentation. When you find yourself covering every edge case, consider whether most are better handled by the agent's own judgment.

### Structure with progressive disclosure

Keep `SKILL.md` under 500 lines and 5000 tokens — the core the agent needs on every run. When more is legitimately needed, move detail to `references/` and tell the agent **when** to load each file.

> "Read `references/api-errors.md` if the API returns a non-200 status code" is more useful than a generic "see references/ for details."

## Calibrating control

Not every part needs the same level of prescriptiveness. Match specificity to fragility.

### Match specificity to fragility

**Give the agent freedom** when multiple approaches are valid and the task tolerates variation. Explaining *why* often beats rigid directives.

```markdown
## Code review process

1. Check all database queries for SQL injection (use parameterized queries)
2. Verify authentication checks on every endpoint
3. Look for race conditions in concurrent code paths
4. Confirm error messages don't leak internal details
```

**Be prescriptive** when operations are fragile, consistency matters, or a specific sequence must be followed.

```markdown
## Database migration

Run exactly this sequence:

```bash
python scripts/migrate.py --verify --backup
```

Do not modify the command or add additional flags.
```

Most skills have a mix. Calibrate each part independently.

### Provide defaults, not menus

When multiple tools or approaches could work, pick a default and mention alternatives briefly.

```markdown
<!-- Too many options -->
You can use pypdf, pdfplumber, PyMuPDF, or pdf2image...

<!-- Clear default with escape hatch -->
Use pdfplumber for text extraction:

```python
import pdfplumber
```

For scanned PDFs requiring OCR, use pdf2image with pytesseract instead.
```

### Favor procedures over declarations

A skill should teach the agent *how to approach* a class of problems, not *what to produce* for a specific instance.

```markdown
<!-- Specific answer — only useful for this exact task -->
Join the `orders` table to `customers` on `customer_id`, filter where
`region = 'EMEA'`, and sum the `amount` column.

<!-- Reusable method — works for any analytical query -->
1. Read the schema from `references/schema.yaml` to find relevant tables
2. Join tables using the `_id` foreign key convention
3. Apply any filters from the user's request as WHERE clauses
4. Aggregate numeric columns as needed and format as a markdown table
```

Specific details (output templates, hard constraints like "never output PII", tool-specific instructions) are valuable. The point: the *approach* should generalize even when individual details are specific.

## Patterns for effective instructions

### Gotchas sections

The highest-value content in many skills is a list of gotchas — environment-specific facts that defy reasonable assumptions. These aren't general advice; they're concrete corrections to mistakes the agent will make without being told.

```markdown
## Gotchas

- The `users` table uses soft deletes. Queries must include
  `WHERE deleted_at IS NULL` or results will include deactivated accounts.
- The user ID is `user_id` in the database, `uid` in the auth service,
  and `accountId` in the billing API. All three refer to the same value.
- The `/health` endpoint returns 200 as long as the web server is running,
  even if the database connection is down. Use `/ready` to check full
  service health.
```

Keep gotchas in `SKILL.md` where the agent reads them before encountering the situation. A reference file works if you tell the agent when to load it, but for non-obvious issues, the agent may not recognize the trigger.

When the agent makes a mistake you have to correct, add the correction to the gotchas section. This is one of the most direct ways to improve a skill iteratively.

### Templates for output format

When the agent must produce output in a specific format, provide a template. Agents pattern-match well against concrete structures. Short templates can live inline; longer ones go in `assets/`.

```markdown
## Report structure

Use this template, adapting sections as needed:

```markdown
# [Analysis Title]

## Executive summary
[One-paragraph overview of key findings]

## Key findings
- Finding 1 with supporting data
- Finding 2 with supporting data

## Recommendations
1. Specific actionable recommendation
2. Specific actionable recommendation
```
```

### Checklists for multi-step workflows

An explicit checklist helps the agent track progress and avoid skipping steps, especially when steps have dependencies or validation gates.

```markdown
## Form processing workflow

Progress:
- [ ] Step 1: Analyze the form (run `scripts/analyze_form.py`)
- [ ] Step 2: Create field mapping (edit `fields.json`)
- [ ] Step 3: Validate mapping (run `scripts/validate_fields.py`)
- [ ] Step 4: Fill the form (run `scripts/fill_form.py`)
- [ ] Step 5: Verify output (run `scripts/verify_output.py`)
```

### Validation loops

Instruct the agent to validate its own work before moving on: do, validate, fix, repeat.

```markdown
## Editing workflow

1. Make your edits
2. Run validation: `python scripts/validate.py output/`
3. If validation fails:
   - Review the error message
   - Fix the issues
   - Run validation again
4. Only proceed when validation passes
```

A reference document can also be the "validator" — instruct the agent to check its work against the reference before finalizing.

### Plan-validate-execute

For batch or destructive operations: create an intermediate plan, validate it against a source of truth, then execute.

```markdown
## PDF form filling

1. Extract form fields: `python scripts/analyze_form.py input.pdf` → `form_fields.json`
2. Create `field_values.json` mapping each field to its intended value
3. Validate: `python scripts/validate_fields.py form_fields.json field_values.json`
4. If validation fails, revise `field_values.json` and re-validate
5. Fill the form: `python scripts/fill_form.py input.pdf field_values.json output.pdf`
```

The key ingredient is step 3: a validation script that checks the plan against the source of truth. Errors like "Field 'signature_date' not found — available fields: customer_name, order_total, signature_date_signed" give the agent enough information to self-correct.

### Bundling reusable scripts

When iterating on a skill, compare execution traces across test cases. If the agent independently reinvents the same logic each run (building charts, parsing a format, validating output), that's the signal to write a tested script once and bundle it. See [scripts-guide.md](scripts-guide.md).
