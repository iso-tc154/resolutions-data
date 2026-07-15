# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

A **data repository** (not a software project) holding ISO/TC 154's formal
resolutions as structured YAML. There is no application code, no test suite,
no build step. The only "code" is two one-shot migration scripts under
`scripts/`.

The YAML follows the **Edoxen** information model — a generic meeting /
agenda / decision model whose canonical LutaML definition lives at
https://github.com/edoxen/edoxen-model. The Ruby gem `edoxen` (pinned in
the `Gemfile`, currently `~> 0.8`) implements that model and provides the
`edoxen` CLI used for validation and normalization. Model and gem are
versioned independently: the **model** is at `1.0` (initial release — per-
field Localized wire shape per ISO 24229); the **gem** that implements it
is at `0.8.1` (the first released implementation of model 1.0).

## Layout

- `plenary/` — plenary-meeting resolutions (10th–44th, files `plenary-NN.yaml`)
- `ballots/` — committee-internal ballot resolutions, one file per year
- `7372ma/` — ISO 7372 maintenance-agency resolutions
- `legacy/` — pre-migration originals, mirrored under `legacy/{plenary,ballots,7372ma}/`. **Never edit or delete** — these are the source-preservation backups the migration scripts wrote (mirrors the global "never delete source" rule).
- `reference-docs/` — original PDFs/DOCs the YAML was transcribed from. Treat as read-only source material.
- `scripts/` — one-shot migration scripts (see "Migration history" below).
- `.github/workflows/validate.yml` — CI runs `edoxen validate` on every push/PR.

## Common commands

```sh
bundle install                                  # first-time only

# Validate (CI runs exactly this glob):
bundle exec edoxen validate "{plenary,ballots,7372ma}/*.yaml"
bundle exec edoxen validate plenary/plenary-43.yaml   # single file

# Normalize (re-emit in canonical form; always run before committing edits):
bundle exec edoxen normalize "plenary/*.yaml" --inplace
```

`bundle exec edoxen` with no args prints the Thor command list, including
the meeting-side commands (`validate-meetings`, `normalize-meetings`) which
are not used here — this repo only carries Decision documents.

## Wire format (Edoxen Model 1.0 — per-field Localized)

Every YAML file is a `DecisionCollection`:

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/edoxen/edoxen/refs/heads/main/schema/edoxen.yaml
---
metadata:
  title:
  - spelling: eng
    value: Resolutions of the 43rd plenary meeting of ISO/TC 154
  date: '2024-10-25'
  source: ISO/TC 154 Secretariat
decisions:
- identifier:
  - prefix: ISO/TC 154
    number: P-2024-01
  kind: resolution
  status: decided
  dates:
  - date: '2024-10-25'
    type: adoption
  categories: [...]
  title:
  - spelling: eng
    value: ...
  subject:
  - spelling: eng
    value: ...
  actions:
  - type: resolves
    date_effective:
      date: '2024-10-25'
      type: effective
    message:
    - spelling: eng
      value: |
        resolves to ...
```

Key invariants — breaking any of these fails `edoxen validate`:

- **Every translatable string is `[{ spelling, value }]`**, even when only
  one language is present. `spelling` is an ISO 24229 code (e.g. `eng`,
  `fra`, `zho-Hans`). There is no scalar fallback.
- `metadata.title` is a `LocalizedString[]`; it is *not* a plain string.
- `metadata.date` is a bare ISO date string (`'2024-10-25'`), not under a
  `dates:` array.
- Each `Decision.identifier` is an array of `{ prefix, number }` (1..*).
  Prefix for this repo is `ISO/TC 154`.
- `Decision.dates[]` entries are `{ date, type }` where `type ∈
  {adoption, effective, drafted, discussed, published}`.
- `Action` and `Consideration` carry `date_effective`; `Approval` carries
  `date`. All three are `DecisionDate` objects (`{ date, type }`), and all
  three have `message: LocalizedString[]`.
- `Action.type`, `Approval.{type,degree}`, `Consideration.type` are closed
  enums — see `schema/decision-collection.yaml` `$defs` in the edoxen-model
  repo for the authoritative value lists.
- YAML wire names are `snake_case` even though the LutaML files use
  `camelCase` (`dateEffective`, `languageCode`). The schema sync specs in
  the gem enforce the mapping.

## Schema header

Every YAML file **must** start with the `yaml-language-server` comment
pointing at the published schema. This is what gives editors
autocomplete + inline validation. The URL is
`https://raw.githubusercontent.com/edoxen/edoxen/refs/heads/main/schema/edoxen.yaml`
— note `edoxen/edoxen`, not `metanorma/edoxen` (the repo was renamed; the
v0.7.x files used the old URL and `migrate_to_v2.rb` rewrites it).

## Migration history

This repo has been migrated twice. Both scripts live in `scripts/` and are
**idempotent** — they detect already-migrated files and skip:

| Script | From → To | Trigger |
|---|---|---|
| `migrate_to_v2.rb` | Pre-model (`resolutions:`, scalar strings, `dates: [{start, kind}]`) → early `decisions:` with per-Decision `localizations[]` wrapper | `feat/v2.1-migration` branch |
| `migrate-to-v3.rb` | `localizations[]` wrapper → **Edoxen Model 1.0** (per-field `LocalizedString[]`, no wrapper) | `feat/migrate-to-v3-format` branch (current HEAD) |

Despite the filenames, both target outputs are historical waypoints — the
**current canonical shape is Edoxen Model 1.0**. The `v3` in the branch
name and the second script is a misnomer from before model 1.0 landed; the
data is in model 1.0 form today (commit `129127b`).

Both scripts preserve originals to `legacy/` (or skip backup with
`--dry-run`).

When the next Edoxen major version lands, add a new migration script
following the same pattern: idempotent, preserve originals, print a
per-file report at the end.

## Editing workflow

1. Make the change in the YAML file.
2. Run `bundle exec edoxen normalize <file> --inplace` to canonicalize
   whitespace/key ordering. Skipping this produces noisy diffs.
3. Run `bundle exec edoxen validate <file>`. Fix any reported violations.
4. Commit. CI will re-validate on push.

When transcribing new resolutions from a PDF in `reference-docs/`, keep the
PDF in place — it is the source of truth. Do not delete or rename
`reference-docs/` entries even after transcription.

## Canonical model location

The authoritative LutaML definitions and JSON-Schema live in the
`edoxen/edoxen-model` repo on GitHub (https://github.com/edoxen/edoxen-model):

- `models/*.lutaml` — one file per concept (`decision.lutaml`,
  `action.lutaml`, `approval.lutaml`, etc.).
- `schema/decision-collection.yaml` — the JSON-Schema `edoxen validate`
  checks against. Authoritative enum value lists live under `$defs`.
- `schema/examples/decision-example.yaml` — canonical example fixture.
- `CHANGELOG.adoc` — what changed at each model version; read this first
  when planning a migration.

If the gem and the model disagree, the **model repo wins** — the gem's sync
specs assert 1:1 parity with the LutaML.
