-- =============================================================================
-- 05_profitability_analysis.sql
-- Decision Intelligence System — Profit-focused analytical views
-- -----------------------------------------------------------------------------
-- Purpose : Layered views that answer "where is the money made/lost?".
--           None of these depend on forecast_results or the inventory engine;
--           they read only from the SKU-level features built in 04.
-- Run order: 5th. Requires 04_feature_engineering.sql.
--
-- Contents (dependency order preserved):
--   1. vw_business_impact                — SCALE / OPTIMIZE / EXIT dollar sizing
--   2. vw_profit_concentration           — Pareto ranking of profitable SKUs
--   3. vw_profit_leak_map                — top 50 loss-makers + dominant cost driver
--   4. vw_category_margin_changes        — first-half vs second-half margin drift
--   5. vw_sensitivity_freight_up_20pct   — stress test: freight cost +20%
--   6. vw_sensitivity_returns_up_50pct   — stress test: returns cost +50%
--   7. vw_sensitivity_storage_up_30pct   — stress test: storage cost +30%
--   8. vw_sensitivity_summary            — one-row-per-scenario roll-up
-- =============================================================================

SET client_min_messages = warning;

DROP VIEW IF EXISTS public.vw_sensitivity_summary        CASCADE;
DROP VIEW IF EXISTS public.vw_sensitivity_storage_up_30pct CASCADE;
DROP VIEW IF EXISTS public.vw_sensitivity_returns_up_50pct CASCADE;
DROP VIEW IF EXISTS public.vw_sensitivity_freight_up_20pct CASCADE;
DROP VIEW IF EXISTS public.vw_category_margin_changes    CASCADE;
DROP VIEW IF EXISTS public.vw_profit_leak_map            CASCADE;
DROP VIEW IF EXISTS public.vw_profit_concentration       CASCADE;
DROP VIEW IF EXISTS public.vw_business_impact            CASCADE;


-- -----------------------------------------------------------------------------
-- Business-impact sizing per strategic class
-- EXIT     -> recoup absolute losses on unprofitable SKUs
-- SCALE    -> assume 20% revenue lift @ current margin
-- OPTIMIZE -> assume 5% margin lift on current revenue
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_business_impact AS
SELECT 'EXIT SKUs — eliminating losses'::text AS opportunity,
       count(*)                                                  AS sku_count,
       round(sum(CASE WHEN net_profit < 0::numeric
                      THEN abs(net_profit) ELSE 0::numeric END), 2) AS potential_value_brl,
       round(sum(gross_revenue), 2)                              AS revenue_in_scope
  FROM public.vw_sku_classification
 WHERE decision = 'EXIT'
UNION ALL
SELECT 'SCALE SKUs — 20% revenue uplift opportunity',
       count(*),
       round((sum(gross_revenue) * 0.20 * avg(profit_margin_pct))
             / NULLIF(100.0::numeric, 0::numeric), 2),
       round(sum(gross_revenue), 2)
  FROM public.vw_sku_classification
 WHERE decision = 'SCALE'
UNION ALL
SELECT 'OPTIMIZE SKUs — 5pp margin improvement opportunity',
       count(*),
       round(sum(gross_revenue) * 0.05, 2),
       round(sum(gross_revenue), 2)
  FROM public.vw_sku_classification
 WHERE decision = 'OPTIMIZE';


-- -----------------------------------------------------------------------------
-- Pareto view of profit concentration (positive-profit SKUs only)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_profit_concentration AS
WITH ranked AS (
    SELECT product_id,
           category,
           net_profit,
           sum(net_profit) OVER (ORDER BY net_profit DESC) AS running_profit,
           sum(net_profit) OVER ()                          AS total_profit,
           row_number()    OVER (ORDER BY net_profit DESC) AS profit_rank,
           count(*)        OVER ()                          AS total_skus
      FROM public.vw_sku_profitability
     WHERE net_profit > 0::numeric
)
SELECT profit_rank,
       product_id,
       category,
       ('$' || to_char(round(net_profit, 2), 'FM999,999,990.00'))         AS net_profit,
       (to_char(round(100.0 * running_profit / NULLIF(total_profit, 0::numeric), 1),
                'FM990.0') || '%')                                        AS cumulative_profit_pct,
       (to_char(round(100.0 * profit_rank::numeric / NULLIF(total_skus, 0)::numeric, 1),
                'FM990.0') || '%')                                        AS cumulative_sku_pct
  FROM ranked
 ORDER BY profit_rank;


