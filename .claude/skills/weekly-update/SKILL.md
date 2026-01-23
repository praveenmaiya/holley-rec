---
name: weekly-update
description: Generate a team-facing weekly status update from STATUS_LOG.md and git history.
allowed-tools: Bash, Read, Glob, Edit, AskUserQuestion
arguments:
  - name: date
    description: End date for the week (format "Jan 20")
    required: true
---

# Weekly Update Skill

Generate a concise, business-focused weekly status update for the team.

**Usage:** `/weekly-update Jan 20`

## Process

### Step 1: Gather Context

1. Read `STATUS_LOG.md` - find entries within the 7-day window ending on the given date
2. Run git log for the period:
   ```bash
   git log --oneline --since="7 days ago" --until="tomorrow"
   ```
   (Adjust dates based on the provided date argument)
3. Check doc timestamps:
   ```bash
   ls -la docs/*.md
   ```
4. Read `docs/weekly_updates.md` - match the existing format and tone

### Step 2: Draft the Update

Write 2-3 bullets following these rules:

| Rule | Do This |
|------|---------|
| **Work, not stats** | Describe what was accomplished; stats support the story, don't lead it |
| **Business impact** | Why does this matter? What does it unlock? |
| **Self-explanatory** | Reader should understand without a voiceover |
| **No "we" or "I"** | Noun-led phrasing ("Established..." not "I established...") |
| **No version numbers** | Say "segment-based recommendations" not "v5.17" |
| **Human tone** | Conversational, clear, not robotic or AI-sounding |
| **Brief** | 2-3 bullets maximum |

### Step 3: Ask for "Next"

**IMPORTANT:** Always ask the user:

> "What's coming next week for the Next section?"

Wait for user response before proceeding. Do not auto-generate the Next section.

### Step 4: Present Draft

Show the complete update:

```
**Weekly Update - [Date], 2026**

* **[Topic]:** What was done. Why it matters.
* **[Topic]:** ...
* **Next:** [user-provided next items]
```

### Step 5: Offer to Save

Ask: **"Want me to add this to docs/weekly_updates.md and commit?"**

If yes:
1. Prepend the update to `docs/weekly_updates.md` with `---` separator
2. Commit with message: `Add weekly update [Date]: [brief summary]`

## Anti-patterns

| Don't Write | Write Instead |
|-------------|---------------|
| "Implemented collaborative filtering" | "Collaborative filtering was tested but deprioritized due to low repeat purchase rates (18%)" |
| "Fixed variant dedup bug" | "Rolled out a fix for specialized product variants, ensuring users see exact performance parts" |
| "87% coverage achieved" | "Vehicle-specific recommendations now reach 87% of users" |
| "We investigated the issue" | "Investigation revealed that 65% of purchases involve untracked products" |
| "v5.17 deployed" | "Segment-based recommendations deployed" |

## Example Output

**Weekly Update - Jan 20, 2026**

* **Segment-Based Recommendations Validated (Holley):** The shift from global popularity to vehicle-segment recommendations is now live and measured. Open rates nearly tripled and click-through rates nearly doubled—same-user testing confirmed it's the algorithm, not seasonality.
* **Deployment Verification Runbooks:** Established standardized guides to trace a model from "Succeeded" workflow to live serving config. Cuts debugging time on silent failures where workflows pass but models don't update.
* **Next:** Run end-to-end training flow for a test company. Start scoping generalized recommendation framework.
