-- =============================================================================
-- Query 6: Waste analysis
--
-- BUSINESS QUESTION
-- "How much money are we actually burning on expired/wasted stock, broken
--  down by category and facility — and is it concentrated enough somewhere
--  to justify a process fix (smaller order quantities, tighter FEFO
--  discipline, a redistribution program) rather than just writing it off?"
--
-- APPROACH
-- usage_transactions.transaction_type = 'waste' is the ground truth for
-- "this stock was destroyed/discarded", valued at the receiving lot's own
-- unit_cost_at_receipt (not the catalog's current unit_cost) so historical
-- waste is costed at what was actually paid for it. Rolled up by category
-- (via the item_categories hierarchy) and facility, with a percent-of-total
-- column so a reviewer can see concentration at a glance.
-- =============================================================================

CREATE OR REPLACE VIEW vw_waste_analysis AS
WITH waste_events AS (
    SELECT
        ut.facility_id,
        ut.item_id,
        ut.lot_id,
        ut.quantity,
        ut.transaction_date,
        il.unit_cost_at_receipt,
        (ut.quantity * il.unit_cost_at_receipt) AS waste_value
    FROM usage_transactions ut
    JOIN inventory_lots il ON il.lot_id = ut.lot_id
    WHERE ut.transaction_type = 'waste'
)
SELECT
    f.facility_id,
    f.name AS facility_name,
    ic.category_id,
    ic.category_name,
    COUNT(*) AS waste_event_count,
    SUM(we.quantity) AS total_units_wasted,
    ROUND(SUM(we.waste_value), 2) AS total_waste_value,
    ROUND(
        100.0 * SUM(we.waste_value) / SUM(SUM(we.waste_value)) OVER (),
        2
    ) AS pct_of_total_waste_value
FROM waste_events we
JOIN facilities f ON f.facility_id = we.facility_id
JOIN supply_items si ON si.item_id = we.item_id
JOIN item_categories ic ON ic.category_id = si.category_id
GROUP BY f.facility_id, f.name, ic.category_id, ic.category_name
ORDER BY total_waste_value DESC;

COMMENT ON VIEW vw_waste_analysis IS
    'Total value of wasted/expired stock by facility and leaf category, valued at each lot''s actual receipt cost. pct_of_total_waste_value uses a window function (SUM() OVER ()) to show concentration without a second query.';

-- Top wasted items fleet-wide, independent of the facility/category rollup
-- above -- useful for a "which SKUs should we stop over-ordering" list.
CREATE OR REPLACE VIEW vw_waste_by_item AS
SELECT
    si.item_id,
    si.item_name,
    si.item_code,
    ic.category_name,
    COUNT(*) AS waste_event_count,
    SUM(ut.quantity) AS total_units_wasted,
    ROUND(SUM(ut.quantity * il.unit_cost_at_receipt), 2) AS total_waste_value,
    ROUND(SUM(ut.quantity * il.unit_cost_at_receipt)
          / NULLIF((SELECT SUM(rl.quantity_fulfilled * rl.unit_cost_at_order)
                    FROM requisition_lines rl WHERE rl.item_id = si.item_id), 0) * 100, 2
    ) AS waste_as_pct_of_total_spend
FROM usage_transactions ut
JOIN inventory_lots il ON il.lot_id = ut.lot_id
JOIN supply_items si ON si.item_id = ut.item_id
JOIN item_categories ic ON ic.category_id = si.category_id
WHERE ut.transaction_type = 'waste'
GROUP BY si.item_id, si.item_name, si.item_code, ic.category_name
ORDER BY total_waste_value DESC;

COMMENT ON VIEW vw_waste_by_item IS
    'Wasted value per catalog item fleet-wide, with waste as a percentage of that item''s total procurement spend -- flags items where a large share of what we buy ends up discarded rather than used.';

-- Example usage: worst facility/category combinations by dollars wasted.
-- SELECT * FROM vw_waste_analysis LIMIT 10;

-- Example usage: items where waste is eating the largest share of spend.
-- SELECT * FROM vw_waste_by_item WHERE waste_as_pct_of_total_spend IS NOT NULL ORDER BY waste_as_pct_of_total_spend DESC LIMIT 10;
