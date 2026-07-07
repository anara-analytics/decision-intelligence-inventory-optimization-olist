-- =============================================================================
-- 03_data_cleaning.sql
-- Decision Intelligence System — Post-load cleaning & referential integrity
-- -----------------------------------------------------------------------------
-- Purpose : Apply non-destructive fixes to the loaded raw data, add foreign
--           keys (deferred to after bulk load), and run data-quality asserts.
-- Run order: 3rd. Requires 02_data_import.sql to have populated all tables.
--
-- Cleaning pattern chosen: IN-PLACE, non-destructive.
--   Rationale: the 40+ downstream views already read directly from raw tables
--   and use substr() on text timestamps. Building a parallel stg_* layer would
--   force a rewrite of every view. Instead we:
--     * rename obvious column typos (safe — no view references them)
--     * normalize whitespace/case on join keys
--     * convert empty-string timestamps to NULL (safety net for CSV imports)
--     * flag out-of-range numerics by NULLing clearly invalid values
--     * add FK constraints AFTER data is normalized
--     * assert row counts + integrity at the end (raise if anything is off)
--
-- Nothing here deletes rows. Timestamps stay as text — every downstream view
-- casts with ::date / ::timestamp explicitly or uses substr() for year_month.
-- =============================================================================

SET client_min_messages = warning;

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Fix column-name typos in products
--    Verified: no existing view references product_name_lenght or
--    product_description_lenght, so this rename is safe.
-- -----------------------------------------------------------------------------

ALTER TABLE public.products
    RENAME COLUMN product_name_lenght        TO product_name_length;
ALTER TABLE public.products
    RENAME COLUMN product_description_lenght TO product_description_length;


-- -----------------------------------------------------------------------------
-- 2. Normalize join keys (whitespace + case)
--    Category names should be lowercase snake_case; enforce that so joins to
--    supplier_costs / storage_costs / fulfillment_costs / return_costs never
--    miss on casing drift.
-- -----------------------------------------------------------------------------

UPDATE public.category_translation
   SET product_category_name         = lower(trim(product_category_name)),
       product_category_name_english = lower(trim(product_category_name_english))
 WHERE product_category_name         <> lower(trim(product_category_name))
    OR product_category_name_english <> lower(trim(product_category_name_english));

UPDATE public.supplier_costs    SET category = lower(trim(category)) WHERE category <> lower(trim(category));
UPDATE public.storage_costs     SET category = lower(trim(category)) WHERE category <> lower(trim(category));
UPDATE public.fulfillment_costs SET category = lower(trim(category)) WHERE category <> lower(trim(category));
UPDATE public.return_costs      SET category = lower(trim(category)) WHERE category <> lower(trim(category));

UPDATE public.products
   SET product_category_name = lower(trim(product_category_name))
 WHERE product_category_name IS NOT NULL
   AND product_category_name <> lower(trim(product_category_name));

UPDATE public.orders
   SET order_status = lower(trim(order_status))
 WHERE order_status IS NOT NULL
   AND order_status <> lower(trim(order_status));


-- -----------------------------------------------------------------------------
-- 3. Convert empty-string timestamps to NULL
--    CSV loaders sometimes turn missing dates into '' rather than \N. Fix that
--    so downstream ::date / ::timestamp casts don't blow up.
-- -----------------------------------------------------------------------------

UPDATE public.orders SET order_purchase_timestamp      = NULL WHERE order_purchase_timestamp      = '';
UPDATE public.orders SET order_approved_at             = NULL WHERE order_approved_at             = '';
UPDATE public.orders SET order_delivered_carrier_date  = NULL WHERE order_delivered_carrier_date  = '';
UPDATE public.orders SET order_delivered_customer_date = NULL WHERE order_delivered_customer_date = '';
UPDATE public.orders SET order_estimated_delivery_date = NULL WHERE order_estimated_delivery_date = '';

UPDATE public.order_items   SET shipping_limit_date     = NULL WHERE shipping_limit_date     = '';
UPDATE public.order_reviews SET review_creation_date    = NULL WHERE review_creation_date    = '';
UPDATE public.order_reviews SET review_answer_timestamp = NULL WHERE review_answer_timestamp = '';


-- -----------------------------------------------------------------------------
-- 4. Numeric sanity — NULL out clearly invalid values
--    Zero/negative physical dimensions are impossible; negative prices/freight
--    are data-entry errors. NULLing (not deleting) preserves the row for other
--    analyses while dropping the bad measurement from aggregates.
-- -----------------------------------------------------------------------------

UPDATE public.products SET product_weight_g   = NULL WHERE product_weight_g   IS NOT NULL AND product_weight_g   <= 0;
UPDATE public.products SET product_length_cm  = NULL WHERE product_length_cm  IS NOT NULL AND product_length_cm  <= 0;
UPDATE public.products SET product_height_cm  = NULL WHERE product_height_cm  IS NOT NULL AND product_height_cm  <= 0;
UPDATE public.products SET product_width_cm   = NULL WHERE product_width_cm   IS NOT NULL AND product_width_cm   <= 0;
UPDATE public.products SET product_photos_qty = NULL WHERE product_photos_qty IS NOT NULL AND product_photos_qty <  0;