-- -----------------------------------------------------------------------------
-- Top 50 loss-making SKUs annotated with the dominant cost driver
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_profit_leak_map AS
SELECT p.product_id,
       p.category,
       ('$' || to_char(round(p.gross_revenue, 2), 'FM999,999,990.00')) AS gross_revenue,
       ('$' || to_char(round(p.net_profit, 2),   'FM999,999,990.00')) AS net_loss,
       ('$' || to_char(c.cogs_total,             'FM999,999,990.00')) AS cogs_total,
       ('$' || to_char(c.freight_cost_total,     'FM999,999,990.00')) AS freight_cost_total,
       ('$' || to_char(c.return_cost_total,      'FM999,999,990.00')) AS return_cost_total,
       ('$' || to_char(c.storage_cost_total,     'FM999,999,990.00')) AS storage_cost_total,
       ('$' || to_char(c.fulfillment_cost_total, 'FM999,999,990.00')) AS fulfillment_cost_total,
       CASE GREATEST(c.cogs_total, c.freight_cost_total, c.return_cost_total,
                     c.storage_cost_total, c.fulfillment_cost_total)
            WHEN c.cogs_total             THEN 'COGS'
            WHEN c.freight_cost_total     THEN 'Freight'
            WHEN c.return_cost_total      THEN 'Returns'
            WHEN c.storage_cost_total     THEN 'Storage'
            ELSE 'Fulfillment'
       END AS dominant_cost_driver
  FROM public.vw_sku_profitability p
  JOIN public.vw_sku_costs         c ON c.product_id = p.product_id
 WHERE p.net_profit < 0::numeric
 ORDER BY p.net_profit
 LIMIT 50;


-- -----------------------------------------------------------------------------
-- Category margin drift: split period at Feb-2018 (dataset midpoint)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_category_margin_changes AS
WITH period_bounds AS (
    SELECT min(substr(order_purchase_timestamp, 1, 7)) AS min_month,
           max(substr(order_purchase_timestamp, 1, 7)) AS max_month
      FROM public.orders
     WHERE order_status NOT IN ('canceled','unavailable')
       AND order_purchase_timestamp IS NOT NULL
),
category_monthly AS (
    SELECT ct.product_category_name_english        AS category,
           substr(o.order_purchase_timestamp, 1, 7) AS order_month,
           sum(oi.price)                            AS month_revenue,
           (sum(oi.price) * (1::double precision - sc.cogs_rate) - sum(oi.freight_value)) AS month_margin
      FROM public.order_items oi
      JOIN public.orders   o  ON oi.order_id   = o.order_id
      JOIN public.products p  ON oi.product_id = p.product_id
      JOIN public.category_translation ct
                            ON p.product_category_name = ct.product_category_name
      JOIN public.supplier_costs sc
                            ON sc.category = ct.product_category_name_english
     WHERE o.order_status NOT IN ('canceled','unavailable')
       AND o.order_purchase_timestamp IS NOT NULL
     GROUP BY ct.product_category_name_english,
              substr(o.order_purchase_timestamp, 1, 7),
              sc.cogs_rate
),
category_split AS (
    SELECT cm.category,
           CASE WHEN cm.order_month <= '2018-02' THEN 'first_half' ELSE 'second_half' END AS period,
           sum(cm.month_revenue) AS period_revenue,
           sum(cm.month_margin)  AS period_margin
      FROM category_monthly cm
     GROUP BY cm.category,
              CASE WHEN cm.order_month <= '2018-02' THEN 'first_half' ELSE 'second_half' END
)
SELECT first.category,
       round((first.period_margin  * 100.0::double precision
              / NULLIF(NULLIF(first.period_revenue, 0::double precision), 0::double precision))::numeric, 2)  AS margin_pct_first_half,
       round((second.period_margin * 100.0::double precision
              / NULLIF(NULLIF(second.period_revenue, 0::double precision), 0::double precision))::numeric, 2) AS margin_pct_second_half,
       round(((second.period_margin * 100.0::double precision
               / NULLIF(NULLIF(second.period_revenue, 0::double precision), 0::double precision))
             - (first.period_margin  * 100.0::double precision
               / NULLIF(NULLIF(first.period_revenue,  0::double precision), 0::double precision)))::numeric, 2) AS margin_change_pp,
       CASE
           WHEN ((second.period_margin * 100.0::double precision
                  / NULLIF(NULLIF(second.period_revenue, 0::double precision), 0::double precision))
               - (first.period_margin  * 100.0::double precision
                  / NULLIF(NULLIF(first.period_revenue,  0::double precision), 0::double precision))) > 2::double precision THEN 'IMPROVING'
           WHEN ((second.period_margin * 100.0::double precision
                  / NULLIF(NULLIF(second.period_revenue, 0::double precision), 0::double precision))
               - (first.period_margin  * 100.0::double precision
                  / NULLIF(NULLIF(first.period_revenue,  0::double precision), 0::double precision))) < (-2)::double precision THEN 'DETERIORATING'
           ELSE 'STABLE'
       END AS trend_flag,
       round((first.period_revenue + second.period_revenue)::numeric, 2) AS total_revenue
  FROM category_split first
  JOIN category_split second ON first.category = second.category
 WHERE first.period = 'first_half' AND second.period = 'second_half'
 ORDER BY margin_change_pp NULLS FIRST;


