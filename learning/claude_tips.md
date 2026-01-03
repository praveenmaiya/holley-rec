# Claude Code Tips from Boris Cherny

Boris Cherny (@bcherny) is the creator of Claude Code (started as a side project in Sept 2024).
He landed **259 PRs in 30 days** - every line written by Claude Code + Opus 4.5.

Last updated: 2026-01-02

---

## The Official 13 Tips (From Twitter Thread)

**Sources:**
- Thread Part 1: https://x.com/bcherny/status/2007179858435281082
- Thread Part 2: https://x.com/bcherny/status/2007179832300581177

### 1. Run 5 Claudes in Parallel (Terminal)
Number your terminal tabs 1-5, use system notifications to know when a Claude needs input.
- Docs: https://code.claude.com/docs/en/terminal-config#iterm-2-system-notifications

### 2. Run 5-10 Claudes on claude.ai/code + Mobile
Run parallel sessions on web alongside local Claudes:
- Hand off local sessions to web using `&`
- Use `--teleport` to move back and forth
- Start sessions from Claude iOS app and check in later

### 3. Use Opus 4.5 with Thinking for Everything
> "It's the best coding model I've ever used, and even though it's bigger & slower than Sonnet, since you have to steer it less and it's better at tool use, it is almost always faster than using a smaller model in the end."

### 4. Team Shares Single CLAUDE.md
- Check into git, whole team contributes
- **Key principle**: Anytime you see Claude do something incorrectly, add it to CLAUDE.md so Claude knows not to do it next time
- Each team maintains their own CLAUDE.md

### 5. Tag @.claude on PRs via GitHub Action
During code review, tag `@.claude` on coworkers' PRs to add something to CLAUDE.md as part of the PR.
- Use `/install-github-action` to set up
- This is "Compounding Engineering" - the codebase gets smarter over time

### 6. Most Sessions Start in Plan Mode
- `Shift+Tab` twice to enter Plan Mode
- Go back and forth with Claude until you like its plan
- Then switch to auto-accept edits mode
- **"A good plan is really important!"**

### 7. Slash Commands for Every Inner Loop Workflow
Use slash commands for workflows you do many times a day:
- Saves from repeated prompting
- Claude can use these workflows too
- Commands live in `.claude/commands/` and are checked into git
- Example: `/commit-push-pr` with inline bash to pre-compute git status

**Pro tip**: Add inline bash to pre-compute context and avoid back-and-forth:
```markdown
# In your command file
\`\`\`bash
git status --short
git diff --stat
git log -3 --oneline
\`\`\`
```
- Docs: https://code.claude.com/docs/en/slash-commands#bash-command-execution

### 8. Subagents for Common Workflows
> "I use a few subagents regularly: code-simplifier simplifies the code after Claude is done working, verify-app has detailed instructions for testing Claude Code end to end, and so on. Similar to slash commands, I think of subagents as automating the most common workflows that I do for most PRs."

Regular subagents Boris uses:
- `code-simplifier` - simplifies code after Claude is done
- `verify-app` - detailed instructions for testing end-to-end
- Think of subagents as automating the most common workflows for most PRs
- Docs: https://code.claude.com/docs/en/sub-agents

### 9. PostToolUse Hook to Format Code
> "We use a PostToolUse hook to format Claude's code. Claude usually generates well-formatted code out of the box, and the hook handles the last 10% to avoid formatting errors in CI later."

- Claude usually generates well-formatted code out of the box
- Hook handles the last 10% to avoid formatting errors in CI later
- Docs: https://code.claude.com/docs/en/hooks-guide

### 10. Use /permissions Instead of --dangerously-skip-permissions
> "I don't use --dangerously-skip-permissions. Instead, I use /permissions to pre-allow common bash commands that I know are safe in my environment, to avoid unnecessary permission prompts. Most of these are checked into .claude/settings.json and shared with the team."

- Use `/permissions` to pre-allow common bash commands you know are safe
- Most are checked into `.claude/settings.json` and shared with team

### 11. Claude Uses All Your Tools (MCP)
> "Claude Code uses all my tools for me. It often searches and posts to Slack (via the MCP server), runs BigQuery queries to answer analytics questions (using bq CLI), grabs error logs from Sentry, etc. The Slack MCP configuration is checked into our .mcp.json and shared with the team."

Claude Code uses all Boris's tools:
- Searches and posts to Slack (via MCP server)
- Runs BigQuery queries (bq CLI)
- Grabs error logs from Sentry
- MCP configuration checked into `.mcp.json` and shared with team

### 12. Long-Running Tasks: Background Agents + Stop Hooks
> "For very long-running tasks, I will either (a) prompt Claude to verify its work with a background agent when it's done, (b) use an agent Stop hook to do that more deterministically, or (c) use the ralph-wiggum plugin. I will also use either --permission-mode=dontAsk or --dangerously-skip-permissions in a sandbox to avoid permission prompts for the session, so Claude can cook without being blocked on me."

