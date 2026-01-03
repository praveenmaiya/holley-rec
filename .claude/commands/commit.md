---
description: Commit changes with optional push and PR creation
---

# Commit Workflow

Commit staged/unstaged changes with a well-crafted message, optionally push and create PR.

## Pre-computed Context

```bash
echo "📊 GIT STATUS"
git status --short

echo ""
echo "📝 STAGED CHANGES"
git diff --cached --stat

echo ""
echo "📝 UNSTAGED CHANGES"
git diff --stat

echo ""
echo "📜 RECENT COMMITS (for style reference)"
git log -5 --oneline

echo ""
echo "🌿 CURRENT BRANCH"
git branch --show-current
```

## Instructions

1. **Analyze changes** from the pre-computed context above
2. **Draft commit message** following this repo's style:
   - Imperative mood ("Add", "Fix", "Update", not "Added", "Fixed")
   - First line: summary (50 chars max)
   - Body: explain "why" not "what" (wrap at 72 chars)
3. **Stage files** if needed: `git add <files>` or `git add .`
4. **Commit** with the drafted message using HEREDOC format
5. **If user requests push**: `git push -u origin <branch>`
6. **If user requests PR**: Use `gh pr create`

## Commit Message Format

```bash
git commit -m "$(cat <<'EOF'
<summary line>

<body explaining why>

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

## Common Patterns

### Quick commit (no push)
```bash
git add . && git commit -m "..."
```

### Commit and push
```bash
git add . && git commit -m "..." && git push -u origin $(git branch --show-current)
```

### Full PR workflow
```bash
git add . && git commit -m "..." && git push -u origin $(git branch --show-current) && gh pr create --fill
```

## Safety Rules

- NEVER use `--force` push
- NEVER use `--amend` unless explicitly requested AND commit is local
- NEVER skip hooks (`--no-verify`)
- Check for secrets in staged files before committing

## Arguments

- `$ARGUMENTS` - Optional: "push" to also push, "pr" to also create PR
