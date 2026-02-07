"""
NIG Thompson Sampling Convergence Simulation
=============================================

Simulates the Normal-Inverse-Gamma Thompson Sampling bandit to determine
how long it takes to differentiate between treatments at various data volumes.

Scenarios tested (using corrected numbers from investigation):
  A: Current state — 20 high-traffic treatments, ~37 opens/treatment/day
  B: Reduced to 10 treatments (~75 opens/treatment/day)
  C: Per-user auction — 7 treatments (what each user actually sees)
  D: 10 treatments + informative prior

Key corrections from earlier version:
  - 92 treatments in bandit pool, but only 20 with 100+ sends/day (75% of traffic)
  - Per user request: only 4-7 treatments eligible (fitment-filtered)
  - Model trains on opens (not sends): ~750 opens/day total
  - CTRs are CTR-of-opens (5-12%), not CTR-of-sends (0.5-2%)

Usage:
  python3 src/nig_convergence_simulation.py

Based on: docs/bandit-models-deep-analysis.md (NIG math formulas)
Data from: Q12/Q16 of sql/analysis/bandit_investigation_phase2.sql

No external dependencies — uses only Python standard library.
"""

import math
import random
from dataclasses import dataclass
from statistics import median, mean


@dataclass
class NIGParams:
    """Normal-Inverse-Gamma distribution parameters."""
    mu: float      # Location (posterior mean estimate)
    lam: float     # Precision (number of pseudo-observations)
    alpha: float   # Shape (related to variance estimate)
    beta: float    # Scale (related to variance estimate)

    def posterior_mean(self) -> float:
        return self.mu

    def posterior_stddev(self) -> float:
        """Standard deviation used for Thompson Sampling."""
        if self.alpha <= 0.5:
            return float('inf')
        val = self.beta / (self.lam * (self.alpha - 0.5))
        if val < 0:
            return 0.0
        return math.sqrt(val)


def nig_update(prior: NIGParams, rewards: list) -> NIGParams:
    """
    Update NIG parameters given a batch of Bernoulli rewards.

    This follows the stateless batch update used by the Auxia platform:
    the model is retrained from scratch each cycle with the full dataset.

    Math (from docs/bandit-models-deep-analysis.md):
      lambda_new = lambda + n
      mu_new = (lambda * mu + sum(rewards)) / lambda_new
      alpha_new = alpha + n/2
      beta_new = beta + 0.5*(ss - sum(rewards)^2/lambda_new)
                 + 0.5 * lambda * n * (mean(rewards) - mu)^2 / lambda_new

    For Bernoulli rewards: ss = sum(rewards) since 1^2 = 1.
    """
    n = len(rewards)
    if n == 0:
        return prior

    k = float(sum(rewards))
    ss = k  # For Bernoulli: sum of squared rewards = sum of rewards

    lam_new = prior.lam + n
    mu_new = (prior.lam * prior.mu + k) / lam_new
    alpha_new = prior.alpha + n / 2.0

    # Variance adjustment term
    sample_mean = k / n if n > 0 else 0
    beta_new = (prior.beta
                + 0.5 * (ss - k * k / lam_new)
                + 0.5 * prior.lam * n * (sample_mean - prior.mu) ** 2 / lam_new)

    return NIGParams(mu=mu_new, lam=lam_new, alpha=alpha_new, beta=beta_new)


@dataclass
class ScenarioConfig:
    """Configuration for a simulation scenario."""
    name: str
    num_treatments: int
    opens_per_day_total: int  # Total opens across all treatments (not sends!)
    true_ctrs: list           # True CTR of opens for each treatment
    prior: NIGParams          # Starting prior for each treatment
    description: str


