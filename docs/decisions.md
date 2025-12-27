# Decision Log

Append-only log of architectural and implementation decisions.

## Template

```markdown
### YYYY-MM-DD: Decision Title
- **Context**: What situation prompted this decision?
- **Decision**: What did we decide?
- **Alternatives**: What else was considered?
- **Consequences**: What are the implications?
```

---

## Decisions

### 2024-12-21: Variant Dedup Regex Fix (v5.7)
- **Context**: 7,711 SKUs incorrectly collapsed (e.g., "BRAKE" → "BRAK") because the regex `[BRGP]$` matched any trailing B/R/G/P, not just color/variant suffixes.
- **Decision**: Changed regex from `[BRGP]$` to `[0-9][BRGP]$` - only strip suffix when preceded by a digit.
- **Alternatives**: Could have used product catalog mapping to identify true variants, but regex is simpler and sufficient.
- **Consequences**: 99.95% rec overlap with v5.6, correct behavior for edge cases. Only 257 users affected (diff_rec3: 28, diff_rec4: 229).

### 2024-12-21: Single import_orders Scan (v5.7)
- **Context**: Pipeline was scanning `import_orders` twice - once for popularity (324d) and once for purchase exclusion (365d).
- **Decision**: Consolidated into single scan with conditional aggregation for both windows.
- **Alternatives**: Keep separate scans for clarity, but cost was ~2x.
- **Consequences**: ~50% reduction in bytes scanned for that step. Slight increase in query complexity.

### 2024-12-21: Pipeline Version Column
- **Context**: No way to track which pipeline version generated each recommendation.
- **Decision**: Added `pipeline_version` column to output (e.g., "v5.7").
- **Alternatives**: Could track in metadata table, but inline is simpler.
- **Consequences**: Easy version tracking, minimal storage overhead.

### 2024-12-17: MECE Framework for Treatment Comparison
- **Context**: Initial CTR comparisons showed Personalized performing worse, but comparison was biased (different user populations).
- **Decision**: Adopted MECE framework - only compare users eligible for both treatment types (users with vehicle data).
- **Alternatives**: Could have used propensity score matching, but MECE is simpler and addresses the core bias.
- **Consequences**: Revealed true performance difference. Static actually outperforms Personalized by ~80% for eligible users.

### 2024-12-10: Thompson Sampling for Treatment Selection
- **Context**: Needed to balance exploration (testing new treatments) with exploitation (using best performers).
- **Decision**: Implemented Thompson Sampling with Beta-Binomial conjugate prior.
- **Alternatives**: Epsilon-greedy (simpler but less efficient), UCB (deterministic).
- **Consequences**: Natural exploration decay as confidence increases. 10% exploration traffic via bandit model.
