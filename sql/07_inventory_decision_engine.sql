-- =============================================================================
-- 07_inventory_decision_engine.sql
-- Decision Intelligence System — Inventory verdicts, risk, and action views
-- -----------------------------------------------------------------------------
-- Purpose : Merge forecast + demand features + profitability into per-SKU and
--           per-category inventory verdicts (REORDER NOW / HOLD / REDUCE STOCK
--           / DISCONTINUE), then layer risk registers, action sheets, and
--           strategy-vs-ops reconciliation on top.
-- Run order: 7th. Requires 04 (SKU features) + 06 (demand features + indexes)
--           + 02 (forecast_results data).
--
-- Model parameters (defined inline via a params CTE per engine view):
--   lead_time_months       = 2.0    -- restock lead time
--   z_service_level        = 1.65   -- ~95% service level
--   coverage_months        = 4.0    -- modeled current stock = 4x past demand
--   overstock_multiple     = 3.0    -- flag REDUCE STOCK above 3x reorder point
--   dead_demand_threshold  = 1.0    -- units/month floor for "dead" SKUs
--   margin_floor_pct       = 10.0   -- margin floor below which DISCONTINUE gates
--
-- Dependency order enforced below.
-- =============================================================================

SET client_min_messages = warning;

-- Drop leaves before roots so re-runs work
DROP VIEW IF EXISTS public.vw_inventory_business_impact_by_category CASCADE;
DROP VIEW IF EXISTS public.vw_inventory_business_impact             CASCADE;
DROP VIEW IF EXISTS public.vw_sku_monthly_fact                      CASCADE;
DROP VIEW IF EXISTS public.vw_sku_snapshot                          CASCADE;
DROP VIEW IF EXISTS public.vw_sku_master_action_sheet               CASCADE;
DROP VIEW IF EXISTS public.vw_strategy_operations_matrix            CASCADE;
DROP VIEW IF EXISTS public.vw_strategy_operations                   CASCADE;
DROP VIEW IF EXISTS public.vw_profitability_quadrant                CASCADE;
DROP VIEW IF EXISTS public.vw_profit_optimization                   CASCADE;
DROP VIEW IF EXISTS public.vw_stockout_risk_register                CASCADE;
DROP VIEW IF EXISTS public.vw_demand_trend_shift                    CASCADE;
DROP VIEW IF EXISTS public.vw_inventory_decision_category           CASCADE;
DROP VIEW IF EXISTS public.vw_inventory_decision_engine             CASCADE;


-- -----------------------------------------------------------------------------
-- Core engine: per-SKU inventory verdict
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_inventory_decision_engine AS
WITH params AS (
    SELECT 2.0  AS lead_time_months,
           1.65 AS z_service_level,
           4.0  AS coverage_months,
           3.0  AS overstock_multiple,
           1.0  AS dead_demand_threshold,
           10.0 AS margin_floor_pct
),
sku_forecast AS (
    SELECT grain_key                            AS product_id,
           max(category)                        AS category,
           round(avg(predicted_units), 2)       AS forecast_demand,
           round(avg(mape_pct), 2)              AS mape_pct,
           round(avg(mae), 2)                   AS mae,
           max(confidence)                      AS confidence
      FROM public.forecast_results
     WHERE grain = 'sku'
     GROUP BY grain_key
),
base AS (
    SELECT f.product_id,
           f.category,
           f.forecast_demand,
           f.mape_pct,
           f.mae,
           f.confidence,
           d.past_demand,
           d.demand_sigma,
           p.net_profit,
           p.profit_margin_pct,
           r.units_sold,
           round(c.cogs_total    / NULLIF(r.units_sold, 0)::numeric, 2) AS unit_cogs,
           round(r.gross_revenue::numeric / NULLIF(r.units_sold, 0)::numeric, 2) AS unit_price
      FROM sku_forecast f
      JOIN public.vw_sku_demand_features d ON d.product_id = f.product_id
      JOIN public.vw_sku_profitability   p ON p.product_id = f.product_id
      JOIN public.vw_sku_revenue         r ON r.product_id = f.product_id
      JOIN public.vw_sku_costs           c ON c.product_id = f.product_id
),
calc AS (
    SELECT b.*,
           pa.lead_time_months,
           pa.coverage_months,
           pa.overstock_multiple,
           pa.dead_demand_threshold,
           pa.margin_floor_pct,
           round(pa.z_service_level * b.demand_sigma * sqrt(pa.lead_time_months), 2) AS safety_stock,
           round(b.forecast_demand * pa.lead_time_months
                 + pa.z_service_level * b.demand_sigma * sqrt(pa.lead_time_months), 2) AS reorder_point,
           round(pa.coverage_months * b.past_demand, 2)                              AS modeled_current_stock
      FROM base b CROSS JOIN params pa
)
SELECT product_id,
       category,
       forecast_demand,
       past_demand,
       demand_sigma,
       net_profit,
       profit_margin_pct,
       unit_cogs,
       unit_price,
       lead_time_months,
       safety_stock,
       reorder_point,
       modeled_current_stock,
       mape_pct,
       mae,
       confidence,
       CASE
           WHEN forecast_demand < dead_demand_threshold
                AND profit_margin_pct < margin_floor_pct         THEN 'DISCONTINUE'
           WHEN modeled_current_stock <= reorder_point           THEN 'REORDER NOW'
           WHEN modeled_current_stock > overstock_multiple * reorder_point THEN 'REDUCE STOCK'
           ELSE 'HOLD'
       END AS verdict,
       GREATEST(modeled_current_stock - reorder_point, 0::numeric) AS excess_units,
       round(forecast_demand * lead_time_months, 2)                AS at_risk_units
  FROM calc;


