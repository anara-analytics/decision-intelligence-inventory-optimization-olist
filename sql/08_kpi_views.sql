-- =============================================================================
-- 08_kpi_views.sql
-- Decision Intelligence System — Executive KPI and top-list views
-- -----------------------------------------------------------------------------
-- Purpose : Executive-facing summary views: portfolio-level KPIs, monthly
--           revenue trend, top-selling SKUs, worst-rated categories, and the
--           inventory-engine executive scorecard.
-- Run order: 8th. Requires 04 (SKU features) + 07 (inventory engine).
-- =============================================================================

SET client_min_messages = warning;

DROP VIEW IF EXISTS public.vw_worst_rated_products     CASCADE;
DROP VIEW IF EXISTS public.vw_top_products             CASCADE;
DROP VIEW IF EXISTS public.vw_top_400_skus             CASCADE;
DROP VIEW IF EXISTS public.vw_monthly_revenue_trend    CASCADE;
DROP VIEW IF EXISTS public.vw_inventory_executive_kpis CASCADE;
DROP VIEW IF EXISTS public.vw_executive_kpis           CASCADE;


-- -----------------------------------------------------------------------------
-- Portfolio-level KPIs — one-row snapshot for the top of a dashboard
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_executive_kpis AS
SELECT
    (SELECT count(DISTINCT product_id)          FROM public.vw_sku_profitability) AS total_skus_analyzed,
    (SELECT round(sum(gross_revenue), 2)        FROM public.vw_sku_profitability) AS total_gross_revenue,
    (SELECT round(sum(net_profit), 2)           FROM public.vw_sku_profitability) AS total_net_profit,
    (SELECT round(avg(profit_margin_pct), 2)    FROM public.vw_sku_profitability) AS avg_profit_margin_pct,
    (SELECT round(avg(avg_review_score), 2)     FROM public.vw_sku_profitability) AS avg_customer_review,
    (SELECT count(*) FROM public.vw_sku_classification WHERE decision = 'SCALE')    AS scale_skus,
    (SELECT count(*) FROM public.vw_sku_classification WHERE decision = 'OPTIMIZE') AS optimize_skus,
    (SELECT count(*) FROM public.vw_sku_classification WHERE decision = 'EXIT')     AS exit_skus;


-- -----------------------------------------------------------------------------
-- Inventory-engine executive scorecard — long-form (metric, value, display)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_inventory_executive_kpis AS
WITH k AS (
    SELECT count(*)                                                    AS skus,
           count(*) FILTER (WHERE verdict <> 'HOLD')                   AS actionable,
           count(*) FILTER (WHERE verdict = 'REORDER NOW')             AS reorder_now,
           count(*) FILTER (WHERE verdict = 'HOLD')                    AS hold,
           count(*) FILTER (WHERE verdict = 'REDUCE STOCK')            AS reduce_stock,
           count(*) FILTER (WHERE verdict = 'DISCONTINUE')             AS discontinue,
           COALESCE(sum(CASE WHEN verdict = 'DISCONTINUE'  THEN GREATEST(-net_profit, 0::numeric) END), 0::numeric) AS losses,
           COALESCE(sum(CASE WHEN verdict = 'REDUCE STOCK' THEN excess_units * unit_cogs END), 0::numeric)          AS freed,
           COALESCE(sum(CASE WHEN verdict = 'REORDER NOW'  THEN at_risk_units * unit_price END), 0::numeric)        AS protected_,
           (percentile_cont(0.5) WITHIN GROUP (ORDER BY mape_pct::double precision))::numeric AS mape_sku_median
      FROM public.vw_inventory_decision_engine
),
catmape AS (
    SELECT (percentile_cont(0.5) WITHIN GROUP (ORDER BY c.m::double precision))::numeric AS mape_cat_median
      FROM (SELECT category, avg(mape_pct) AS m
              FROM public.forecast_results
             WHERE grain = 'category'
             GROUP BY category) c
),
metrics AS (
    SELECT 1 AS sort_order, 'SKUs in decision engine'::text AS metric, skus::numeric AS value, skus::text AS value_display FROM k
    UNION ALL SELECT 2, 'Actionable SKUs',      actionable::numeric,                actionable::text FROM k
    UNION ALL SELECT 3, 'Actionable share',
                 round(actionable::numeric * 100.0 / NULLIF(skus, 0)::numeric, 1),
                 to_char(round(actionable::numeric * 100.0 / NULLIF(skus, 0)::numeric, 1), 'FM9990.0') || '%' FROM k
    UNION ALL SELECT 4, 'REORDER NOW (SKUs)',   reorder_now::numeric,               reorder_now::text FROM k
    UNION ALL SELECT 5, 'HOLD (SKUs)',          hold::numeric,                       hold::text FROM k
    UNION ALL SELECT 6, 'REDUCE STOCK (SKUs)',  reduce_stock::numeric,               reduce_stock::text FROM k
    UNION ALL SELECT 7, 'DISCONTINUE (SKUs)',   discontinue::numeric,                discontinue::text FROM k
    UNION ALL SELECT 8, 'Losses eliminated',
                 round(losses, 2),
                 '$' || to_char(round(losses, 2), 'FM999,999,990.00') FROM k
    UNION ALL SELECT 9, 'Capital freed',
                 round(freed, 2),
                 '$' || to_char(round(freed, 2), 'FM999,999,990.00') FROM k
    UNION ALL SELECT 10, 'Sales protected',
                 round(protected_, 2),
                 '$' || to_char(round(protected_, 2), 'FM999,999,990.00') FROM k
    UNION ALL SELECT 11, 'Total opportunity',
                 round(losses + freed + protected_, 2),
                 '$' || to_char(round(losses + freed + protected_, 2), 'FM999,999,990.00') FROM k
    UNION ALL SELECT 12, 'Median forecast MAPE — category',
                 round(catmape.mape_cat_median, 1),
                 to_char(round(catmape.mape_cat_median, 1), 'FM9990.0') || '%' FROM catmape
    UNION ALL SELECT 13, 'Median forecast MAPE — SKU',
                 round(k.mape_sku_median, 1),
                 to_char(round(k.mape_sku_median, 1), 'FM9990.0') || '%' FROM k
)
SELECT metric, value, value_display FROM metrics ORDER BY sort_order;


