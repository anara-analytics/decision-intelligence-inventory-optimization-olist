-- =============================================================================
-- 09_validation_checks_views.sql
-- Decision Intelligence System — Forecast quality validation
-- -----------------------------------------------------------------------------
-- Purpose : Views that quantify how much to trust the forecast, per category
--           and per confidence band. Used by reviewers to sanity-check the
--           inventory recommendations coming out of 07.
-- Run order: 9th (last). Requires 04, 07, and forecast_results data from 02.
--
-- Contents:
--   1. vw_forecast_accuracy_by_category  — MAPE/MAE + accuracy grade per cat
--   2. vw_forecast_reliability_summary   — SKU + revenue + $ opportunity by
--                                          confidence band
--   3. vw_forecast_model_comparison      — Holt-Winters vs Naive vs 3-month MA
--   4. vw_forecast_confidence_kpis       — long-form confidence-band scorecard
--   5. vw_category_confidence_coverage   — how many categories have SKU-level
--                                          coverage vs only a category forecast
-- =============================================================================

SET client_min_messages = warning;

DROP VIEW IF EXISTS public.vw_category_confidence_coverage CASCADE;
DROP VIEW IF EXISTS public.vw_forecast_confidence_kpis     CASCADE;
DROP VIEW IF EXISTS public.vw_forecast_model_comparison    CASCADE;
DROP VIEW IF EXISTS public.vw_forecast_reliability_summary CASCADE;
DROP VIEW IF EXISTS public.vw_forecast_accuracy_by_category CASCADE;


-- -----------------------------------------------------------------------------
-- 1. Forecast accuracy by category
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_forecast_accuracy_by_category AS
SELECT category,
       max(model_used)                          AS model_used,
       round(avg(mape_pct), 2)                  AS mape_pct,
       round(avg(mae), 2)                       AS mae,
       max(confidence)                          AS confidence,
       count(*)                                 AS forecast_months,
       round(sum(predicted_units), 2)           AS total_forecast_units,
       CASE
           WHEN avg(mape_pct) < 20::numeric THEN 'Strong'
           WHEN avg(mape_pct) < 50::numeric THEN 'Moderate'
           ELSE 'Weak'
       END AS accuracy_grade
  FROM public.forecast_results
 WHERE grain = 'category'
 GROUP BY category
 ORDER BY avg(mape_pct);


-- -----------------------------------------------------------------------------
-- 2. Forecast reliability summary — SKU/revenue/opportunity by confidence band
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_forecast_reliability_summary AS
WITH base AS (
    SELECT e.confidence,
           p.gross_revenue,
           CASE e.verdict
               WHEN 'DISCONTINUE'  THEN GREATEST(-e.net_profit, 0::numeric)
               WHEN 'REDUCE STOCK' THEN e.excess_units * e.unit_cogs
               WHEN 'REORDER NOW'  THEN e.at_risk_units * e.unit_price
               ELSE 0::numeric
           END AS opportunity_brl
      FROM public.vw_inventory_decision_engine e
      JOIN public.vw_sku_profitability p ON p.product_id = e.product_id
),
agg AS (
    SELECT confidence,
           count(*)                        AS sku_count,
           round(sum(gross_revenue), 2)    AS revenue_brl,
           round(sum(opportunity_brl), 2)  AS opportunity_brl
      FROM base
     GROUP BY confidence
)
SELECT confidence,
       sku_count,
       round(sku_count::numeric * 100.0 / sum(sku_count) OVER (), 1)                              AS pct_of_skus,
       revenue_brl,
       opportunity_brl,
       round(opportunity_brl * 100.0 / NULLIF(sum(opportunity_brl) OVER (), 0::numeric), 1)       AS pct_of_opportunity
  FROM agg
 ORDER BY CASE confidence WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END;


-- -----------------------------------------------------------------------------
-- 3. Model comparison — Holt-Winters vs naive baselines
--    Baselines are hard-coded reference numbers from the model bake-off; the
--    Holt-Winters row is computed live from forecast_results.
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_forecast_model_comparison AS
WITH hw AS (
    SELECT round((percentile_cont(0.5) WITHIN GROUP (ORDER BY s.mae::double precision))::numeric, 2)      AS median_mae,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY s.mape_pct::double precision))::numeric, 1) AS median_mape,
           round(avg(s.mae), 2)      AS mean_mae,
           round(avg(s.mape_pct), 1) AS mean_mape
      FROM (SELECT DISTINCT ON (grain_key) grain_key, mae, mape_pct
              FROM public.forecast_results
             WHERE grain = 'sku'
             ORDER BY grain_key, forecast_month DESC) s
)
SELECT sort_order, model, median_mae, median_mape_pct,
       captures_trend, confidence_bands, notes
  FROM (
    SELECT 1 AS sort_order,
           'Naive (last-value)'::text  AS model,
           3.20::numeric               AS median_mae,
           95.0::numeric               AS median_mape_pct,
           false                       AS captures_trend,
           false                       AS confidence_bands,
           'Carries last observed value forward; no trend, no uncertainty.'::text AS notes
    UNION ALL
    SELECT 2, '3-month Moving Average', 2.80::numeric, 82.0::numeric, false, false,
           'Smooths recent demand; still no trend term or confidence bands.'
    UNION ALL
    SELECT 3, 'Holt-Winters (selected)', hw.median_mae, hw.median_mape, true, true,
           'Selected model: best MAE, models trend, produces confidence bands and labels.'
      FROM hw
  ) m
 ORDER BY sort_order;


