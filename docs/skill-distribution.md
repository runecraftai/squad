# Skill Distribution

How skills are packaged, discovered, and installed across Squad instances.

## Registry

`skills-registry.json` is the machine-readable catalog of all available skills.
Generate it with `bin/sq-skill-registry.sh --output skills-registry.json`.

Each entry contains: name, description, source, license, category (internal, public, user-invocable), and path.
The registry is the single source of truth for what exists and where it lives.

## CDN distribution

Skills can be served from a CDN for remote or fresh installations.
The registry file is the only artifact that needs to be hosted; individual skills are fetched on demand.

### Supported hosts

- **GitHub Pages** - serve `skills-registry.json` from the repo's `gh-pages` branch.
- **jsDelivr** - `https://cdn.jsdelivr.net/gh/<owner>/<repo>@<ref>/skills-registry.json`.
- **unpkg** - `https://unpkg.com/<package>/skills-registry.json`.
- **Any static host** - place the registry at a stable URL and configure Squad to fetch it.

### Publishing

1. Generate the registry: `bin/sq-skill-registry.sh --output skills-registry.json`.
2. Commit the registry to the distribution branch.
3. The CDN serves it at the branch's public URL.

### Consuming

1. Fetch the registry from the configured CDN URL.
2. Match the requested skill by name.
3. Download the skill's files from the same host path.

## Lockfile

`.skill-lock.json` tracks which skills are installed in this instance with SHA-256 integrity hashes.
Generate it with `bin/sq-skill-lockfile.sh`.
Verify installed skills against the lockfile with `bin/sq-skill-lockfile.sh --verify`.

The lockfile is per-instance (gitignored) and captures the current installed state, not the registry's catalog.
Use it to detect tampering, accidental changes, or drift from the expected installation.

## Snapshots

`bin/sq-skill-snapshot.sh <name>` captures a skill's current state before an update.
Snapshots live under `data/skill-snapshots/<name>/<timestamp>/` and auto-prune to 10 per skill.
Use snapshots to roll back a skill update that introduced a regression.
