-- =============================================================================
-- 04_feature_engineering.sql
-- Decision Intelligence System — Dimensions, facts, SKU-level features
-- -----------------------------------------------------------------------------
-- Purpose : Build the reusable analytical layer on top of the cleaned raw
--           tables. Everything downstream (profitability, forecasting,
--           inventory, KPIs, validation) reads from these views.
-- Run order: 4th. Requires 03_data_cleaning.sql to have completed.
--
-- Layout (dependency order enforced within the file):
--   1. Dimensions     : dim_category, dim_date, dim_product
--   2. Fact           : fact_order_items
--   3. SKU rollups    : vw_sku_revenue, vw_sku_costs, vw_sku_review_scores
--   4. SKU derived    : vw_sku_profitability, vw_sku_classification
--   5. Monthly grain  : vw_monthly_sku_performance
-- =============================================================================

SET client_min_messages = warning;

-- Drop in reverse dependency order so re-runs succeed.
DROP VIEW IF EXISTS public.vw_monthly_sku_performance CASCADE;
DROP VIEW IF EXISTS public.vw_sku_classification      CASCADE;
DROP VIEW IF EXISTS public.vw_sku_profitability       CASCADE;
DROP VIEW IF EXISTS public.vw_sku_review_scores       CASCADE;
DROP VIEW IF EXISTS public.vw_sku_costs               CASCADE;
DROP VIEW IF EXISTS public.vw_sku_revenue             CASCADE;
DROP VIEW IF EXISTS public.fact_order_items           CASCADE;
DROP VIEW IF EXISTS public.dim_product                CASCADE;
DROP VIEW IF EXISTS public.dim_date                   CASCADE;
DROP VIEW IF EXISTS public.dim_category               CASCADE;


-- -----------------------------------------------------------------------------
-- Dimension: category (one row per English category with full cost model)
-- -----------------------------------------------------------------------------
CREATE VIEW public.dim_category AS
SELECT ct.product_category_name_english AS category,
       sc.cogs_rate,
       st.storage_cost_per_unit,
       fc.fulfillment_cost_per_order,
       rc.return_rate,
       rc.return_cost_per_unit
  FROM public.category_translation ct
  JOIN public.supplier_costs    sc ON sc.category = ct.product_category_name_english
  JOIN public.storage_costs     st ON st.category = ct.product_category_name_english
  JOIN public.fulfillment_costs fc ON fc.category = ct.product_category_name_english
  JOIN public.return_costs      rc ON rc.category = ct.product_category_name_english;


-- -----------------------------------------------------------------------------
-- Dimension: date (distinct order_dates with year, year_month, month, dow)
-- -----------------------------------------------------------------------------
CREATE VIEW public.dim_date AS
SELECT DISTINCT
       (order_purchase_timestamp)::date                                       AS order_date,
       substr(order_purchase_timestamp, 1, 4)                                 AS year,
       substr(order_purchase_timestamp, 1, 7)                                 AS year_month,
       substr(order_purchase_timestamp, 6, 2)                                 AS month,
       (EXTRACT(dow FROM (order_purchase_timestamp)::timestamp))::integer     AS day_of_week
  FROM public.orders
 WHERE order_purchase_timestamp IS NOT NULL;


-- -----------------------------------------------------------------------------
-- Dimension: product (product with PT + EN category name)
-- -----------------------------------------------------------------------------
CREATE VIEW public.dim_product AS
SELECT p.product_id,
       p.product_category_name                 AS category_pt,
       ct.product_category_name_english        AS category_en,
       p.product_weight_g,
       p.product_length_cm,
       p.product_height_cm,
       p.product_width_cm
  FROM public.products p
  LEFT JOIN public.category_translation ct
         ON p.product_category_name = ct.product_category_name;


-- -----------------------------------------------------------------------------
-- Fact: order_items — canceled/unavailable orders filtered out at source so
-- every downstream aggregate is over the valid revenue-generating population.
-- -----------------------------------------------------------------------------
CREATE VIEW public.fact_order_items AS
SELECT oi.order_id,
       oi.order_item_id,
       oi.product_id,
       (o.order_purchase_timestamp)::date AS order_date,
       o.order_status,
       oi.price,
       oi.freight_value,
       r.review_score
  FROM public.order_items   oi
  JOIN public.orders        o ON oi.order_id = o.order_id
  LEFT JOIN public.order_reviews r ON oi.order_id = r.order_id
 WHERE o.order_status NOT IN ('canceled','unavailable');


-- -----------------------------------------------------------------------------
-- SKU rollup: revenue
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_revenue AS
SELECT oi.product_id,
       count(oi.order_item_id)          AS units_sold,
       sum(oi.price)                    AS gross_revenue,
       sum(oi.freight_value)            AS freight_collected,
       count(DISTINCT oi.order_id)      AS order_count
  FROM public.order_items oi
  JOIN public.orders o ON oi.order_id = o.order_id
 WHERE o.order_status NOT IN ('canceled','unavailable')
 GROUP BY oi.product_id;


