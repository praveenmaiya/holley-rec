# Thompson Sampling (Click Bandit) — Dec 20, 2025

Saved from conversation: plain-language explanation of how the bandit model in `src/bandit_click_holley.py` works and its knobs.

## How the Model Works (simple terms)
- Treat each email treatment like a slot-machine arm with an unknown chance of getting a click.
- Keep a belief curve (Beta distribution) for each arm; start neutral with Beta(1,1).
- After data arrives: successes = clicks, trials = views (or sends). Update to Beta(1+clicks, 1+views-clicks).
- To pick a treatment for the next user: sample one possible click-rate from each arm’s Beta, choose the arm with the highest sample.
- Repeat. Good arms win more often; uncertain arms still get occasional traffic, automatically balancing explore vs exploit.

## Parameters in the Holley script
- `COMPANY_ID` (default "1950") and `SURFACE_ID` (default 929): which tenant/channel to use.
- `DATA_WINDOW_DAYS` (default 60): lookback window; excludes today.
- Priors: `PRIOR_ALPHA = 1.0`, `PRIOR_BETA = 1.0` (uniform start).
- Simulation: 10k samples per run (`simulate_thompson_sampling`) with seed 42 to estimate how traffic would split.

## Metric Being Optimized
- Trials are distinct views; successes are distinct clicks → the optimized metric is click-to-open rate (CTOR). If we want CTR on sends or revenue, the denominator/success definition must change.

## Fit Notes
- Works well when we only need a non-contextual ranking of treatments and have steady tracking.
- Risks: missing opens exclude arms (inner join on views); fixed 60d window may lag; no live allocation/traffic guardrails; project/company/surface currently hardcoded for Holley.