def simulate_scenario(config: ScenarioConfig, n_days: int = 180,
                      n_simulations: int = 200, seed: int = 42) -> dict:
    """
    Simulate NIG Thompson Sampling for a given scenario.

    The model is STATELESS -- retrained from scratch each day using ALL
    historical data (matching Auxia's batch retraining approach).

    Observations = opens (not sends). Rewards = clicks.
    CTR = clicks/opens (CTR of opens).

    Returns dict with convergence metrics.
    """
    rng = random.Random(seed)

    # Track results across simulations
    days_to_identify_winner = []
    winner_correct_at_90d = 0
    winner_correct_at_180d = 0

    # Track posterior evolution (from first simulation for reporting)
    posterior_means_history = None
    posterior_stddevs_history = None

    true_best = config.true_ctrs.index(max(config.true_ctrs))

    for sim in range(n_simulations):
        # Cumulative data storage (stateless model retrains from scratch)
        all_rewards = [[] for _ in range(config.num_treatments)]

        # Daily opens per treatment (roughly uniform among competing treatments)
        opens_per_treatment = config.opens_per_day_total // config.num_treatments

        winner_identified_day = None
        daily_means = []
        daily_stddevs = []

        for day in range(n_days):
            # Generate today's data: each treatment gets ~opens_per_treatment opens
            for t in range(config.num_treatments):
                n_opens = opens_per_treatment + rng.randint(-3, 3)
                n_opens = max(1, n_opens)
                # Generate Bernoulli clicks from opens
                rewards = [1 if rng.random() < config.true_ctrs[t] else 0
                           for _ in range(n_opens)]
                all_rewards[t].extend(rewards)

            # Retrain from scratch (stateless, like Auxia's pipeline)
            posteriors = []
            for t in range(config.num_treatments):
                posterior = nig_update(config.prior, all_rewards[t])
                posteriors.append(posterior)

            means = [p.posterior_mean() for p in posteriors]
            stddevs = [p.posterior_stddev() for p in posteriors]

            daily_means.append(list(means))
            daily_stddevs.append(list(stddevs))

            # Check if winner is identifiable:
            # Best treatment's lower bound > second-best's upper bound (95% CI)
            indexed = sorted(enumerate(means), key=lambda x: x[1], reverse=True)
            best_idx = indexed[0][0]
            second_idx = indexed[1][0]

            best_lower = means[best_idx] - 1.96 * stddevs[best_idx]
            second_upper = means[second_idx] + 1.96 * stddevs[second_idx]

            if best_lower > second_upper and winner_identified_day is None:
                winner_identified_day = day + 1
                if best_idx == true_best:
                    days_to_identify_winner.append(day + 1)

            # Track correctness at checkpoints
            if day == 89:  # Day 90
                if means.index(max(means)) == true_best:
                    winner_correct_at_90d += 1
            if day == 179:  # Day 180
                if means.index(max(means)) == true_best:
                    winner_correct_at_180d += 1

        # Store first simulation's history for plotting
        if sim == 0:
            posterior_means_history = daily_means
            posterior_stddevs_history = daily_stddevs

        if winner_identified_day is None:
            days_to_identify_winner.append(float('inf'))

    # Compute results
    finite_days = [d for d in days_to_identify_winner if d != float('inf')]
    never_converged = sum(1 for d in days_to_identify_winner if d == float('inf'))

    def percentile(data, pct):
        if not data:
            return float('inf')
        sorted_data = sorted(data)
        idx = int(len(sorted_data) * pct / 100)
        idx = min(idx, len(sorted_data) - 1)
        return sorted_data[idx]

    return {
        'scenario': config.name,
        'description': config.description,
        'num_treatments': config.num_treatments,
        'opens_per_day': config.opens_per_day_total,
        'opens_per_treatment_day': config.opens_per_day_total // config.num_treatments,
        'median_days_to_converge': median(finite_days) if finite_days else float('inf'),
        'mean_days_to_converge': mean(finite_days) if finite_days else float('inf'),
        'p90_days_to_converge': percentile(finite_days, 90),
        'never_converged_pct': never_converged / n_simulations * 100,
        'winner_correct_90d_pct': winner_correct_at_90d / n_simulations * 100,
        'winner_correct_180d_pct': winner_correct_at_180d / n_simulations * 100,
        'posterior_means_history': posterior_means_history,
        'posterior_stddevs_history': posterior_stddevs_history,
        'true_ctrs': config.true_ctrs,
        'true_best': true_best,
    }


