**Weekly Update - Jan 20, 2026**

*   **ML Pipeline Ownership (Metaflow):** Deep-dived into the full model training-to-production chain — from Metaflow flows running on Kubernetes, to Docker images pushed to Artifact Registry, to PostgreSQL model_config registration that the prediction service reads. This end-to-end understanding unlocks the ability to independently train, deploy, and troubleshoot ML models without relying on the ML platform team for every change.
*   **Deployment Verification Runbooks (Metaflow):** Established standardized runbooks for validating Argo cron jobs and confirming live model updates. These guides provide a clear process to trace a model from a "Succeeded" workflow to its specific Artifact Registry tag and active serving configuration, drastically reducing time spent debugging "silent failures" where workflows pass but models don't update.
*   **Segment-Based Recommendations Validated (Holley):** The shift from global popularity to vehicle-segment recommendations is now live and measured. Open rates nearly tripled (4.25% → 11.88%) and click-through rates nearly doubled (0.48% → 0.93%). A same-user comparison confirmed this isn't seasonal—users who received emails in both periods opened the new recommendations 58% more often. The Personalized treatment is finally outperforming in the metrics that matter.
*   **Next:** Run a training flow end-to-end for a test company, verify the model lands in Artifact Registry with correct tags, and confirm inference picks it up — closing the loop from documentation to hands-on validation. Look into Assurant and generalized recommendation framework.

---

**Weekly Update - Jan 13**

*   **Solving the Relevance Gap**: The recommendation engine has shifted from global popularity to segment-specific sales velocity (v5.7 → v5.17). This ensures owners now see parts their peers actually buy rather than generic "one-size-fits-all" products like headlights that fit 3,000+ cars. Vehicle-specific recommendations now reach 87% of users, and the reliance on generic "global fallback" items has dropped from 24% to just 2%.
*   **Data-Driven Pivots**: Investigation revealed that 65% of actual purchases involve products not currently tracked in the fitment database, explaining why earlier models struggled with relevance. While collaborative filtering was tested, it was deprioritized due to low repeat purchase rates (18%). These findings led to a more effective segment-based popularity model that tailors parts for 1,100+ unique vehicle types and raised average recommended price points from $283 to over $460 by prioritizing high-value components.
*   **Automation & Business Impact**: An automated pipeline via Metaflow is now configured to ensure recommendations stay fresh without manual intervention. The workflow is set up, though a final Gradle dependency issue is currently being resolved before the automated schedule goes live. These improvements have moved the needle on backtest match rates from near-zero to 0.38%, positioning the personalized email program for significantly higher engagement.

---

**Weekly Update - Jan 5**

*   **Found Why Personalized Emails Underperform:** The recommendation engine has been suggesting products based on what sells across *all* vehicles, not what owners of a *specific* vehicle actually buy. For example, 1969 Camaro owners keep seeing a generic headlight that fits 3,000+ cars, while the Camaro-specific console latch they're 6x more likely to purchase never shows up. Less than 1 in 1,000 purchases match the recommendations.
*   **Fix Is Designed, Ready to Build:** The next version will prioritize products that owners of a particular vehicle have historically purchased. A Mustang owner will see what other Mustang owners buy, not just what's popular across the entire catalog. Vehicle-specific parts will rank higher than generic universal parts.
*   **What This Means for the Business:** Once deployed, the email recommendations should feel noticeably more relevant to customers. Early estimates suggest the match rate could improve 50-100x, which should translate to higher click-through and conversion rates on the Personalized treatment.

---

**Weekly Update - Dec 29**

*   **Production Deployment of v5.7:** Rolled out the latest pipeline version with a critical fix for specialized product variants (B/R/G/P suffixes). This ensures users are recommended exact performance parts—like high-output ignition coils—rather than generic base SKUs, protecting the customer experience for over 7,700 technical products.
*   **Resolved Apparel vs. Vehicle Parts Debate:** Addressed concerns that the recommendation logic might be over-indexing on parts. Six months of data confirms hard parts drive 98% of total revenue ($43.8M), while apparel has remained flat at just 4% of orders all year with no growth trend. The data proves the vehicle-centric approach is exactly where the money is.
*   **High-Ticket Revenue Insight:** Further analysis shows that 60% of all vehicle parts revenue comes from items priced over $500 (e.g., fuel injection systems and carburetors). This validates the decision in v5.7 to prioritize these high-value categories, ensuring the engine focuses on the core business drivers.
*   **Bandit Model Outperforming Baseline:** Recent tracking shows the Bandit model is now beating the random baseline on Click-Through-Rate per Send (0.39% vs 0.25%). The model is successfully identifying high-intent segments and driving higher quality traffic, even with the technical complexity of these products.
*   **Deployment Safety Hooks:** Implemented automated SQL validation and guardrails to prevent logic errors from reaching production. This technical "safety net" allows the team to iterate faster and safer on upcoming v6.0 features without risking the live customer experience.