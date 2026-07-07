-- =============================================================================
-- 06_forecasting_preparation.sql
-- Decision Intelligence System — Demand features + forecast table indexing
-- -----------------------------------------------------------------------------
-- Purpose : Prepare the demand-history features that feed the forecasting
--           model, and add performance indexes on forecast_results so the
--           inventory engine (07) and KPI/validation views (08/09) can filter
--           by grain/grain_key/forecast_month efficiently.
-- Run order: 6th. Requires 04_feature_engineering.sql (vw_monthly_sku_performance).
--
-- Context:
--   forecast_results itself is a table (created in 01, populated in 02). It
--   holds outputs from an external Holt-Winters model run in Python, at two
--   grains — SKU (grain='sku') and category (grain='category'). The model was
--   fit against the monthly SKU history summarized by vw_sku_demand_features
--   below, then loaded back in via COPY.
-- =============================================================================

SET client_min_messages = warning;

DROP VIEW  IF EXISTS public.vw_sku_demand_features   CASCADE;
DROP INDEX IF EXISTS public.ix_forecast_results_grain;
DROP INDEX IF EXISTS public.ix_forecast_results_grain_key;
DROP INDEX IF EXISTS public.ix_forecast_results_category;


-- -----------------------------------------------------------------------------
-- Demand features: per-SKU history statistics used as forecast model inputs
--   active_months  — how many months this SKU sold at least one unit
--   total_units    — lifetime unit count
--   past_demand    — average monthly unit demand
--   demand_sigma   — population stddev of monthly demand (0 if only one month)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_demand_features AS
WITH monthly AS (
    SELECT product_id,
           max(category)         AS category,
           order_month,
           sum(units_sold)       AS monthly_units
      FROM public.vw_monthly_sku_performance
     GROUP BY product_id, order_month
)
SELECT 'sku'::text                                                   AS grain,
       product_id,
       max(category)                                                 AS category,
       count(*)                                                      AS active_months,
       sum(monthly_units)                                            AS total_units,
       round(avg(monthly_units), 2)                                  AS past_demand,
       round(COALESCE(stddev_pop(monthly_units), 0::numeric), 2)     AS demand_sigma
  FROM monthly
 GROUP BY product_id;


-- -----------------------------------------------------------------------------
-- Indexes for downstream forecast_results consumers
-- Every inventory / KPI / validation view filters on grain first, then
-- optionally grain_key or category, and often orders by forecast_month DESC.
-- -----------------------------------------------------------------------------
CREATE INDEX ix_forecast_results_grain
    ON public.forecast_results (grain);

CREATE INDEX ix_forecast_results_grain_key
    ON public.forecast_results (grain, grain_key, forecast_month DESC);

CREATE INDEX ix_forecast_results_category
    ON public.forecast_results (category)
    WHERE category IS NOT NULL;
