---
description: Review code before PR (REVIEW mode)
---

Review code changes and prepare for PR.

## Instructions

1. Run all checks:
   ```bash
   make lint
   make test-unit
   make sql-validate
   ```

2. If model changes, run evaluation:
   ```bash
   make eval
   ```

3. Review checklist:
   - [ ] Type hints on all functions
   - [ ] Tests exist for new code
   - [ ] No hardcoded configs
   - [ ] SQL validated
   - [ ] Docs updated if needed

4. Check evaluation metrics (if applicable):
   - Compare against `evals/baselines/`
   - Verify no regression beyond threshold

5. Prepare PR summary:
   - What changed
   - Why it changed
   - How to test
   - Eval results (if model change)

## Reference
- @agent_docs/testing_guide.md
- @agent_docs/evaluation_guide.md