For very long-running tasks:
- (a) Prompt Claude to verify its work with a background agent when done
- (b) Use an agent Stop hook to do that more deterministically
- (c) Use the `ralph-wiggum` plugin to keep Claude going
- Use `--permission-mode=dontAsk` or `--dangerously-skip-permissions` in sandbox

**Links:**
- ralph-wiggum plugin: https://github.com/anthropics/claude-plugins-official/tree/main/plugins/ralph-wiggum
- Hooks guide: https://code.claude.com/docs/en/hooks-guide

### 13. Give Claude a Way to Verify Its Work (MOST IMPORTANT)
> "Probably the most important thing to get great results out of Claude Code - give Claude a way to verify its work. If Claude has that feedback loop, it will 2-3x the quality of the final result."

> "Claude tests every single change I land to claude.ai/code using the Claude Chrome extension. It opens a browser, tests the UI, and iterates until the code works and the UX feels good."

Verification looks different for each domain:
- Running bash commands
- Running test suite
- Testing app in browser (Claude Chrome extension)
- Testing in phone simulator
- **Make sure to invest in making this rock-solid**

- Chrome Extension: https://code.claude.com/docs/en/chrome

---

## Effective Workflows

### Explore-Plan-Code-Commit
1. Have Claude read files first
2. Create a plan (use "think" or "ultrathink" for extended thinking)
3. Implement
4. Commit

### Test-Driven Development
1. Write tests first
2. Verify they fail
3. Have Claude implement code to pass them

### Visual Iteration
1. Provide screenshots or design mocks
2. Have Claude iterate until results match

---

## Quick Commands

| Command | Purpose |
|---------|---------|
| `Esc Esc` | Rewind to checkpoints |
| `Shift+Tab` x2 | Enter Plan Mode |
| `Ctrl+S` | Stash prompts temporarily |
| `/clear` | Reset context (use frequently in long sessions) |
| `#message` | Save to permanent memory |
| `@file` | Add file to context |
| `!command` | Execute bash instantly |

---

## Extended Thinking Keywords

| Keyword | Tokens | Use Case |
|---------|--------|----------|
| `think` | Default | Normal reasoning |
| `think hard` | More | Complex problems |
| `ultrathink` | 31,999 | Deep analysis |

---

## What We Use in This Repo

### Implemented (matches Boris's tips)

| Tip # | Feature | Our Implementation |
|-------|---------|-------------------|
| 3 | Opus 4.5 | Using Opus 4.5 with thinking |
| 4 | CLAUDE.md | Strong CLAUDE.md with patterns, gotchas (consolidated) |
| 6 | Plan Mode | Plan -> Code -> Review workflow, `/plan` command |
| 7 | Slash Commands | `/commit`, `/plan`, `/implement`, `/review`, `/eval` |
| 8 | Subagents | `code-reviewer`, `sql-debugger`, `pipeline-verifier` in `.claude/agents/` |
| 9 | Format Hook | PostToolUse hook for Python (ruff) + SQL validation |
| 10 | /permissions | `.claude/settings.json` with allow list (bq, make, pytest, ruff, mypy) |
| 11 | Tool Integration | BigQuery via `bq` CLI |
| 5 | GitHub Action | `.github/workflows/claude.yml` for @claude PR tagging |
| 13 | Verification | Auto-verification in `/run-pipeline`, `/validate` skill, `pipeline-verifier` subagent |

### Partially Implemented

| Tip # | Feature | Status | Gap |
|-------|---------|--------|-----|
| 11 | MCP | Partial | `.mcp.json` with Linear MCP, bq CLI. No Slack MCP yet |

### Not Implemented Yet

| Tip # | Feature | Priority | Notes |
|-------|---------|----------|-------|
| 1 | 5 Parallel Terminals | Low | User workflow preference |
| 2 | claude.ai/code + Mobile | Low | User workflow preference |
| 12 | Stop Hooks | Medium | ralph-wiggum plugin for long runs |

### To Explore
- [x] Install Claude Code GitHub Action (`.github/workflows/claude.yml`) ✅
- [ ] Stop hooks + ralph-wiggum plugin for pipeline runs
- [ ] Git worktrees for parallel Claude instances
- [ ] Slack MCP server if needed

---

## Sources

- [Claude Code: Best practices for agentic coding - Anthropic](https://www.anthropic.com/engineering/claude-code-best-practices)
- [Boris Cherny on X](https://x.com/bcherny)
- [Boris Cherny Creator Interview](https://www.developing.dev/p/boris-cherny-creator-of-claude-code)
- [How to Use Claude Code Like the People Who Built It](https://every.to/podcast/how-to-use-claude-code-like-the-people-who-built-it)
- [Ultimate Claude Code Tips (Advent of Claude 2025)](https://dev.to/damogallagher/the-ultimate-claude-code-tips-collection-advent-of-claude-2025-5b73)