-- -----------------------------------------------------------------------------
-- Category-level engine (does not depend on the SKU engine)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_inventory_decision_category AS
WITH params AS (
    SELECT 2.0 AS lead_time_months, 1.65 AS z_service_level, 4.0 AS coverage_months,
           3.0 AS overstock_multiple, 1.0 AS dead_demand_threshold, 10.0 AS margin_floor_pct
),
cat_forecast AS (
    SELECT category,
           round(avg(predicted_units), 2) AS forecast_demand,
           round(avg(mape_pct), 2)        AS mape_pct,
           round(avg(mae), 2)             AS mae,
           max(confidence)                AS confidence
      FROM public.forecast_results
     WHERE grain = 'category'
     GROUP BY category
),
cat_monthly AS (
    SELECT category, order_month, sum(units_sold) AS monthly_units
      FROM public.vw_monthly_sku_performance
     GROUP BY category, order_month
),
cat_demand AS (
    SELECT category,
           round(avg(monthly_units), 2)                            AS past_demand,
           round(COALESCE(stddev_pop(monthly_units), 0::numeric), 2) AS demand_sigma
      FROM cat_monthly
     GROUP BY category
),
cat_econ AS (
    SELECT p.category,
           sum(p.net_profit)                                                    AS net_profit,
           round(sum(p.net_profit) * 100.0 / NULLIF(sum(p.gross_revenue), 0::numeric), 2) AS profit_margin_pct,
           round(sum(c.cogs_total)     / NULLIF(sum(r.units_sold), 0)::numeric, 2) AS unit_cogs,
           round(sum(p.gross_revenue)  / NULLIF(sum(r.units_sold), 0)::numeric, 2) AS unit_price
      FROM public.vw_sku_profitability p
      JOIN public.vw_sku_revenue       r ON r.product_id = p.product_id
      JOIN public.vw_sku_costs         c ON c.product_id = p.product_id
     GROUP BY p.category
),
calc AS (
    SELECT f.category,
           f.forecast_demand, d.past_demand, d.demand_sigma,
           e.net_profit, e.profit_margin_pct, e.unit_cogs, e.unit_price,
           f.mape_pct, f.mae, f.confidence,
           pa.overstock_multiple, pa.dead_demand_threshold, pa.margin_floor_pct,
           round(pa.z_service_level * d.demand_sigma * sqrt(pa.lead_time_months), 2) AS safety_stock,
           round(f.forecast_demand * pa.lead_time_months
                 + pa.z_service_level * d.demand_sigma * sqrt(pa.lead_time_months), 2) AS reorder_point,
           round(pa.coverage_months * d.past_demand, 2) AS modeled_current_stock
      FROM cat_forecast f
      JOIN cat_demand   d ON d.category = f.category
      JOIN cat_econ     e ON e.category = f.category
      CROSS JOIN params pa
)
SELECT category, forecast_demand, past_demand, demand_sigma,
       net_profit, profit_margin_pct, safety_stock, reorder_point,
       modeled_current_stock, mape_pct, mae, confidence,
       CASE
           WHEN forecast_demand < dead_demand_threshold
                AND profit_margin_pct < margin_floor_pct         THEN 'DISCONTINUE'
           WHEN modeled_current_stock <= reorder_point           THEN 'REORDER NOW'
           WHEN modeled_current_stock > overstock_multiple * reorder_point THEN 'REDUCE STOCK'
           ELSE 'HOLD'
       END AS verdict
  FROM calc;


