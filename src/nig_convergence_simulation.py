"""
NIG Thompson Sampling Convergence Simulation
=============================================

Simulates the Normal-Inverse-Gamma Thompson Sampling bandit to determine
how long it takes to differentiate between treatments at various data volumes.

Hypotheses tested:
  A: Current state — 30+ treatments, ~3 clicks/week each, NIG(1,1,0,1)
  B: Reduced treatments — 10 treatments (consolidate similar ones)
  C: Informative prior — NIG(alpha=10, beta=0.3, mu=0.05, lambda=100)
  D: Combined — 10 treatments + informative prior

For each scenario, simulates daily NIG updates over 180 days and measures
how long until the best treatment is reliably identified.

Usage:
  python3 src/nig_convergence_simulation.py

Based on: docs/bandit-models-deep-analysis.md (NIG math formulas)
Data from: Q16 of sql/analysis/bandit_investigation_phase2.sql

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
    sends_per_day_total: int  # Total sends across all treatments
    true_ctrs: list           # True CTR for each treatment
    prior: NIGParams          # Starting prior for each treatment
    description: str


def simulate_scenario(config: ScenarioConfig, n_days: int = 180,
                      n_simulations: int = 200, seed: int = 42) -> dict:
    """
    Simulate NIG Thompson Sampling for a given scenario.

    The model is STATELESS -- retrained from scratch each day using ALL
    historical data (matching Auxia's batch retraining approach).

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

        # Daily sends per treatment (roughly uniform, as observed)
        sends_per_treatment = config.sends_per_day_total // config.num_treatments

        winner_identified_day = None
        daily_means = []
        daily_stddevs = []

        for day in range(n_days):
            # Generate today's data: each treatment gets ~sends_per_treatment sends
            for t in range(config.num_treatments):
                n_sends = sends_per_treatment + rng.randint(-2, 2)
                n_sends = max(1, n_sends)
                # Generate Bernoulli draws
                rewards = [1 if rng.random() < config.true_ctrs[t] else 0
                           for _ in range(n_sends)]
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
        'sends_per_day': config.sends_per_day_total,
        'sends_per_treatment_day': config.sends_per_day_total // config.num_treatments,
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
    Build the four simulation scenarios using real data from Q16.

    Real data (from Holley bandit arm, 120-day window):
    - ~5,000 sends/day total in bandit arm
    - 55-87 active treatments (Q12 finding!)
    - Average CTR of sends: ~1% (clicks/sends)
    - Average CTR of opens: ~7% (clicks/opens)
    - Best treatment CTR: ~2.5% of sends, worst: ~0.2%
    """

    # -- Scenario A: Current state (30 treatments, uninformative prior) --
    # True CTRs based on real Q16 data (clicks/sends):
    # Most treatments cluster around 0.5-1.5%, with a few outliers
    current_ctrs = (
        [0.025, 0.022, 0.020]           # 3 "best" treatments
        + [0.018, 0.015, 0.015, 0.014,
           0.012, 0.012, 0.010, 0.010,
           0.010, 0.009, 0.009, 0.008]  # 12 "average" treatments
        + [0.008, 0.007, 0.007, 0.006,
           0.006, 0.005, 0.005, 0.005,
           0.004, 0.004, 0.003, 0.003,
           0.002, 0.002, 0.001]          # 15 "poor" treatments
    )

    scenario_a = ScenarioConfig(
        name="A: Current State",
        num_treatments=30,
        sends_per_day_total=5000,
        true_ctrs=current_ctrs,
        prior=NIGParams(mu=0, lam=1, alpha=1, beta=1),
        description="30 treatments, ~167 sends/treatment/day, NIG(0,1,1,1) prior"
    )

    # -- Scenario B: Reduced to 10 treatments --
    reduced_ctrs = [0.025, 0.018, 0.015, 0.012, 0.010,
                    0.008, 0.007, 0.005, 0.003, 0.002]

    scenario_b = ScenarioConfig(
        name="B: 10 Treatments",
        num_treatments=10,
        sends_per_day_total=5000,
        true_ctrs=reduced_ctrs,
        prior=NIGParams(mu=0, lam=1, alpha=1, beta=1),
        description="10 treatments, 500 sends/treatment/day, NIG(0,1,1,1) prior"
    )

    # -- Scenario C: Informative prior --
    # Set prior based on historical CTR knowledge:
    # mu=0.008 (known ~0.8% avg CTR), lambda=100 (moderate confidence),
    # alpha=10 (some shape), beta=0.3 (low variance)
    scenario_c = ScenarioConfig(
        name="C: Informative Prior",
        num_treatments=30,
        sends_per_day_total=5000,
        true_ctrs=current_ctrs,
        prior=NIGParams(mu=0.008, lam=100, alpha=10, beta=0.3),
        description="30 treatments, 167 sends/treatment/day, NIG(0.008, 100, 10, 0.3)"
    )

    # -- Scenario D: Combined (fewer treatments + informative prior) --
    scenario_d = ScenarioConfig(
        name="D: 10 Treatments + Informative Prior",
        num_treatments=10,
        sends_per_day_total=5000,
        true_ctrs=reduced_ctrs,
        prior=NIGParams(mu=0.008, lam=100, alpha=10, beta=0.3),
        description="10 treatments, 500 sends/treatment/day, NIG(0.008, 100, 10, 0.3)"
    )

    return [scenario_a, scenario_b, scenario_c, scenario_d]


def print_convergence_table(results: list):
    """Print a formatted results table."""
    print("\n" + "=" * 100)
    print("NIG THOMPSON SAMPLING CONVERGENCE SIMULATION RESULTS")
    print("=" * 100)
    print(f"{'Scenario':<40} {'Median':>8} {'Mean':>8} {'P90':>8} {'Never%':>8} "
          f"{'90d%':>8} {'180d%':>8}")
    print(f"{'':40} {'(days)':>8} {'(days)':>8} {'(days)':>8} {'convg':>8} "
          f"{'correct':>8} {'correct':>8}")
    print("-" * 100)

    for r in results:
        med = f"{r['median_days_to_converge']:.0f}" if r['median_days_to_converge'] != float('inf') else "NEVER"
        mn = f"{r['mean_days_to_converge']:.0f}" if r['mean_days_to_converge'] != float('inf') else "NEVER"
        p90 = f"{r['p90_days_to_converge']:.0f}" if r['p90_days_to_converge'] != float('inf') else "NEVER"
        print(f"{r['scenario']:<40} {med:>8} {mn:>8} {p90:>8} "
              f"{r['never_converged_pct']:>7.1f}% "
              f"{r['winner_correct_90d_pct']:>7.1f}% "
              f"{r['winner_correct_180d_pct']:>7.1f}%")

    print("-" * 100)


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
        print(f"  Sends/day total: {r['sends_per_day']:,}")
        print(f"  Sends/treatment/day: {r['sends_per_treatment_day']}")
        print(f"  True best CTR: {r['true_ctrs'][r['true_best']]:.2%}")

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

    a = results[0]  # Current state
    d = results[3]  # Best scenario

    if a['never_converged_pct'] > 50:
        print(f"""
  At current data volume ({a['sends_per_day']:,} sends/day across {a['num_treatments']} treatments),
  the NIG Thompson Sampling model CANNOT reliably identify the best treatment.

  - {a['never_converged_pct']:.0f}% of simulations never converged within 180 days
  - Even after 180 days, only {a['winner_correct_180d_pct']:.0f}% correctly identified the winner
  - The model correctly outputs posterior means near true CTR, but the CTR differences
    between treatments (~0.5-1.5pp) are smaller than the posterior uncertainty

  ROOT CAUSE: Not a bug -- it's a fundamental data sparsity problem.
  Each treatment gets ~{a['sends_per_treatment_day']} sends/day with ~{a['true_ctrs'][0]:.1%} CTR =
  ~{a['sends_per_treatment_day'] * a['true_ctrs'][0]:.1f} clicks/day. This is insufficient
  to shrink posteriors enough to differentiate treatments.
""")
    else:
        print(f"""
  Current state converges in ~{a['median_days_to_converge']:.0f} days (median).
""")

    if d['never_converged_pct'] < a['never_converged_pct']:
        improvement = a['never_converged_pct'] - d['never_converged_pct']
        print(f"""  RECOMMENDED FIX: {d['scenario']}
  - Reduces non-convergence from {a['never_converged_pct']:.0f}% to {d['never_converged_pct']:.0f}% (-{improvement:.0f}pp)
  - Correct winner at 90 days: {d['winner_correct_90d_pct']:.0f}% (vs {a['winner_correct_90d_pct']:.0f}% current)
  - Correct winner at 180 days: {d['winner_correct_180d_pct']:.0f}% (vs {a['winner_correct_180d_pct']:.0f}% current)
""")


def main():
    print("NIG Thompson Sampling Convergence Simulation")
    print("=" * 50)
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
    print_posterior_evolution(results[3])  # Best scenario
    print_key_finding(results)


if __name__ == "__main__":
    main()