-- -----------------------------------------------------------------------------
-- 4. Forecast confidence KPIs — long-form scorecard (metric, value, display)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_forecast_confidence_kpis AS
WITH sku_conf AS (
    SELECT DISTINCT ON (grain_key) grain_key, confidence, mape_pct, mae
      FROM public.forecast_results
     WHERE grain = 'sku'
     ORDER BY grain_key, forecast_month DESC
),
band AS (
    SELECT confidence,
           count(*)                                                                                  AS sku_count,
           round(avg(mape_pct), 1)                                                                   AS avg_mape,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY mape_pct::double precision))::numeric, 1) AS median_mape,
           round(avg(mae), 2)                                                                        AS avg_mae
      FROM sku_conf
     GROUP BY confidence
),
totals AS (
    SELECT sum(sku_count) AS total_skus,
           sum(sku_count) FILTER (WHERE confidence IN ('high','medium')) AS high_med_skus
      FROM band
),
opp AS (
    SELECT e.confidence,
           round(sum(CASE e.verdict
                         WHEN 'DISCONTINUE'  THEN GREATEST(-e.net_profit, 0::numeric)
                         WHEN 'REDUCE STOCK' THEN e.excess_units * e.unit_cogs
                         WHEN 'REORDER NOW'  THEN e.at_risk_units * e.unit_price
                         ELSE 0::numeric
                     END), 2) AS opportunity_brl
      FROM public.vw_inventory_decision_engine e
     GROUP BY e.confidence
),
total_opp AS ( SELECT sum(opportunity_brl) AS total_opportunity FROM opp ),
metrics AS (
    SELECT 1 AS sort_order, 'High-confidence SKUs (count)'::text AS metric,
           b.sku_count::numeric AS value, b.sku_count::text AS value_display
      FROM band b WHERE b.confidence = 'high'
    UNION ALL
    SELECT 2, 'High-confidence SKUs (% of total)',
           round(b.sku_count::numeric * 100.0 / NULLIF(t.total_skus, 0::numeric), 1),
           to_char(round(b.sku_count::numeric * 100.0 / NULLIF(t.total_skus, 0::numeric), 1), 'FM9990.0') || '%'
      FROM band b, totals t WHERE b.confidence = 'high'
    UNION ALL
    SELECT 3, 'High-confidence — median MAPE',
           b.median_mape,
           to_char(b.median_mape, 'FM9990.0') || '%'
      FROM band b WHERE b.confidence = 'high'
    UNION ALL
    SELECT 4, 'High-confidence — opportunity (BRL)',
           o.opportunity_brl,
           'R$' || to_char(o.opportunity_brl, 'FM999,999,990.00')
      FROM opp o WHERE o.confidence = 'high'
    UNION ALL
    SELECT 5, 'High-confidence — % of total opportunity',
           round(o.opportunity_brl * 100.0 / NULLIF(tot.total_opportunity, 0::numeric), 1),
           to_char(round(o.opportunity_brl * 100.0 / NULLIF(tot.total_opportunity, 0::numeric), 1), 'FM9990.0') || '%'
      FROM opp o, total_opp tot WHERE o.confidence = 'high'
    UNION ALL
    SELECT 6, 'Medium-confidence SKUs (count)',
           b.sku_count::numeric, b.sku_count::text
      FROM band b WHERE b.confidence = 'medium'
    UNION ALL
    SELECT 7, 'Medium-confidence SKUs (% of total)',
           round(b.sku_count::numeric * 100.0 / NULLIF(t.total_skus, 0::numeric), 1),
           to_char(round(b.sku_count::numeric * 100.0 / NULLIF(t.total_skus, 0::numeric), 1), 'FM9990.0') || '%'
      FROM band b, totals t WHERE b.confidence = 'medium'
    UNION ALL
    SELECT 8, 'Medium-confidence — median MAPE',
           b.median_mape,
           to_char(b.median_mape, 'FM9990.0') || '%'
      FROM band b WHERE b.confidence = 'medium'
    UNION ALL
    SELECT 9, 'Medium-confidence — opportunity (BRL)',
           o.opportunity_brl,
           'R$' || to_char(o.opportunity_brl, 'FM999,999,990.00')
      FROM opp o WHERE o.confidence = 'medium'
    UNION ALL
    SELECT 10, 'Medium-confidence — % of total opportunity',
           round(o.opportunity_brl * 100.0 / NULLIF(tot.total_opportunity, 0::numeric), 1),
           to_char(round(o.opportunity_brl * 100.0 / NULLIF(tot.total_opportunity, 0::numeric), 1), 'FM9990.0') || '%'
      FROM opp o, total_opp tot WHERE o.confidence = 'medium'
    UNION ALL
    SELECT 11, 'Low-confidence SKUs (count)',
           b.sku_count::numeric, b.sku_count::text
      FROM band b WHERE b.confidence = 'low'
    UNION ALL
    SELECT 12, 'Low-confidence SKUs (% of total)',
           round(b.sku_count::numeric * 100.0 / NULLIF(t.total_skus, 0::numeric), 1),
           to_char(round(b.sku_count::numeric * 100.0 / NULLIF(t.total_skus, 0::numeric), 1), 'FM9990.0') || '%'
      FROM band b, totals t WHERE b.confidence = 'low'
    UNION ALL
    SELECT 13, 'Low-confidence — median MAPE',
           b.median_mape,
           to_char(b.median_mape, 'FM9990.0') || '%'
      FROM band b WHERE b.confidence = 'low'
    UNION ALL
    SELECT 14, 'Low-confidence — opportunity (BRL)',
           o.opportunity_brl,
           'R$' || to_char(o.opportunity_brl, 'FM999,999,990.00')
      FROM opp o WHERE o.confidence = 'low'
    UNION ALL
    SELECT 15, 'Low-confidence — % of total opportunity',
           round(o.opportunity_brl * 100.0 / NULLIF(tot.total_opportunity, 0::numeric), 1),
           to_char(round(o.opportunity_brl * 100.0 / NULLIF(tot.total_opportunity, 0::numeric), 1), 'FM9990.0') || '%'
      FROM opp o, total_opp tot WHERE o.confidence = 'low'
    UNION ALL
    SELECT 16, 'High + Medium SKUs (actionable confidence)',
           t.high_med_skus, t.high_med_skus::text
      FROM totals t
    UNION ALL
    SELECT 17, 'High + Medium share of total SKUs',
           round(t.high_med_skus * 100.0 / NULLIF(t.total_skus, 0::numeric), 1),
           to_char(round(t.high_med_skus * 100.0 / NULLIF(t.total_skus, 0::numeric), 1), 'FM9990.0') || '%'
      FROM totals t
    UNION ALL
    SELECT 18, 'Median MAPE — High-confidence SKUs only',
           b.median_mape,
           to_char(b.median_mape, 'FM9990.0') || '%'
      FROM band b WHERE b.confidence = 'high'
    UNION ALL
    SELECT 19, 'Median MAPE — all forecastable SKUs',
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY sc.mape_pct::double precision))::numeric, 1),
           to_char(round((percentile_cont(0.5) WITHIN GROUP (ORDER BY sc.mape_pct::double precision))::numeric, 1), 'FM9990.0') || '%'
      FROM sku_conf sc
)
SELECT metric, value, value_display FROM metrics ORDER BY sort_order;


