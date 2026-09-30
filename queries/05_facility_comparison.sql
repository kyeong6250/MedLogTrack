-- =============================================================================
-- Query 5: Facility comparison (over/under-stocked)
--
-- BUSINESS QUESTION
-- "Which facilities are sitting on more of an item than their own usage
--  justifies, while another facility is running short of the same item —
--  i.e. where's a lateral transfer between facilities cheaper than a new buy?"
--
-- APPROACH
-- For each (facility, item), express current on-hand as "days of supply at
-- this facility's own trailing 90-day usage rate" (a longer window than the
-- low-stock alert's 30-day one, since this is a strategic redistribution
-- call, not a today's-pick-list call). Compare each facility's days-of-
-- supply against the CROSS-FACILITY AVERAGE for that same item using a
-- window function (AVG() OVER PARTITION BY item_id) — a facility is
-- "over-stocked" relative to its peers, not against some arbitrary fixed
-- target, since different facility types genuinely carry different
-- baseline levels. Redistribution candidates pair an over-stocked source
-- with an under-stocked destination for the same item.
-- =============================================================================

CREATE OR REPLACE VIEW vw_facility_stock_position AS
WITH on_hand AS (
    SELECT il.facility_id, il.item_id, SUM(il.quantity_on_hand) AS quantity_on_hand
    FROM inventory_lots il
    WHERE il.status <> 'returned'
    GROUP BY il.facility_id, il.item_id
),
usage_90 AS (
    SELECT ut.facility_id, ut.item_id, SUM(ut.quantity) / 90.0 AS avg_daily_usage_90
    FROM usage_transactions ut
    WHERE ut.transaction_type IN ('issue', 'waste', 'transfer_out')
      AND ut.transaction_date >= CURRENT_DATE - 90
    GROUP BY ut.facility_id, ut.item_id
),
position AS (
    SELECT
        oh.facility_id,
        oh.item_id,
        oh.quantity_on_hand,
        u.avg_daily_usage_90,
        CASE WHEN COALESCE(u.avg_daily_usage_90, 0) > 0
             THEN oh.quantity_on_hand / u.avg_daily_usage_90
             ELSE NULL
        END AS days_of_supply_90
    FROM on_hand oh
    LEFT JOIN usage_90 u ON u.facility_id = oh.facility_id AND u.item_id = oh.item_id
)
SELECT
    p.facility_id,
    f.name AS facility_name,
    p.item_id,
    si.item_name,
    si.item_code,
    p.quantity_on_hand,
    ROUND(COALESCE(p.avg_daily_usage_90, 0), 2) AS avg_daily_usage_90,
    ROUND(p.days_of_supply_90, 1) AS days_of_supply_90,
    -- Peer average EXCLUDES facilities with no measurable usage (NULL days-
    -- of-supply) so a facility that plain doesn't use the item doesn't drag
    -- down the average for the ones that actually do.
    ROUND(AVG(p.days_of_supply_90) OVER (PARTITION BY p.item_id), 1) AS peer_avg_days_of_supply,
    ROUND(
        p.days_of_supply_90 - AVG(p.days_of_supply_90) OVER (PARTITION BY p.item_id),
        1
    ) AS days_of_supply_vs_peer_avg,
    CASE
        WHEN p.days_of_supply_90 IS NULL THEN 'NO_RECENT_USAGE'
        WHEN p.days_of_supply_90 > 1.75 * AVG(p.days_of_supply_90) OVER (PARTITION BY p.item_id)
             AND p.days_of_supply_90 > 60
            THEN 'OVER_STOCKED'
        WHEN p.days_of_supply_90 < 0.5 * AVG(p.days_of_supply_90) OVER (PARTITION BY p.item_id)
             OR p.quantity_on_hand < si.reorder_point
            THEN 'UNDER_STOCKED'
        ELSE 'NORMAL'
    END AS stock_position
FROM position p
JOIN facilities f ON f.facility_id = p.facility_id
JOIN supply_items si ON si.item_id = p.item_id;

COMMENT ON VIEW vw_facility_stock_position IS
    'Each facility''s days-of-supply per item (trailing 90-day usage) compared against the cross-facility peer average for that same item via a window function, classified OVER_STOCKED / UNDER_STOCKED / NORMAL / NO_RECENT_USAGE.';

-- Redistribution candidates: pair each over-stocked facility with an
-- under-stocked facility carrying the same item, ranked by how large the
-- imbalance is.
CREATE OR REPLACE VIEW vw_redistribution_candidates AS
SELECT
    over_stocked.item_id,
    over_stocked.item_name,
    over_stocked.facility_id AS source_facility_id,
    over_stocked.facility_name AS source_facility_name,
    over_stocked.quantity_on_hand AS source_quantity_on_hand,
    over_stocked.days_of_supply_90 AS source_days_of_supply,
    under_stocked.facility_id AS destination_facility_id,
    under_stocked.facility_name AS destination_facility_name,
    under_stocked.quantity_on_hand AS destination_quantity_on_hand,
    under_stocked.days_of_supply_90 AS destination_days_of_supply,
    -- A conservative transfer suggestion: move enough to bring the source
    -- down to the peer average, capped at what would fill the destination
    -- up to its own item reorder point. Never suggest moving more than the
    -- source actually has on hand.
    LEAST(
        GREATEST(ROUND((over_stocked.days_of_supply_90 - over_stocked.peer_avg_days_of_supply)
                        * over_stocked.avg_daily_usage_90), 0),
        over_stocked.quantity_on_hand
    ) AS suggested_transfer_qty
FROM vw_facility_stock_position over_stocked
JOIN vw_facility_stock_position under_stocked
    ON under_stocked.item_id = over_stocked.item_id
   AND under_stocked.facility_id <> over_stocked.facility_id
WHERE over_stocked.stock_position = 'OVER_STOCKED'
  AND under_stocked.stock_position = 'UNDER_STOCKED'
ORDER BY over_stocked.item_name, source_days_of_supply DESC;

COMMENT ON VIEW vw_redistribution_candidates IS
    'Pairs an over-stocked facility with an under-stocked facility carrying the same item, with a conservative suggested transfer quantity -- the "move stock between facilities instead of buying more" recommendation.';

-- Example usage: full stock-position board for one item across all facilities.
-- SELECT facility_name, quantity_on_hand, days_of_supply_90, peer_avg_days_of_supply, stock_position
-- FROM vw_facility_stock_position
-- WHERE item_name = 'Nitrile Exam Gloves, Medium Box-100ct'
-- ORDER BY days_of_supply_90 DESC NULLS LAST;

-- Example usage: top redistribution opportunities fleet-wide.
-- SELECT * FROM vw_redistribution_candidates LIMIT 10;