def build_scenarios() -> list:
    """
    Build the four simulation scenarios using corrected data.

    Corrected numbers (from bandit arm analysis, Jan 14 - Feb 6):
    - 92 treatments in pool, 20 with 100+ sends/day (75% of traffic)
    - Per user request: only 4-7 treatments eligible (fitment-filtered)
    - ~5,000 sends/day total → ~750 opens/day (15% open rate)
    - Model trains on opens, rewards = clicks
    - CTR of opens ranges from ~3% to ~12% across treatments

    Real CTR of opens from Q16 (top treatments):
      21265478: 11.53%, 21265506: 10.04%, 21265458: 9.51%,
      21265451: 9.13%, 17049625: 6.98%, 16490939: 5.85%,
      21265485: 5.30%
    """

    total_opens_per_day = 750  # 5000 sends * 15% open rate

    # -- Scenario A: Current state (20 high-traffic treatments) --
    # These 20 treatments have 100+ sends/day and account for 75% of traffic.
    # CTR of opens based on Q16 data: ranges from ~3% to ~12%.
    ctrs_20 = [
        0.115, 0.100, 0.095, 0.091,   # 4 "best" treatments (9-12%)
        0.080, 0.070, 0.065, 0.060,    # 4 "good" treatments (6-8%)
        0.058, 0.053, 0.050, 0.048,    # 4 "average" treatments (5-6%)
        0.045, 0.040, 0.038, 0.035,    # 4 "below average" (3.5-4.5%)
        0.033, 0.030, 0.028, 0.025,    # 4 "poor" (2.5-3.3%)
    ]

    scenario_a = ScenarioConfig(
        name="A: Current (20 treatments)",
        num_treatments=20,
        opens_per_day_total=total_opens_per_day,
        true_ctrs=ctrs_20,
        prior=NIGParams(mu=0, lam=1, alpha=1, beta=1),
        description="20 high-traffic treatments, ~37 opens/trt/day, NIG(0,1,1,1) prior"
    )

    # -- Scenario B: Reduced to 10 treatments --
    # Keep the top 10 by volume; consolidate the rest.
    # 750 opens/day / 10 = 75 opens/treatment/day
    ctrs_10 = [0.115, 0.091, 0.070, 0.058, 0.050,
               0.045, 0.038, 0.033, 0.028, 0.025]

    scenario_b = ScenarioConfig(
        name="B: 10 Treatments",
        num_treatments=10,
        opens_per_day_total=total_opens_per_day,
        true_ctrs=ctrs_10,
        prior=NIGParams(mu=0, lam=1, alpha=1, beta=1),
        description="10 treatments, ~75 opens/trt/day, NIG(0,1,1,1) prior"
    )

    # -- Scenario C: Per-user auction (7 treatments) --
    # Each user only sees 4-7 treatments (fitment-filtered). Median is ~6.
    # This models the ACTUAL competition per user request.
    # 750 opens/day / 7 = 107 opens/treatment/day
    # CTR spread within a user's eligible set is narrower (same fitment segment).
    ctrs_7 = [0.100, 0.085, 0.070, 0.058, 0.045, 0.035, 0.025]

    scenario_c = ScenarioConfig(
        name="C: Per-user (7 treatments)",
        num_treatments=7,
        opens_per_day_total=total_opens_per_day,
        true_ctrs=ctrs_7,
        prior=NIGParams(mu=0, lam=1, alpha=1, beta=1),
        description="7 treatments (per-user fitment), ~107 opens/trt/day, NIG(0,1,1,1)"
    )

    # -- Scenario D: 10 treatments + informative prior --
    # Prior based on known average CTR of opens (~6%).
    # mu=0.06, lambda=50 (moderate confidence), alpha=10, beta=0.3
    scenario_d = ScenarioConfig(
        name="D: 10 Trts + Informative Prior",
        num_treatments=10,
        opens_per_day_total=total_opens_per_day,
        true_ctrs=ctrs_10,
        prior=NIGParams(mu=0.06, lam=50, alpha=10, beta=0.3),
        description="10 treatments, ~75 opens/trt/day, NIG(0.06, 50, 10, 0.3)"
    )

    return [scenario_a, scenario_b, scenario_c, scenario_d]


