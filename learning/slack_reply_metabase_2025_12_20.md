# Metabase Slack Reply (2025-12-20)

Proposed reply:

Sounds good — +1 to making `default_std_dev` a configurable parameter and bringing back the low-view treatment filter. Agree on also parameterizing `default_mean`.
Question: where should these live (per-company config like `configs/dev.yaml` or a global defaults block)?
Other knobs that might be worth making configurable: min views threshold, prior strength/decay window, and any caps on treatments/arms.