UPDATE public.order_items SET price         = NULL WHERE price         IS NOT NULL AND price         < 0;
UPDATE public.order_items SET freight_value = NULL WHERE freight_value IS NOT NULL AND freight_value < 0;


-- -----------------------------------------------------------------------------
-- 5. Foreign keys — added after cleaning so all references resolve
--    Deferred here (rather than in 01) to keep the COPY loads in 02 unblocked.
-- -----------------------------------------------------------------------------

ALTER TABLE public.products
    ADD CONSTRAINT fk_p_category  FOREIGN KEY (product_category_name)
    REFERENCES public.category_translation(product_category_name);

ALTER TABLE public.supplier_costs
    ADD CONSTRAINT fk_sc_category FOREIGN KEY (category)
    REFERENCES public.category_translation(product_category_name_english);

ALTER TABLE public.storage_costs
    ADD CONSTRAINT fk_st_category FOREIGN KEY (category)
    REFERENCES public.category_translation(product_category_name_english);

ALTER TABLE public.fulfillment_costs
    ADD CONSTRAINT fk_fc_category FOREIGN KEY (category)
    REFERENCES public.category_translation(product_category_name_english);

ALTER TABLE public.return_costs
    ADD CONSTRAINT fk_rc_category FOREIGN KEY (category)
    REFERENCES public.category_translation(product_category_name_english);

COMMIT;


-- -----------------------------------------------------------------------------
-- 6. Data-quality asserts (informational — will RAISE if anything is off)
--    Uses anonymous PL/pgSQL block so failures interrupt the script.
-- -----------------------------------------------------------------------------

DO $$
DECLARE
    v_orphan_items          bigint;
    v_orphan_reviews        bigint;
    v_null_ts_orders        bigint;
    v_null_category         bigint;
    v_bad_status            bigint;
    v_cost_coverage_missing bigint;
BEGIN
    -- 6a. order_items pointing to products that don't exist
    SELECT count(*) INTO v_orphan_items
    FROM public.order_items oi
    LEFT JOIN public.products p ON p.product_id = oi.product_id
    WHERE p.product_id IS NULL;

    -- 6b. order_reviews pointing to orders that don't exist
    SELECT count(*) INTO v_orphan_reviews
    FROM public.order_reviews r
    LEFT JOIN public.orders o ON o.order_id = r.order_id
    WHERE o.order_id IS NULL;

    -- 6c. Orders with no purchase timestamp (silently dropped by dim_date etc.)
    SELECT count(*) INTO v_null_ts_orders
    FROM public.orders
    WHERE order_purchase_timestamp IS NULL;

    -- 6d. Products with NULL category (excluded from category-joined views)
    SELECT count(*) INTO v_null_category
    FROM public.products
    WHERE product_category_name IS NULL;

    -- 6e. Order statuses outside the expected vocabulary
    SELECT count(*) INTO v_bad_status
    FROM public.orders
    WHERE order_status IS NOT NULL
      AND order_status NOT IN (
        'delivered','shipped','canceled','unavailable',
        'invoiced','processing','approved','created'
      );

    -- 6f. Categories present in category_translation but missing a cost row
    SELECT count(*) INTO v_cost_coverage_missing
    FROM public.category_translation ct
    LEFT JOIN public.supplier_costs    sc ON sc.category = ct.product_category_name_english
    LEFT JOIN public.storage_costs     st ON st.category = ct.product_category_name_english
    LEFT JOIN public.fulfillment_costs fc ON fc.category = ct.product_category_name_english
    LEFT JOIN public.return_costs      rc ON rc.category = ct.product_category_name_english
    WHERE ct.product_category_name_english IS NOT NULL
      AND (sc.category IS NULL OR st.category IS NULL OR fc.category IS NULL OR rc.category IS NULL);

    RAISE NOTICE '--- Data-quality report ---';
    RAISE NOTICE 'Orphan order_items (product missing)     : %', v_orphan_items;
    RAISE NOTICE 'Orphan order_reviews (order missing)     : %', v_orphan_reviews;
    RAISE NOTICE 'Orders with NULL purchase timestamp      : %', v_null_ts_orders;
    RAISE NOTICE 'Products with NULL category              : %', v_null_category;
    RAISE NOTICE 'Orders with unexpected status            : %', v_bad_status;
    RAISE NOTICE 'Categories missing full cost-model rows  : %', v_cost_coverage_missing;

    -- Hard-fail on issues that would break downstream cost views.
    IF v_cost_coverage_missing > 0 THEN
        RAISE EXCEPTION
            'Cost-model incomplete: % category/cost rows missing. '
            'vw_sku_costs and dim_category require full coverage across '
            'supplier_costs, storage_costs, fulfillment_costs, return_costs.',
            v_cost_coverage_missing;
    END IF;
END $$;
