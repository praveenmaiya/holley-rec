---
name: implement-spec
description: Implement a feature from a spec file. Use when user says "implement spec", references a spec file to build, or wants to code a planned feature.
allowed-tools: Read, Write, Edit, Glob, Grep, Bash
---

# Implement Spec Skill

## When to Use
- User references a spec in `specs/active/`
- User says "implement the spec" or "build this feature"
- Moving from PLAN mode to CODE mode

## Process

1. **Read the spec** from `specs/active/<feature>.md`
2. **Verify prerequisites**:
   - All open questions resolved
   - Success criteria defined
   - Test plan exists
3. **Plan implementation order**:
   - SQL queries first (if data needed)
   - Core modules in `src/`
   - Metaflow flow in `flows/`
   - Tests in `tests/`
4. **Implement incrementally**:
   - Small, testable chunks
   - Commit after each logical piece
5. **Log to W&B** if experiment
6. **Update spec** with implementation notes
7. **Move spec** to `specs/completed/` when done

## Implementation Order
```
1. sql/recommendations/extract/   → Data queries
2. src/data/                      → Data loading
3. src/features/                  → Feature engineering
4. src/models/                    → Model logic
5. src/evaluation/                → Metrics
6. flows/                         → Pipeline
7. tests/unit/                    → Unit tests
8. scripts/                       → CLI entry point
```

## Conventions
- Reference `@agent_docs/code_conventions.md`
- Use `--test-mode` for BQ during development
- No hardcoded project IDs (use configs/)
- Type hints on all functions

## After Implementation
1. Run `make test` - must pass
2. Run `make lint` - no errors
3. Run `make eval` if model changed
4. Create PR with spec summary