def print_convergence_table(results: list):
    """Print a formatted results table."""
    print("\n" + "=" * 105)
    print("NIG THOMPSON SAMPLING CONVERGENCE SIMULATION RESULTS")
    print("(observations = opens, rewards = clicks, CTR = clicks/opens)")
    print("=" * 105)
    print(f"{'Scenario':<40} {'Median':>8} {'Mean':>8} {'P90':>8} {'Never%':>8} "
          f"{'90d%':>8} {'180d%':>8}")
    print(f"{'':40} {'(days)':>8} {'(days)':>8} {'(days)':>8} {'convg':>8} "
          f"{'correct':>8} {'correct':>8}")
    print("-" * 105)

    for r in results:
        med = f"{r['median_days_to_converge']:.0f}" if r['median_days_to_converge'] != float('inf') else "NEVER"
        mn = f"{r['mean_days_to_converge']:.0f}" if r['mean_days_to_converge'] != float('inf') else "NEVER"
        p90 = f"{r['p90_days_to_converge']:.0f}" if r['p90_days_to_converge'] != float('inf') else "NEVER"
        print(f"{r['scenario']:<40} {med:>8} {mn:>8} {p90:>8} "
              f"{r['never_converged_pct']:>7.1f}% "
              f"{r['winner_correct_90d_pct']:>7.1f}% "
              f"{r['winner_correct_180d_pct']:>7.1f}%")

    print("-" * 105)


def print_posterior_evolution(result: dict, days_to_show: list = None):
    """Print posterior mean evolution for the best and worst treatments."""
    if days_to_show is None:
        days_to_show = [0, 7, 14, 30, 60, 90, 120, 150, 179]

    means_hist = result['posterior_means_history']
    stddevs_hist = result['posterior_stddevs_history']
    true_best = result['true_best']
    ctrs = result['true_ctrs']

    # Find the worst treatment
    true_worst = ctrs.index(min(ctrs))

    print(f"\n--- Posterior Evolution: {result['scenario']} ---")
    print(f"Best treatment (idx={true_best}, true CTR={ctrs[true_best]:.3%})")
    print(f"Worst treatment (idx={true_worst}, true CTR={ctrs[true_worst]:.3%})")
    print(f"{'Day':>6} {'Best mu':>10} {'Best std':>10} {'Worst mu':>10} "
          f"{'Worst std':>10} {'Gap':>10} {'Separable?':>12}")
    print("-" * 70)

    for d in days_to_show:
        if d >= len(means_hist):
            break
        best_mu = means_hist[d][true_best]
        best_std = stddevs_hist[d][true_best]
        worst_mu = means_hist[d][true_worst]
        worst_std = stddevs_hist[d][true_worst]
        gap = best_mu - worst_mu

        # Check if 95% CIs don't overlap
        best_lower = best_mu - 1.96 * best_std
        worst_upper = worst_mu + 1.96 * worst_std
        separable = "YES" if best_lower > worst_upper else "no"

        print(f"{d+1:>6} {best_mu:>10.6f} {best_std:>10.6f} {worst_mu:>10.6f} "
              f"{worst_std:>10.6f} {gap:>10.6f} {separable:>12}")


