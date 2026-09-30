-- =============================================================================
-- Query 2: Expiration risk report (FEFO)
--
-- BUSINESS QUESTION
-- "Which lots are about to expire, and what should we actually do about each
--  one — use it first, ship it to a facility that will burn through it in
--  time, or send it back to the vendor before it becomes a total loss?"
--
-- APPROACH
-- fn_expiration_risk(p_window_days) returns every lot expiring inside the
-- window, FEFO-ranked within its own (facility, item) — rank 1 is the lot
-- that should be issued next under First-Expired-First-Out. Recommended
-- action is a simple decision tree:
--   RETURN_TO_SUPPLIER — expiring very soon (<=7 days) and projected usage
--                         at this facility won't consume it in time anyway;
--                         cutting losses now beats wasting it later.
--   TRANSFER_CANDIDATE — this facility's usage is too slow to consume it,
--                         but another facility is both short on this item
--                         (per vw_low_stock_alert) and has enough runway.
--   USE_FIRST           — the normal case: it's this (facility,item)'s
--                         FEFO-first lot, so ordinary issuing should already
--                         be drawing it down before newer stock.
--   MONITOR             — expiring within the window but not urgent and not
--                         next up in FEFO order yet.
-- A table function (not a plain view) because the risk window needs to be a
-- caller-supplied parameter, not baked into the view definition.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_expiration_risk(p_window_days INTEGER DEFAULT 30)
RETURNS TABLE (
    facility_id INTEGER,
    facility_name VARCHAR,
    lot_id INTEGER,
    lot_number VARCHAR,
    item_id INTEGER,
    item_name VARCHAR,
    item_code VARCHAR,
    quantity_on_hand INTEGER,
    unit_cost_at_receipt NUMERIC,
    expiration_date DATE,
    days_until_expiration INTEGER,
    fefo_rank BIGINT,
    avg_daily_usage_30 NUMERIC,
    projected_days_to_consume NUMERIC,
    recommended_action TEXT
) AS $$
BEGIN
    RETURN QUERY
    WITH at_risk_lots AS (
        SELECT
            il.lot_id, il.facility_id, il.item_id, il.lot_number,
            il.quantity_on_hand, il.unit_cost_at_receipt, il.expiration_date,
            (il.expiration_date - CURRENT_DATE) AS days_until_expiration,
            ROW_NUMBER() OVER (
                PARTITION BY il.facility_id, il.item_id
                ORDER BY il.expiration_date ASC, il.received_date ASC
            ) AS fefo_rank
        FROM inventory_lots il
        WHERE il.expiration_date IS NOT NULL
          AND il.expiration_date BETWEEN CURRENT_DATE AND CURRENT_DATE + p_window_days
          AND il.quantity_on_hand > 0
          AND il.status <> 'returned'
    ),
    usage_30 AS (
        SELECT ut.facility_id, ut.item_id, SUM(ut.quantity) / 30.0 AS avg_daily_usage_30
        FROM usage_transactions ut
        WHERE ut.transaction_type IN ('issue', 'waste', 'transfer_out')
          AND ut.transaction_date >= CURRENT_DATE - 30
        GROUP BY ut.facility_id, ut.item_id
    )
    SELECT
        arl.facility_id,
        f.name,
        arl.lot_id,
        arl.lot_number,
        arl.item_id,
        si.item_name,
        si.item_code,
        arl.quantity_on_hand,
        arl.unit_cost_at_receipt,
        arl.expiration_date,
        arl.days_until_expiration,
        arl.fefo_rank,
        ROUND(COALESCE(u.avg_daily_usage_30, 0), 2),
        CASE WHEN COALESCE(u.avg_daily_usage_30, 0) > 0
             THEN ROUND(arl.quantity_on_hand / u.avg_daily_usage_30, 1)
             ELSE NULL END,
        CASE
            WHEN arl.days_until_expiration <= 7
                 AND (u.avg_daily_usage_30 IS NULL OR u.avg_daily_usage_30 = 0
                      OR arl.quantity_on_hand / u.avg_daily_usage_30 > arl.days_until_expiration)
                THEN 'RETURN_TO_SUPPLIER'
            WHEN (u.avg_daily_usage_30 IS NULL OR u.avg_daily_usage_30 = 0
                  OR arl.quantity_on_hand / u.avg_daily_usage_30 > arl.days_until_expiration)
                 AND nf.facility_names IS NOT NULL
                THEN 'TRANSFER_CANDIDATE: ' || array_to_string(nf.facility_names, ', ')
            WHEN arl.fefo_rank = 1
                THEN 'USE_FIRST'
            ELSE 'MONITOR'
        END AS recommended_action
    FROM at_risk_lots arl
    JOIN facilities f ON f.facility_id = arl.facility_id
    JOIN supply_items si ON si.item_id = arl.item_id
    LEFT JOIN usage_30 u ON u.facility_id = arl.facility_id AND u.item_id = arl.item_id
    -- Candidate receiving facilities for a transfer: same item, currently
    -- below reorder point at some OTHER facility (never the one already
    -- holding the at-risk lot — that's not a transfer, that's the status quo).
    LEFT JOIN LATERAL (
        SELECT array_agg(DISTINCT lsa.facility_name ORDER BY lsa.facility_name) AS facility_names
        FROM vw_low_stock_alert lsa
        WHERE lsa.item_id = arl.item_id AND lsa.facility_id <> arl.facility_id
    ) nf ON TRUE
    ORDER BY arl.days_until_expiration ASC, arl.quantity_on_hand * arl.unit_cost_at_receipt DESC;
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION fn_expiration_risk(INTEGER) IS
    'Lots expiring within p_window_days, FEFO-ranked per facility/item, with a recommended action (RETURN_TO_SUPPLIER / TRANSFER_CANDIDATE / USE_FIRST / MONITOR) derived from projected consumption rate vs. days remaining.';

-- Example usage: everything expiring in the next 30 days, most urgent first.
-- SELECT * FROM fn_expiration_risk(30);

-- Example usage: a tighter 14-day window for a same-week action list.
-- SELECT * FROM fn_expiration_risk(14) WHERE recommended_action <> 'MONITOR';