-- -----------------------------------------------------------------------------
-- Demand trend: forecast vs past average, GROWING/STABLE/DECLINING
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_demand_trend_shift AS
SELECT product_id,
       category,
       round(past_demand)::integer      AS past_demand_units,
       round(forecast_demand)::integer  AS forecast_demand_units,
       round((forecast_demand - past_demand) * 100.0 / NULLIF(past_demand, 0::numeric), 1) AS demand_change_pct,
       verdict,
       CASE
           WHEN past_demand = 0::numeric                                                        THEN 'New / sporadic'
           WHEN ((forecast_demand - past_demand) * 100.0 / NULLIF(past_demand, 0::numeric)) >  15::numeric THEN 'GROWING'
           WHEN ((forecast_demand - past_demand) * 100.0 / NULLIF(past_demand, 0::numeric)) < -15::numeric THEN 'DECLINING'
           ELSE 'STABLE'
       END AS trend_flag
  FROM public.vw_inventory_decision_engine
 ORDER BY demand_change_pct DESC NULLS LAST;


-- -----------------------------------------------------------------------------
-- Stockout risk register — SKUs flagged REORDER NOW, ranked by $ at risk
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_stockout_risk_register AS
SELECT product_id,
       category,
       round(forecast_demand)::integer       AS forecast_demand_units,
       round(modeled_current_stock)::integer AS modeled_stock_units,
       round(reorder_point)::integer         AS reorder_point_units,
       round(modeled_current_stock / NULLIF(forecast_demand, 0::numeric), 1) AS months_of_cover,
       round(at_risk_units * unit_price, 2)  AS sales_at_risk_brl,
       confidence,
       CASE
           WHEN modeled_current_stock / NULLIF(forecast_demand, 0::numeric) < 1::numeric THEN 'Critical — depletes within a month'
           WHEN modeled_current_stock / NULLIF(forecast_demand, 0::numeric) < lead_time_months THEN 'High — depletes before restock lands'
           ELSE 'Elevated — below reorder point'
       END AS urgency,
       row_number() OVER (ORDER BY at_risk_units * unit_price DESC) AS risk_rank
  FROM public.vw_inventory_decision_engine
 WHERE verdict = 'REORDER NOW'
 ORDER BY sales_at_risk_brl DESC;


-- -----------------------------------------------------------------------------
-- Profit optimization — prioritized action list (non-HOLD verdicts)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_profit_optimization AS
SELECT product_id,
       category,
       verdict,
       profit_margin_pct,
       round(forecast_demand)::integer       AS forecast_demand_units,
       round(modeled_current_stock)::integer AS modeled_stock_units,
       round(reorder_point)::integer         AS reorder_point_units,
       round(CASE verdict
                 WHEN 'DISCONTINUE'  THEN GREATEST(-net_profit, 0::numeric)
                 WHEN 'REDUCE STOCK' THEN excess_units * unit_cogs
                 WHEN 'REORDER NOW'  THEN at_risk_units * unit_price
                 ELSE 0::numeric
             END, 2) AS opportunity_value_brl,
       CASE verdict
           WHEN 'DISCONTINUE'  THEN 'Delist — stop carrying a dead, loss-making SKU'
           WHEN 'REDUCE STOCK' THEN 'Run down / promote — free trapped capital'
           WHEN 'REORDER NOW'  THEN 'Replenish now — protect forecast sales from stockout'
           ELSE 'No action'
       END AS recommended_action,
       row_number() OVER (ORDER BY
           CASE verdict
               WHEN 'DISCONTINUE'  THEN GREATEST(-net_profit, 0::numeric)
               WHEN 'REDUCE STOCK' THEN excess_units * unit_cogs
               WHEN 'REORDER NOW'  THEN at_risk_units * unit_price
               ELSE 0::numeric
           END DESC) AS priority_rank
  FROM public.vw_inventory_decision_engine
 WHERE verdict <> 'HOLD'
 ORDER BY opportunity_value_brl DESC;