-- -----------------------------------------------------------------------------
-- 5. Category confidence coverage — SKU-level vs category-only forecasts
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_category_confidence_coverage AS
WITH sku_conf AS (
    SELECT DISTINCT ON (grain_key) category, confidence
      FROM public.forecast_results
     WHERE grain = 'sku'
     ORDER BY grain_key, forecast_month DESC
),
cat_conf AS (
    SELECT DISTINCT ON (grain_key) grain_key AS category, confidence
      FROM public.forecast_results
     WHERE grain = 'category'
     ORDER BY grain_key, forecast_month DESC
),
cat_sku_dominant AS (
    SELECT DISTINCT ON (x.category) x.category, x.confidence AS sku_dominant_confidence
      FROM (SELECT sku_conf.category,
                   sku_conf.confidence,
                   count(*) AS n
              FROM sku_conf
             GROUP BY sku_conf.category, sku_conf.confidence) x
     ORDER BY x.category, x.n DESC,
              CASE x.confidence WHEN 'high' THEN 1 WHEN 'medium' THEN 2 ELSE 3 END
),
category_effective AS (
    SELECT c.category,
           CASE WHEN d.category IS NOT NULL THEN 'sku-forecast' ELSE 'category-only' END AS coverage_type,
           COALESCE(d.sku_dominant_confidence, c.confidence)                             AS effective_confidence
      FROM cat_conf c
      LEFT JOIN cat_sku_dominant d ON d.category = c.category
)
SELECT effective_confidence AS confidence,
       CASE effective_confidence
           WHEN 'high'   THEN 'MAPE < 20%'
           WHEN 'medium' THEN 'MAPE 20–50%'
           WHEN 'low'    THEN 'MAPE > 50%'
       END AS mape_threshold,
       count(*)                                                                                    AS category_count,
       round(count(*)::numeric * 100.0 / NULLIF(sum(count(*)) OVER (), 0::numeric), 1)             AS pct_of_categories,
       count(*) FILTER (WHERE coverage_type = 'sku-forecast')                                      AS categories_with_sku_forecast,
       count(*) FILTER (WHERE coverage_type = 'category-only')                                     AS categories_category_only
  FROM category_effective
 GROUP BY effective_confidence
 ORDER BY CASE effective_confidence WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END;