-- -----------------------------------------------------------------------------
-- Monthly revenue trend
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_monthly_revenue_trend AS
SELECT substr(o.order_purchase_timestamp, 1, 7) AS order_month,
       count(DISTINCT oi.order_id)              AS order_count,
       count(oi.order_item_id)                  AS units_sold,
       round(sum(oi.price)::numeric, 2)         AS gross_revenue,
       round(sum(oi.freight_value)::numeric, 2) AS freight_collected,
       round(avg(oi.price)::numeric, 2)         AS avg_order_value
  FROM public.order_items oi
  JOIN public.orders o ON oi.order_id = o.order_id
 WHERE o.order_status NOT IN ('canceled','unavailable')
   AND o.order_purchase_timestamp IS NOT NULL
 GROUP BY substr(o.order_purchase_timestamp, 1, 7)
 ORDER BY order_month NULLS FIRST;


-- -----------------------------------------------------------------------------
-- Top 400 SKUs by gross revenue rank (with strategic classification)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_top_400_skus AS
SELECT product_id,
       category,
       gross_revenue,
       total_cost,
       net_profit,
       profit_margin_pct,
       avg_review_score,
       sku_rank,
       decision
  FROM public.vw_sku_classification
 WHERE sku_rank <= 400;


-- -----------------------------------------------------------------------------
-- Top products by revenue (no cancel/status filter — raw popularity view)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_top_products AS
SELECT p.product_id,
       p.product_category_name,
       count(*)                          AS total_items_sold,
       round(sum(oi.price)::numeric, 2)  AS revenue
  FROM public.order_items oi
  JOIN public.products    p ON oi.product_id = p.product_id
 GROUP BY p.product_id, p.product_category_name
 ORDER BY revenue DESC;


-- -----------------------------------------------------------------------------
-- Worst-rated 5 categories by avg review score
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_worst_rated_products AS
SELECT p.product_category_name,
       round(avg(r.review_score), 2)  AS avg_rating,
       count(r.review_id)             AS total_reviews
  FROM public.products      p
  JOIN public.order_items   oi ON p.product_id = oi.product_id
  JOIN public.orders        o  ON oi.order_id  = o.order_id
  JOIN public.order_reviews r  ON o.order_id   = r.order_id
 GROUP BY p.product_category_name
 ORDER BY avg_rating
 LIMIT 5;