-- -----------------------------------------------------------------------------
-- Profitability quadrant — margin x review star quadrants + demand trend
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_profitability_quadrant AS
SELECT p.product_id,
       p.category,
       p.avg_review_score,
       (to_char(round(p.profit_margin_pct, 1), 'FM990.0') || '%') AS profit_margin_pct,
       ('$' || to_char(round(p.net_profit, 2), 'FM999,999,990.00')) AS net_profit,
       CASE
           WHEN p.avg_review_score >= 4.0 AND p.profit_margin_pct >= 20::numeric THEN 'Star — loved & profitable'
           WHEN p.avg_review_score >= 4.0 AND p.profit_margin_pct <  20::numeric THEN 'Fix economics — loved but thin/losing'
           WHEN p.avg_review_score <  4.0 AND p.profit_margin_pct >= 20::numeric THEN 'Fix experience — profitable but disliked'
           ELSE 'Review for exit — weak on both'
       END AS quadrant,
       round(e.forecast_demand)::integer AS forecast_demand_units,
       CASE
           WHEN e.forecast_demand IS NULL                                                              THEN 'No forecast'
           WHEN e.past_demand = 0::numeric                                                             THEN 'New / sporadic'
           WHEN ((e.forecast_demand - e.past_demand) * 100.0 / NULLIF(e.past_demand, 0::numeric)) >  15::numeric THEN 'GROWING'
           WHEN ((e.forecast_demand - e.past_demand) * 100.0 / NULLIF(e.past_demand, 0::numeric)) < -15::numeric THEN 'DECLINING'
           ELSE 'STABLE'
       END AS demand_trend,
       COALESCE(to_char(round((e.forecast_demand - e.past_demand) * 100.0
                              / NULLIF(e.past_demand, 0::numeric), 1), 'FM990.0') || '%', '—') AS demand_change_pct,
       COALESCE(e.confidence, 'n/a') AS forecast_confidence
  FROM public.vw_sku_profitability p
  LEFT JOIN public.vw_inventory_decision_engine e ON e.product_id = p.product_id
 WHERE p.avg_review_score IS NOT NULL
 ORDER BY p.net_profit DESC;


-- -----------------------------------------------------------------------------
-- Strategy x Operations — reconciles SCALE/OPTIMIZE/EXIT with ops verdicts
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_strategy_operations AS
SELECT c.product_id,
       c.category,
       c.decision  AS strategy_class,
       e.verdict   AS inventory_verdict,
       c.profit_margin_pct,
       c.avg_review_score,
       round(e.forecast_demand)::integer AS forecast_demand_units,
       CASE
           WHEN c.decision = 'SCALE' AND e.verdict = 'DISCONTINUE'  THEN 'Conflict: strategic winner flagged dead — investigate'
           WHEN c.decision = 'EXIT'  AND e.verdict = 'REORDER NOW'  THEN 'Conflict: restocking a SKU marked for exit — confirm first'
           WHEN c.decision = 'SCALE' AND e.verdict = 'REORDER NOW'  THEN 'Priority: grow & restock — protect a winner'
           WHEN c.decision = 'EXIT'  AND e.verdict = 'DISCONTINUE'  THEN 'Consensus exit — strategy & ops agree, drop it'
           WHEN e.verdict = 'REDUCE STOCK'                          THEN 'Free capital — trim overstock'
           ELSE 'Maintain'
       END AS combined_signal
  FROM public.vw_sku_classification    c
  JOIN public.vw_inventory_decision_engine e ON e.product_id = c.product_id;


CREATE VIEW public.vw_strategy_operations_matrix AS
SELECT c.decision AS strategy_class,
       count(*) FILTER (WHERE e.verdict = 'REORDER NOW')  AS reorder_now,
       count(*) FILTER (WHERE e.verdict = 'HOLD')         AS hold,
       count(*) FILTER (WHERE e.verdict = 'REDUCE STOCK') AS reduce_stock,
       count(*) FILTER (WHERE e.verdict = 'DISCONTINUE')  AS discontinue,
       count(*)                                           AS total_skus
  FROM public.vw_sku_classification    c
  JOIN public.vw_inventory_decision_engine e ON e.product_id = c.product_id
 GROUP BY c.decision
 ORDER BY count(*) DESC;