-- -----------------------------------------------------------------------------
-- Sensitivity: freight +20%
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sensitivity_freight_up_20pct AS
SELECT r.product_id,
       c.category,
       round(r.gross_revenue::numeric, 2) AS gross_revenue,
       round((c.cogs_total + c.storage_cost_total + c.fulfillment_cost_total
              + c.return_cost_total + c.freight_cost_total * 1.20), 2) AS stressed_total_cost,
       round((r.gross_revenue
              - (c.cogs_total + c.storage_cost_total + c.fulfillment_cost_total
                 + c.return_cost_total + c.freight_cost_total * 1.20)::double precision)::numeric, 2) AS stressed_net_profit,
       round(((r.gross_revenue
               - (c.cogs_total + c.storage_cost_total + c.fulfillment_cost_total
                  + c.return_cost_total + c.freight_cost_total * 1.20)::double precision)
             * 100.0::double precision
             / NULLIF(NULLIF(r.gross_revenue, 0::double precision), 0::double precision))::numeric, 2) AS stressed_margin_pct
  FROM public.vw_sku_revenue r
  JOIN public.vw_sku_costs   c ON r.product_id = c.product_id;


-- -----------------------------------------------------------------------------
-- Sensitivity: returns +50%
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sensitivity_returns_up_50pct AS
SELECT r.product_id,
       c.category,
       round(r.gross_revenue::numeric, 2) AS gross_revenue,
       round((r.gross_revenue
              - (c.cogs_total + c.storage_cost_total + c.fulfillment_cost_total
                 + c.return_cost_total * 1.50 + c.freight_cost_total)::double precision)::numeric, 2) AS stressed_net_profit,
       round(((r.gross_revenue
               - (c.cogs_total + c.storage_cost_total + c.fulfillment_cost_total
                  + c.return_cost_total * 1.50 + c.freight_cost_total)::double precision)
             * 100.0::double precision
             / NULLIF(NULLIF(r.gross_revenue, 0::double precision), 0::double precision))::numeric, 2) AS stressed_margin_pct
  FROM public.vw_sku_revenue r
  JOIN public.vw_sku_costs   c ON r.product_id = c.product_id;


-- -----------------------------------------------------------------------------
-- Sensitivity: storage +30%
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sensitivity_storage_up_30pct AS
SELECT r.product_id,
       c.category,
       round(r.gross_revenue::numeric, 2) AS gross_revenue,
       round((r.gross_revenue
              - (c.cogs_total + c.storage_cost_total * 1.30 + c.fulfillment_cost_total
                 + c.return_cost_total + c.freight_cost_total)::double precision)::numeric, 2) AS stressed_net_profit,
       round(((r.gross_revenue
               - (c.cogs_total + c.storage_cost_total * 1.30 + c.fulfillment_cost_total
                  + c.return_cost_total + c.freight_cost_total)::double precision)
             * 100.0::double precision
             / NULLIF(NULLIF(r.gross_revenue, 0::double precision), 0::double precision))::numeric, 2) AS stressed_margin_pct
  FROM public.vw_sku_revenue r
  JOIN public.vw_sku_costs   c ON r.product_id = c.product_id;


-- -----------------------------------------------------------------------------
-- Sensitivity summary: one row per scenario
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sensitivity_summary AS
SELECT 'Baseline'::text                                            AS scenario,
       round(avg(profit_margin_pct), 2)                            AS avg_margin_pct,
       round(sum(net_profit), 2)                                   AS total_net_profit
  FROM public.vw_sku_profitability
UNION ALL
SELECT 'Freight +20%',
       round(avg(stressed_margin_pct), 2),
       round(sum(stressed_net_profit), 2)
  FROM public.vw_sensitivity_freight_up_20pct
UNION ALL
SELECT 'Returns +50%',
       round(avg(stressed_margin_pct), 2),
       round(sum(stressed_net_profit), 2)
  FROM public.vw_sensitivity_returns_up_50pct
UNION ALL
SELECT 'Storage +30%',
       round(avg(stressed_margin_pct), 2),
       round(sum(stressed_net_profit), 2)
  FROM public.vw_sensitivity_storage_up_30pct;
