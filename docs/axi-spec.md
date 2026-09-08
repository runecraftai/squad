# AXI provider methodology

AXI provider CLIs expose provider-native operations through predictable command and output contracts.
Each provider owns its implementation, authentication, and API mapping.

## Command patterns

The shared minimum command vocabulary is:

```text
<provider> list --type <type> [--state <state>] [--label <label>] [--limit <n>]
<provider> get <id>
<provider> poll --interval <ms> [--state <state>] [--changed-since <timestamp>]
<provider> create --type <type> --title <title> [--description <description>]
<provider> update <id> [--state <state>] [--assignee <assignee>]
<provider> comment <id> --body <body>
<provider> auth status|setup
<provider> capabilities
```

Provider-native commands may be added without changing this minimum vocabulary.
`sq-gh` retains its existing GitHub command families and adds `capabilities` as the discovery entry point.

## Output and schema versioning

Existing human-readable output remains the default for backward compatibility.
Pass `--json` after the command to request a JSON envelope.
Every JSON success envelope contains `$schema`, `version`, and `data` fields.
`version` is the provider CLI package version.
`$schema` identifies the AXI output contract and currently uses `https://axi.runecraft.ai/schemas/output/v1.json`.
Breaking output-contract changes increment the schema major version.
Additive fields and non-breaking changes remain within the same schema major version.

Example:

```json
{
  "$schema": "https://axi.runecraft.ai/schemas/output/v1.json",
  "version": "0.1.2",
  "data": "issues[1]:\n  number: 42"
}
```

The `data` value preserves the provider's established text representation while allowing callers to consume a stable JSON envelope.

## Errors

JSON errors use one shape for command failures and never expose raw provider stderr:

```json
{
  "$schema": "https://axi.runecraft.ai/schemas/output/v1.json",
  "version": "0.1.2",
  "error": {
    "code": "NOT_FOUND",
    "message": "Issue #42 does not exist",
    "help": ["Run `sq-gh issue list` to see available issues"]
  }
}
```

`code` is a stable machine-readable category.
`message` is a concise human-readable explanation.
`help` is optional and contains actionable suggestions.
Text-mode errors continue to use the existing AXI/TOON representation.

## Pagination

List commands accept provider-appropriate pagination controls.
`sq-gh` uses `--limit` for its existing GitHub list commands.
Providers implementing cursor pagination should expose `--page-size` and `--cursor` and return the next cursor in the JSON data.
A provider must document whether a returned page is complete and must not silently discard additional results.

## Capability discovery

`<provider> capabilities` is side-effect free and returns JSON regardless of the default output mode.
The response identifies the provider, supported operations, output formats, pagination controls, authentication probes, and schema version.
Capability names describe supported command families and operation verbs rather than implementation details.
Consumers should discover capabilities before using provider-specific optional operations.

For `sq-gh`, run:

```sh
sq-gh capabilities
```
