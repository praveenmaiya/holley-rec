---
description: Create a new feature spec (PLAN mode)
---

Create a new feature specification in `specs/active/`.

## Instructions

1. Ask the user for the feature name if not provided: $ARGUMENTS
2. Create `specs/active/<feature-name>.md` using the template from `specs/templates/feature_spec.md`
3. Fill in what you know, mark unknowns with `[TBD]`
4. Ask clarifying questions about:
   - Problem statement (what are we solving?)
   - Data requirements (what tables/inputs?)
   - Output format (what should be produced?)
   - Success criteria (how do we know it works?)
   - Evaluation metrics (precision, recall, etc.?)

## Template Location
@specs/templates/feature_spec.md

## After Creating Spec
- Review with user
- Resolve all `[TBD]` items
- Get approval before moving to CODE mode