def print_scenario_details(results: list):
    """Print detailed analysis for each scenario."""
    print("\n" + "=" * 100)
    print("DETAILED SCENARIO ANALYSIS")
    print("=" * 100)

    for r in results:
        print(f"\n{'=' * 80}")
        print(f"  {r['scenario']}")
        print(f"  {r['description']}")
        print(f"{'=' * 80}")
        print(f"  Treatments: {r['num_treatments']}")
        print(f"  Opens/day total: {r['opens_per_day']:,}")
        print(f"  Opens/treatment/day: {r['opens_per_treatment_day']}")
        print(f"  True best CTR (of opens): {r['true_ctrs'][r['true_best']]:.2%}")

        med = r['median_days_to_converge']
        if med == float('inf'):
            print(f"  Convergence: NEVER (within 180 days)")
        else:
            print(f"  Median days to converge: {med:.0f}")
            print(f"  P90 days to converge: {r['p90_days_to_converge']:.0f}")

        print(f"  Never converged: {r['never_converged_pct']:.1f}% of simulations")
        print(f"  Correct winner at 90 days: {r['winner_correct_90d_pct']:.1f}%")
        print(f"  Correct winner at 180 days: {r['winner_correct_180d_pct']:.1f}%")


def print_key_finding(results: list):
    """Print the headline finding for the report."""
    print("\n" + "=" * 100)
    print("KEY FINDING")
    print("=" * 100)

    a = results[0]  # Current state (20 treatments)
    b = results[1]  # 10 treatments
    c = results[2]  # Per-user (7 treatments)

    if a['median_days_to_converge'] == float('inf') or a['never_converged_pct'] > 40:
        print(f"""
  At current data volume ({a['opens_per_day']:,} opens/day across {a['num_treatments']} treatments),
  the NIG Thompson Sampling model struggles to reliably identify the best treatment.

  - {a['never_converged_pct']:.0f}% of simulations never converged within 180 days
  - Each treatment gets ~{a['opens_per_treatment_day']} opens/day with best CTR {a['true_ctrs'][0]:.1%}
    = ~{a['opens_per_treatment_day'] * a['true_ctrs'][0]:.1f} clicks/day

  ROOT CAUSE: Not a bug -- structural data sparsity.
""")
    else:
        print(f"""
  Current state (20 treatments): converges in ~{a['median_days_to_converge']:.0f} days (median),
  {a['never_converged_pct']:.0f}% never converge.
""")

    print(f"""  COMPARISON:
  Scenario A ({a['num_treatments']} treatments): {a['median_days_to_converge']:.0f} days median, {a['never_converged_pct']:.0f}% never
  Scenario B ({b['num_treatments']} treatments): {b['median_days_to_converge']:.0f} days median, {b['never_converged_pct']:.0f}% never
  Scenario C ({c['num_treatments']} per-user):  {c['median_days_to_converge']:.0f} days median, {c['never_converged_pct']:.0f}% never

  Reducing from {a['num_treatments']} to {b['num_treatments']} treatments = {a['opens_per_treatment_day']}→{b['opens_per_treatment_day']} opens/trt/day
  Per-user view ({c['num_treatments']} treatments) = {c['opens_per_treatment_day']} opens/trt/day
""")


def main():
    print("NIG Thompson Sampling Convergence Simulation (v2 — corrected)")
    print("=" * 60)
    print("Corrected inputs:")
    print("  - Observations = opens (not sends)")
    print("  - 750 opens/day total (5000 sends * 15% open rate)")
    print("  - CTR = clicks/opens (5-12%, not 0.5-2%)")
    print("  - 20 high-traffic treatments (not 30)")
    print("  - Per-user: 4-7 treatments (fitment-filtered)")
    print()
    print("Simulating 200 runs x 180 days for each scenario...")
    print()

    scenarios = build_scenarios()
    results = []

    for config in scenarios:
        print(f"Running {config.name}...", end=" ", flush=True)
        result = simulate_scenario(config, n_days=180, n_simulations=200)
        results.append(result)
        med = result['median_days_to_converge']
        med_str = f"{med:.0f} days" if med != float('inf') else "NEVER"
        print(f"Done. Median convergence: {med_str}")

    # Print all results
    print_convergence_table(results)
    print_scenario_details(results)
    print_posterior_evolution(results[0])  # Current state
    print_posterior_evolution(results[1])  # 10 treatments
    print_posterior_evolution(results[2])  # Per-user
    print_key_finding(results)


if __name__ == "__main__":
    main()
