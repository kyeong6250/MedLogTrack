-- =============================================================================
-- Query 1: Low-stock alert
--
-- BUSINESS QUESTION
-- "Which items are below reorder point right now, at which facilities, and
--  how many days of supply do we actually have left based on how fast we're
--  really using it?" — the question a Medical Logistics NCOIC asks every
--  morning before the pick-and-pull shift.
--
-- APPROACH
-- For every (facility, item) pair currently holding stock, roll up
-- quantity_on_hand across lots and compute trailing 30/60/90-day average
-- daily usage from usage_transactions (issue + waste + transfer_out all
-- count as "demand" — the stock left the building either way). Days of
-- supply = on_hand / avg_daily_usage_30, which is the number that actually
-- answers "how many days until we run out at the current pace" (the 60/90
-- day averages are included alongside it so a reviewer can see whether
-- usage is accelerating or decelerating, not just the current snapshot).
-- =============================================================================

CREATE OR REPLACE VIEW vw_low_stock_alert AS
WITH on_hand AS (
    SELECT
        il.facility_id,
        il.item_id,
        SUM(il.quantity_on_hand) AS quantity_on_hand
    FROM inventory_lots il
    WHERE il.status <> 'returned'
    GROUP BY il.facility_id, il.item_id
),
usage_windows AS (
    SELECT
        ut.facility_id,
        ut.item_id,
        SUM(ut.quantity) FILTER (WHERE ut.transaction_date >= CURRENT_DATE - 30)
            / 30.0 AS avg_daily_usage_30,
        SUM(ut.quantity) FILTER (WHERE ut.transaction_date >= CURRENT_DATE - 60)
            / 60.0 AS avg_daily_usage_60,
        SUM(ut.quantity) FILTER (WHERE ut.transaction_date >= CURRENT_DATE - 90)
            / 90.0 AS avg_daily_usage_90
    FROM usage_transactions ut
    WHERE ut.transaction_type IN ('issue', 'waste', 'transfer_out')
      AND ut.transaction_date >= CURRENT_DATE - 90
    GROUP BY ut.facility_id, ut.item_id
)
SELECT
    f.facility_id,
    f.name AS facility_name,
    si.item_id,
    si.nsn_code,
    si.item_name,
    ic.category_name,
    COALESCE(oh.quantity_on_hand, 0) AS quantity_on_hand,
    si.reorder_point,
    si.safety_stock_level,
    ROUND(COALESCE(uw.avg_daily_usage_30, 0), 2) AS avg_daily_usage_30,
    ROUND(COALESCE(uw.avg_daily_usage_60, 0), 2) AS avg_daily_usage_60,
    ROUND(COALESCE(uw.avg_daily_usage_90, 0), 2) AS avg_daily_usage_90,
    -- NULL days-of-supply (rather than 0 or infinity) when there's no recent
    -- usage to divide by — "we don't know how long this lasts" is a more
    -- honest signal than a fabricated number for slow/no-movers.
    CASE WHEN COALESCE(uw.avg_daily_usage_30, 0) > 0
         THEN ROUND(COALESCE(oh.quantity_on_hand, 0) / uw.avg_daily_usage_30, 1)
         ELSE NULL
    END AS days_of_supply_30,
    fn_recommended_reorder_qty(f.facility_id, si.item_id, 90) AS recommended_reorder_qty
FROM facilities f
JOIN supply_items si ON TRUE
JOIN item_categories ic ON ic.category_id = si.category_id
LEFT JOIN on_hand oh ON oh.facility_id = f.facility_id AND oh.item_id = si.item_id
LEFT JOIN usage_windows uw ON uw.facility_id = f.facility_id AND uw.item_id = si.item_id
WHERE f.is_active
  AND si.is_active
  -- Only surface pairs the facility actually stocks (has lot history) or is
  -- already below reorder point with zero on hand — otherwise every facility
  -- would show every item in the 150-row catalog, most never carried there.
  AND (oh.quantity_on_hand IS NOT NULL)
  AND COALESCE(oh.quantity_on_hand, 0) < si.reorder_point;

COMMENT ON VIEW vw_low_stock_alert IS
    'Items currently below reorder point per facility, with trailing 30/60/90-day average daily usage and days-of-supply remaining. Source: inventory_lots + usage_transactions.';

-- Example usage: everything below reorder point at one facility, worst first.
-- SELECT * FROM vw_low_stock_alert
-- WHERE facility_id = 1
-- ORDER BY days_of_supply_30 NULLS LAST;

-- Sample output (see README for a captured example with real seed data).