-- -----------------------------------------------------------------------------
-- Master action sheet — one row per SKU, ops + strategy + $ opportunity
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_master_action_sheet AS
SELECT e.product_id,
       e.category,
       r.units_sold,
       c.gross_revenue,
       c.net_profit,
       c.profit_margin_pct,
       c.avg_review_score,
       c.sku_rank,
       c.decision  AS strategy_class,
       e.verdict   AS inventory_verdict,
       round(e.forecast_demand)::integer       AS forecast_demand_units,
       round(e.modeled_current_stock)::integer AS modeled_stock_units,
       round(e.reorder_point)::integer         AS reorder_point_units,
       round(e.modeled_current_stock / NULLIF(e.forecast_demand, 0::numeric), 1) AS months_of_cover,
       round(CASE e.verdict
                 WHEN 'DISCONTINUE'  THEN GREATEST(-e.net_profit, 0::numeric)
                 WHEN 'REDUCE STOCK' THEN e.excess_units * e.unit_cogs
                 WHEN 'REORDER NOW'  THEN e.at_risk_units * e.unit_price
                 ELSE 0::numeric
             END, 2) AS opportunity_value_brl,
       round(e.modeled_current_stock * e.unit_cogs, 2) AS deployed_capital_brl,
       e.mape_pct,
       e.confidence
  FROM public.vw_inventory_decision_engine e
  JOIN public.vw_sku_classification c ON c.product_id = e.product_id
  JOIN public.vw_sku_revenue        r ON r.product_id = e.product_id;


-- -----------------------------------------------------------------------------
-- SKU snapshot — richer per-SKU record used for the sku detail page
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_snapshot AS
SELECT e.product_id,
       e.category,
       c.sku_rank,
       c.decision AS strategy_class,
       e.verdict  AS inventory_verdict,
       r.units_sold        AS total_units_sold,
       r.gross_revenue     AS total_revenue,
       c.net_profit        AS total_net_profit,
       round(r.units_sold::numeric * e.unit_cogs, 2) AS total_cogs_brl,
       c.profit_margin_pct,
       c.avg_review_score,
       e.unit_cogs,
       e.unit_price,
       round(e.forecast_demand)::integer       AS forecast_demand_units,
       round(e.modeled_current_stock)::integer AS modeled_stock_units,
       round(e.reorder_point)::integer         AS reorder_point_units,
       round(e.modeled_current_stock / NULLIF(e.forecast_demand, 0::numeric), 1) AS months_of_cover,
       round(CASE e.verdict
                 WHEN 'DISCONTINUE'  THEN GREATEST(-e.net_profit, 0::numeric)
                 WHEN 'REDUCE STOCK' THEN e.excess_units * e.unit_cogs
                 WHEN 'REORDER NOW'  THEN e.at_risk_units * e.unit_price
                 ELSE 0::numeric
             END, 2) AS opportunity_value_brl,
       round(e.modeled_current_stock * e.unit_cogs, 2) AS deployed_capital_brl,
       e.mape_pct,
       e.mae,
       e.confidence
  FROM public.vw_inventory_decision_engine e
  JOIN public.vw_sku_classification c ON c.product_id = e.product_id
  JOIN public.vw_sku_revenue        r ON r.product_id = e.product_id;


-- -----------------------------------------------------------------------------
-- Monthly SKU fact — pairs monthly performance with unit economics
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_monthly_fact AS
SELECT a.product_id,
       a.category,
       a.order_month,
       a.units_sold,
       a.revenue                                                       AS monthly_revenue,
       round(a.units_sold::numeric * e.unit_cogs, 2)                   AS monthly_cogs_brl,
       round(a.revenue - a.units_sold::numeric * e.unit_cogs, 2)       AS monthly_gross_profit_brl,
       a.avg_review_score                                              AS monthly_avg_review_score
  FROM public.vw_monthly_sku_performance a
  JOIN public.vw_inventory_decision_engine e ON e.product_id = a.product_id;


