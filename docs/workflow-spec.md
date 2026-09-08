# WORKFLOW.md specification

`WORKFLOW.md` is the versioned, per-repository mechanical configuration manifest used by Squad.

## Format

The file must contain YAML front matter delimited by `---` and no prompt body.
The prompt for a task remains in the generated brief.
`WORKFLOW.md` may reference `AGENTS.md` by path, but must not duplicate its behavioral or safety rules.

The supported schema is versioned with `schema_version`.
The complete reference schema is in section 2.3 of `data/squad-symphony-architecture-recon/report.md`.
The current parser supports schema version `1.x.y`.
Unknown fields are rejected so misspellings cannot silently change execution.
Numeric timeout, retry, and backoff values are positive integers.
Secrets must be supplied through environment-variable indirection, never stored in this file.

## Placement and resolution

The repository manifest is `<project-root>/WORKFLOW.md` and is tracked with the project.
The private fallback is `<SQUAD_BASE>/config/workflow/<project-id>.md` and is gitignored.
The repository manifest wins when both files exist.
The private manifest is used only when the repository manifest is absent.
Projects without either manifest use Squad's existing built-in defaults.

Base-local files such as `config/crew-harness`, `config/backend`, and
`config/crew-dispatch.json` retain ownership of their existing axes.
A WORKFLOW.md manifest does not override or add axes to those files.

## Schema fields

All top-level sections below are optional except `schema_version`.
Within a section, some fields may be conditionally required as documented.
When tracker is present, kind is required.
kind must be one of: github, gitlab, jira, linear.
When a section is present, its values must follow the types validated by `bin/sq-workflow.sh`.

- `schema_version`: required semantic version string; currently `1.x.y`.
- `tracker`: issue-tracker configuration.
  - `kind`: `github`, `gitlab`, `jira`, or `linear`.
  - `provider.repo`: provider repository identifier such as `owner/repo`.
- `workspace`: workspace settings.
  - `root`: workspace root path; `$VAR` and `~` indirection may be used by consumers.
- `hooks`: lifecycle hooks represented as structured command arrays, not free-form shell strings.
  - `after_create`, `before_run`, `after_run`, and `before_remove` each accept `command` and `timeout_ms`.
  - `command` is a non-empty array of string arguments.
- `execution`: execution-attempt policy.
  - `max_retry_attempts`, `failure_backoff_base_ms`, and `max_retry_backoff_ms` are positive integers.
- `stall`: stall detection policy.
  - `timeout_ms` is a positive integer.
- `axi`: AXI provider selection.
  - `provider` identifies the provider-specific AXI integration.

Use `sq-workflow.sh parse` for compact JSON, `validate` for a validation check, and
`get <path> <dotted-key>` for a typed scalar or JSON getter.