-- -----------------------------------------------------------------------------
-- SKU rollup: costs (COGS, storage, fulfillment, returns, freight)
-- Applies the category-level cost model to each SKU's units/orders/revenue.
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_costs AS
WITH sku_base AS (
    SELECT oi.product_id,
           ct.product_category_name_english AS category,
           count(oi.order_item_id)          AS units_sold,
           count(DISTINCT oi.order_id)      AS order_count,
           sum(oi.price)                    AS gross_revenue,
           sum(oi.freight_value)            AS freight_cost_total
      FROM public.order_items oi
      JOIN public.orders   o  ON oi.order_id   = o.order_id
      JOIN public.products p  ON oi.product_id = p.product_id
      JOIN public.category_translation ct
                            ON p.product_category_name = ct.product_category_name
     WHERE o.order_status NOT IN ('canceled','unavailable')
     GROUP BY oi.product_id, ct.product_category_name_english
)
SELECT b.product_id,
       b.category,
       round((b.gross_revenue * sc.cogs_rate)::numeric, 2)                                       AS cogs_total,
       round((b.units_sold::double precision * st.storage_cost_per_unit)::numeric, 2)            AS storage_cost_total,
       round((b.order_count::double precision * fc.fulfillment_cost_per_order)::numeric, 2)      AS fulfillment_cost_total,
       round((b.units_sold::double precision * rc.return_rate * rc.return_cost_per_unit)::numeric, 2) AS return_cost_total,
       round(b.freight_cost_total::numeric, 2)                                                   AS freight_cost_total
  FROM sku_base b
  JOIN public.supplier_costs    sc ON sc.category = b.category
  JOIN public.storage_costs     st ON st.category = b.category
  JOIN public.fulfillment_costs fc ON fc.category = b.category
  JOIN public.return_costs      rc ON rc.category = b.category;


-- -----------------------------------------------------------------------------
-- SKU rollup: review scores (avg + count of negative reviews at <=2 stars)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_review_scores AS
SELECT oi.product_id,
       round(avg(r.review_score), 2)                                          AS avg_review_score,
       sum(CASE WHEN r.review_score <= 2 THEN 1 ELSE 0 END)                   AS negative_review_count
  FROM public.order_items   oi
  JOIN public.orders        o ON oi.order_id = o.order_id
  JOIN public.order_reviews r ON oi.order_id = r.order_id
 WHERE o.order_status NOT IN ('canceled','unavailable')
 GROUP BY oi.product_id;


-- -----------------------------------------------------------------------------
-- SKU derived: profitability (revenue - all costs, margin %, rank)
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_profitability AS
SELECT r.product_id,
       c.category,
       round(r.gross_revenue::numeric, 2) AS gross_revenue,
       round((c.cogs_total + c.storage_cost_total + c.fulfillment_cost_total
              + c.return_cost_total + c.freight_cost_total), 2) AS total_cost,
       round((r.gross_revenue
              - (c.cogs_total + c.storage_cost_total + c.fulfillment_cost_total
                 + c.return_cost_total + c.freight_cost_total)::double precision)::numeric, 2) AS net_profit,
       round(((r.gross_revenue
               - (c.cogs_total + c.storage_cost_total + c.fulfillment_cost_total
                  + c.return_cost_total + c.freight_cost_total)::double precision)
              * 100.0::double precision
              / NULLIF(r.gross_revenue, 0::double precision))::numeric, 2)     AS profit_margin_pct,
       rs.avg_review_score,
       row_number() OVER (ORDER BY r.gross_revenue DESC NULLS LAST)            AS sku_rank
  FROM public.vw_sku_revenue r
  JOIN public.vw_sku_costs   c  ON r.product_id = c.product_id
  LEFT JOIN public.vw_sku_review_scores rs ON r.product_id = rs.product_id;


-- -----------------------------------------------------------------------------
-- SKU derived: strategic classification (SCALE / OPTIMIZE / EXIT)
--   EXIT     -> margin < 10% OR review < 3.0
--   SCALE    -> margin >= 25% AND review >= 4.0
--   OPTIMIZE -> everything in between
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_sku_classification AS
SELECT product_id,
       category,
       gross_revenue,
       total_cost,
       net_profit,
       profit_margin_pct,
       avg_review_score,
       sku_rank,
       CASE
           WHEN profit_margin_pct < 10::numeric OR avg_review_score < 3.0 THEN 'EXIT'
           WHEN profit_margin_pct >= 25::numeric AND avg_review_score >= 4.0 THEN 'SCALE'
           ELSE 'OPTIMIZE'
       END AS decision
  FROM public.vw_sku_profitability;


-- -----------------------------------------------------------------------------
-- Monthly grain: SKU performance per year-month (units, revenue, avg review)
-- Consumed by category-level demand and margin views downstream.
-- -----------------------------------------------------------------------------
CREATE VIEW public.vw_monthly_sku_performance AS
SELECT oi.product_id,
       ct.product_category_name_english        AS category,
       substr(o.order_purchase_timestamp, 1, 7) AS order_month,
       count(oi.order_item_id)                  AS units_sold,
       round(sum(oi.price)::numeric, 2)         AS revenue,
       round(avg(r.review_score), 2)            AS avg_review_score
  FROM public.order_items oi
  JOIN public.orders   o  ON oi.order_id   = o.order_id
  JOIN public.products p  ON oi.product_id = p.product_id
  JOIN public.category_translation ct
                        ON p.product_category_name = ct.product_category_name
  LEFT JOIN public.order_reviews r ON oi.order_id = r.order_id
 WHERE o.order_status NOT IN ('canceled','unavailable')
   AND o.order_purchase_timestamp IS NOT NULL
 GROUP BY oi.product_id,
          ct.product_category_name_english,
          substr(o.order_purchase_timestamp, 1, 7)
 ORDER BY substr(o.order_purchase_timestamp, 1, 7) NULLS FIRST;
