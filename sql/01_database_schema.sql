-- =============================================================================
-- 01_database_schema.sql
-- Decision Intelligence System — DDL only
-- -----------------------------------------------------------------------------
-- Purpose : Create all base tables and primary keys.
-- Run order: 1st (fresh DB). Foreign keys and cleaning happen in 03.
-- Notes   : Column names for products (product_name_lenght,
--           product_description_lenght) intentionally keep the source
--           misspelling here so that 02_data_import.sql (verbatim COPY dump)
--           loads without header mismatch. They get renamed in 03.
-- =============================================================================

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

-- Drop first for idempotent re-runs on a fresh DB. CASCADE removes dependent
-- views created in later scripts if this file is re-run mid-cycle.
DROP TABLE IF EXISTS public.forecast_results  CASCADE;
DROP TABLE IF EXISTS public.order_reviews     CASCADE;
DROP TABLE IF EXISTS public.order_items       CASCADE;
DROP TABLE IF EXISTS public.orders            CASCADE;
DROP TABLE IF EXISTS public.products          CASCADE;
DROP TABLE IF EXISTS public.return_costs      CASCADE;
DROP TABLE IF EXISTS public.storage_costs     CASCADE;
DROP TABLE IF EXISTS public.fulfillment_costs CASCADE;
DROP TABLE IF EXISTS public.supplier_costs    CASCADE;
DROP TABLE IF EXISTS public.category_translation CASCADE;


-- -----------------------------------------------------------------------------
-- Reference / lookup tables
-- -----------------------------------------------------------------------------

CREATE TABLE public.category_translation (
    product_category_name         text NOT NULL,
    product_category_name_english text
);

CREATE TABLE public.supplier_costs (
    category  text NOT NULL,
    cogs_rate real NOT NULL
);

CREATE TABLE public.storage_costs (
    category               text NOT NULL,
    storage_cost_per_unit  real NOT NULL
);

CREATE TABLE public.fulfillment_costs (
    category                     text NOT NULL,
    fulfillment_cost_per_order   real NOT NULL
);

CREATE TABLE public.return_costs (
    category              text NOT NULL,
    return_rate           real NOT NULL,
    return_cost_per_unit  real NOT NULL
);


-- -----------------------------------------------------------------------------
-- Raw transactional tables (Olist)
-- Timestamp columns kept as text to match source CSVs and downstream substr()
-- usage in view definitions. 03_data_cleaning normalizes empty strings to NULL.
-- -----------------------------------------------------------------------------

CREATE TABLE public.orders (
    order_id                        text NOT NULL,
    customer_id                     text,
    order_status                    text,
    order_purchase_timestamp        text,
    order_approved_at               text,
    order_delivered_carrier_date    text,
    order_delivered_customer_date   text,
    order_estimated_delivery_date   text
);

CREATE TABLE public.order_items (
    order_id             text    NOT NULL,
    order_item_id        integer NOT NULL,
    product_id           text,
    seller_id            text,
    shipping_limit_date  text,
    price                real,
    freight_value        real
);

CREATE TABLE public.products (
    product_id                  text NOT NULL,
    product_category_name       text,
    product_name_lenght         real,   -- misspelled; renamed in 03
    product_description_lenght  real,   -- misspelled; renamed in 03
    product_photos_qty          real,
    product_weight_g            real,
    product_length_cm           real,
    product_height_cm           real,
    product_width_cm            real
);

CREATE TABLE public.order_reviews (
    review_id                text NOT NULL,
    order_id                 text,
    review_score             integer,
    review_comment_title     text,
    review_comment_message   text,
    review_creation_date     text,
    review_answer_timestamp  text
);


-- -----------------------------------------------------------------------------
-- Forecast output table
-- Populated externally (Holt-Winters model in Python) and loaded via COPY in 02.
-- Stores both SKU-grain and category-grain forecasts side-by-side.
-- -----------------------------------------------------------------------------

CREATE TABLE public.forecast_results (
    grain           text          NOT NULL,        -- 'sku' | 'category'
    grain_key       text          NOT NULL,        -- product_id or category name
    category        text,
    forecast_month  date          NOT NULL,
    predicted_units numeric(12,2),
    lower_bound     numeric(12,2),
    upper_bound     numeric(12,2),
    mae             numeric(12,2),
    mape_pct        numeric(12,2),
    model_used      text,
    confidence      text                            -- 'high' | 'medium' | 'low'
);


-- -----------------------------------------------------------------------------
-- Primary keys
-- Applied here (not in 03) so the COPY loads in 02 fail loudly on duplicates.
-- -----------------------------------------------------------------------------

ALTER TABLE public.category_translation
    ADD CONSTRAINT pk_category_translation PRIMARY KEY (product_category_name);

ALTER TABLE public.category_translation
    ADD CONSTRAINT uq_category_en UNIQUE (product_category_name_english);

ALTER TABLE public.supplier_costs
    ADD CONSTRAINT pk_supplier_costs PRIMARY KEY (category);

ALTER TABLE public.storage_costs
    ADD CONSTRAINT pk_storage_costs PRIMARY KEY (category);

ALTER TABLE public.fulfillment_costs
    ADD CONSTRAINT pk_fulfillment_costs PRIMARY KEY (category);

ALTER TABLE public.return_costs
    ADD CONSTRAINT pk_return_costs PRIMARY KEY (category);

ALTER TABLE public.orders
    ADD CONSTRAINT pk_orders PRIMARY KEY (order_id);

ALTER TABLE public.order_items
    ADD CONSTRAINT pk_order_items PRIMARY KEY (order_id, order_item_id);

ALTER TABLE public.products
    ADD CONSTRAINT pk_products PRIMARY KEY (product_id);

ALTER TABLE public.order_reviews
    ADD CONSTRAINT pk_order_reviews PRIMARY KEY (review_id);

ALTER TABLE public.forecast_results
    ADD CONSTRAINT pk_forecast_results PRIMARY KEY (grain, grain_key, forecast_month);
