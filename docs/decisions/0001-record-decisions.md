# 0001: Record decisions in this log

**Status:** Accepted, 2026-11-21

## Context

This repo is built by two agents in small pull requests and reviewed by people who were not there when choices were made. Reasons get lost in PR threads.

## Options

1. No log; rely on PR descriptions.
2. A short decision record per notable choice in `docs/decisions/`.
3. A wiki outside the repo.

## Choice

Option 2. Short records in the repo, next to the code they explain.

## Consequences

- Reviewers can see why something is the way it is without digging through PRs.
- Each notable choice costs a few minutes of writing.
- Superseded decisions stay visible, which shows how the design evolved.