-- -----------------------------------------------------------------------------
-- Business-impact roll-up (all verdicts, formatted for exec deck)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_inventory_business_impact AS
WITH per_verdict AS (
    SELECT verdict,
           count(*) AS sku_count,
           round(sum(CASE
                        WHEN verdict = 'DISCONTINUE'  THEN GREATEST(-net_profit, 0::numeric)
                        WHEN verdict = 'REDUCE STOCK' THEN excess_units * unit_cogs
                        WHEN verdict = 'REORDER NOW'  THEN at_risk_units * unit_price
                        ELSE 0::numeric
                    END), 2) AS opportunity_brl,
           round(sum(modeled_current_stock * unit_cogs), 2) AS deployed_capital_brl
      FROM public.vw_inventory_decision_engine
     GROUP BY verdict
),
labeled AS (
    SELECT CASE verdict
               WHEN 'DISCONTINUE'  THEN 1
               WHEN 'REDUCE STOCK' THEN 2
               WHEN 'REORDER NOW'  THEN 3
               WHEN 'HOLD'         THEN 4
           END AS sort_order,
           CASE verdict
               WHEN 'DISCONTINUE'  THEN 'DISCONTINUE — losses eliminated'
               WHEN 'REDUCE STOCK' THEN 'REDUCE STOCK — capital freed'
               WHEN 'REORDER NOW'  THEN 'REORDER NOW — sales protected'
               WHEN 'HOLD'         THEN 'HOLD — no action (capital correctly deployed)'
           END AS opportunity,
           sku_count, opportunity_brl, deployed_capital_brl
      FROM per_verdict
),
rows_all AS (
    SELECT sort_order,
           opportunity,
           sku_count::text AS sku_count,
           opportunity_brl,
           deployed_capital_brl
      FROM labeled
    UNION ALL
    SELECT 5,
           'TOTAL — opportunity (actionable only) | capital (all SKUs)',
           (sum(CASE WHEN sort_order <= 3 THEN sku_count ELSE 0::bigint END)::text
             || ' | ' || sum(sku_count)::text),
           sum(CASE WHEN sort_order <= 3 THEN opportunity_brl ELSE 0::numeric END),
           sum(deployed_capital_brl)
      FROM labeled
)
SELECT opportunity,
       sku_count,
       ('$' || to_char(opportunity_brl,      'FM999,999,990.00')) AS opportunity_brl,
       ('$' || to_char(deployed_capital_brl, 'FM999,999,990.00')) AS deployed_capital_brl
  FROM rows_all
 ORDER BY sort_order;


-- -----------------------------------------------------------------------------
-- Business-impact by category
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_inventory_business_impact_by_category AS
SELECT category,
       count(*)                                            AS total_skus,
       count(*) FILTER (WHERE verdict = 'REORDER NOW')     AS reorder_skus,
       count(*) FILTER (WHERE verdict = 'HOLD')            AS hold_skus,
       count(*) FILTER (WHERE verdict = 'REDUCE STOCK')    AS reduce_skus,
       count(*) FILTER (WHERE verdict = 'DISCONTINUE')     AS discontinue_skus,
       round(sum(CASE WHEN verdict = 'DISCONTINUE'  THEN GREATEST(-net_profit, 0::numeric) ELSE 0::numeric END), 2) AS losses_eliminated_brl,
       round(sum(CASE WHEN verdict = 'REDUCE STOCK' THEN excess_units * unit_cogs         ELSE 0::numeric END), 2) AS capital_freed_brl,
       round(sum(CASE WHEN verdict = 'REORDER NOW'  THEN at_risk_units * unit_price       ELSE 0::numeric END), 2) AS sales_protected_brl,
       round(sum(CASE WHEN verdict = 'DISCONTINUE'  THEN GREATEST(-net_profit, 0::numeric) ELSE 0::numeric END)
           + sum(CASE WHEN verdict = 'REDUCE STOCK' THEN excess_units * unit_cogs         ELSE 0::numeric END)
           + sum(CASE WHEN verdict = 'REORDER NOW'  THEN at_risk_units * unit_price       ELSE 0::numeric END), 2) AS total_opportunity_brl
  FROM public.vw_inventory_decision_engine
 GROUP BY category
 ORDER BY total_opportunity_brl DESC;
