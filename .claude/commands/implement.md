---
description: Implement a feature from spec (CODE mode)
---

Implement a feature from an approved spec.

## Arguments
$ARGUMENTS - spec name or path (e.g., "user_embeddings" or "specs/active/user_embeddings.md")

## Instructions

1. Read the spec from `specs/active/`
2. Verify all open questions are resolved
3. Follow implementation order:
   - SQL in `sql/recommendations/`
   - Modules in `src/`
   - Flow in `flows/`
   - Tests in `tests/unit/`
4. Use `--test-mode` for any BQ queries
5. Log experiments to W&B if applicable
6. Run `make test` and `make lint` frequently

## Reference Docs
- @agent_docs/architecture.md
- @agent_docs/code_conventions.md
- @agent_docs/bigquery_patterns.md

## Completion
When done:
1. Ensure all tests pass
2. Move spec to `specs/completed/`
3. Prepare for REVIEW mode
