# 0003: Argo CD Applications live in `gitops/`, not `platform/`

**Status:** Accepted, 2026-11-21

## Context

The suggested layout puts the Argo CD Applications in a `platform/` directory and the CLI in a `platform` script, both at the repo root. A file and a directory cannot share a name in the same folder, so one must change.

## Options

1. Keep the `platform/` directory and rename the CLI (for example `./platformctl`).
2. Keep the `./platform` CLI and rename the directory.

## Choice

Option 2: the directory becomes `gitops/`. The `./platform` command is what every reviewer types, so its name matters more. `gitops/` also says what the directory is: the desired state Argo CD syncs from.

## Consequences

- The Argo CD root Application points at `gitops/`.
- The README and brief layout differ in this one name.
