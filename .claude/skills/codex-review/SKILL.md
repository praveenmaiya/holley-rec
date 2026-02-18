---
name: codex-review
description: Send context to OpenAI Codex CLI for independent peer review. Use when user wants a second opinion from Codex on architecture, code, design decisions, or any work produced in the current session.
allowed-tools: Read, Write, Bash, Glob, Grep
---

# Codex Review Skill

Send work from this session to OpenAI Codex for an independent peer review.

## When to Use
- User says "codex review this", "get a second opinion", "ask codex about this"
- User wants to validate architecture, design, or code decisions
- User has doubts about an approach and wants Codex to challenge it

## Workflow

### Step 1: Identify What to Review

Ask the user if not clear. The review target can be:
- **Conversation context**: Architecture description, design decision, analysis — summarize it from the conversation
- **Files**: Specific source files the user points to
- **Both**: Context + files for full picture

### Step 2: Write Context File

Write the review material to `/tmp/codex_review_context.md`:

```markdown
# Review Request

## What to Review
{brief description of the work}

## Context
{architecture description, design rationale, constraints, or analysis from the conversation}

## Specific Concerns
{user's specific doubts or areas to focus on, if any}

## Code
{if reviewing files, include the file contents here with paths as headers}
```

Keep it focused — include only what's relevant, not the entire conversation.

### Step 3: Execute Codex

Run Codex CLI in non-interactive mode. Use `--full-auto` since this is read-only review work:

```bash
codex exec "You are a senior engineer performing an independent peer review of work done by another AI assistant (Claude). Read /tmp/codex_review_context.md and review it.

Your review must cover:
1. **Correctness** - logical errors, wrong assumptions, flawed reasoning
2. **Blind spots** - what was missed, overlooked, or under-considered
3. **Improvements** - simpler approaches, better patterns, unnecessary complexity
4. **Risks** - potential failures, edge cases, production gotchas

Rules:
- Be specific and critical. Vague praise is useless.
- If you disagree with an approach, explain WHY and suggest an alternative.
- Reference specific sections, line numbers, or code when discussing issues.
- If something looks correct, say so briefly and move on.
- End with a severity-ranked list: CRITICAL > HIGH > MEDIUM > LOW" \
  --full-auto \
  -o /tmp/codex_review_output.md
```

**Timeout**: Allow up to 5 minutes (300000ms) for complex reviews.

**If Codex fails**: Check that `codex` is in PATH and CODEX_API_KEY / OPENAI_API_KEY is set. Report the error to the user.

### Step 4: Present Results

Read `/tmp/codex_review_output.md` and present the review to the user.

Format the output as:
```
## Codex Review

{codex output}

---
*Reviewed by OpenAI Codex CLI*
```

### Step 5: Discuss

Ask the user if they want to:
- Address any of the findings
- Send a follow-up question to Codex
- Proceed as-is

## Examples

### Architecture review
User: `/codex-review the GNN two-tower architecture I just described`
- Summarize the architecture from conversation into context file
- Send to Codex for review

### Code review
User: `/codex-review src/gnn/scorer.py`
- Read the file, write to context with description of what it does
- Send to Codex

### Design decision
User: `/codex-review should we use slot reservation or scoring boost for fitment?`
- Write the tradeoffs discussed in conversation to context file
- Ask Codex to weigh in

### With specific concern
User: `/codex-review the purchase exclusion logic - I'm worried about SKU normalization edge cases`
- Gather relevant code + context
- Include the specific concern in the review prompt
