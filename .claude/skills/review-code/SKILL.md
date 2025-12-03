---
name: review-code
description: Review code changes for quality, tests, and documentation. Use when user asks to review code, prepare for PR, or check implementation quality.
allowed-tools: Read, Grep, Glob, Bash
---

# Review Code Skill

## When to Use
- Before creating a PR
- User asks "review this code"
- User wants pre-merge checks

## Review Checklist

### Code Quality
- [ ] All functions have type hints
- [ ] Public functions have docstrings
- [ ] No hardcoded values (use configs/)
- [ ] No secrets in code
- [ ] Error handling for edge cases
- [ ] Logging instead of print statements

### Tests
- [ ] Unit tests exist for new code
- [ ] Tests cover happy path and edge cases
- [ ] `make test-unit` passes

### SQL (if applicable)
- [ ] SQL validated with `make sql-validate`
- [ ] Queries use parameterized inputs
- [ ] No hardcoded project/dataset names

### Evaluation (if model changes)
- [ ] `make eval` passes
- [ ] Metrics don't regress vs baseline
- [ ] Results logged to W&B

### Documentation
- [ ] `agent_docs/` updated if architecture changed
- [ ] README updated if new commands/setup

## Commands to Run
```bash
make lint          # Ruff + mypy
make test-unit     # Unit tests
make sql-validate  # SQL validation
make eval          # If model changes
```

## Common Issues to Flag
1. **Missing type hints** - Add return types and param types
2. **Hardcoded configs** - Move to `configs/*.yaml`
3. **No tests** - Add tests for new functions
4. **Print statements** - Replace with logging
5. **Magic numbers** - Extract to constants or config
6. **Broad exceptions** - Catch specific exceptions

## Generate Missing Tests
If tests are missing, suggest test cases:
```python
def test_function_happy_path():
    """Test normal operation."""
    result = function(valid_input)
    assert result == expected

def test_function_edge_case():
    """Test edge case handling."""
    result = function(empty_input)
    assert result == default_value

def test_function_error():
    """Test error handling."""
    with pytest.raises(ValueError):
        function(invalid_input)
```
