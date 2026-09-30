-- =============================================================================
-- Query 4: Demand trend analysis
--
-- BUSINESS QUESTION
-- "Is usage of this item trending up hard enough that we should raise its
--  reorder point before it starts causing stockouts?"
--
-- APPROACH
-- Aggregate usage_transactions into fleet-wide (all facilities combined)
-- monthly totals per item, then compute a 3-month trailing moving average
-- with AVG() OVER (... ROWS BETWEEN 2 PRECEDING AND CURRENT ROW). A trend
-- ratio (current month / 3-month moving average of the prior 3 months,
-- i.e. excluding the current month so the item isn't compared to itself)
-- flags items where the current month is running meaningfully hotter than
-- its recent trend — vw_demand_trend_alerts below surfaces just the sharp
-- ones as reorder-point-increase candidates.
-- =============================================================================

CREATE OR REPLACE VIEW vw_demand_trend AS
WITH monthly_usage AS (
    SELECT
        ut.item_id,
        date_trunc('month', ut.transaction_date)::date AS usage_month,
        SUM(ut.quantity) AS total_quantity
    FROM usage_transactions ut
    WHERE ut.transaction_type IN ('issue', 'waste', 'transfer_out')
    GROUP BY ut.item_id, date_trunc('month', ut.transaction_date)
)
SELECT
    mu.item_id,
    si.item_name,
    si.item_code,
    mu.usage_month,
    mu.total_quantity,
    ROUND(AVG(mu.total_quantity) OVER (
        PARTITION BY mu.item_id ORDER BY mu.usage_month
        ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
    ), 1) AS moving_avg_3mo,
    -- Trailing average of the THREE MONTHS BEFORE the current one (1-3
    -- preceding, current row excluded) — the trend baseline the current
    -- month is judged against.
    ROUND(AVG(mu.total_quantity) OVER (
        PARTITION BY mu.item_id ORDER BY mu.usage_month
        ROWS BETWEEN 3 PRECEDING AND 1 PRECEDING
    ), 1) AS prior_3mo_avg,
    LAG(mu.total_quantity, 1) OVER (PARTITION BY mu.item_id ORDER BY mu.usage_month) AS prior_month_quantity
FROM monthly_usage mu
JOIN supply_items si ON si.item_id = mu.item_id
ORDER BY mu.item_id, mu.usage_month;

COMMENT ON VIEW vw_demand_trend IS
    'Fleet-wide monthly usage per item with a 3-month trailing moving average (window function), plus the pre-current-month 3-month baseline used to detect sharp upward trends.';

-- Sharp-uptick candidates for a reorder-point increase: current month usage
-- is running well above (default: 50%+) its own recent 3-month baseline,
-- restricted to the most recent month in the dataset so this is "what needs
-- attention right now" rather than every historical spike.
CREATE OR REPLACE VIEW vw_demand_trend_alerts AS
SELECT
    vdt.item_id,
    vdt.item_name,
    vdt.item_code,
    vdt.usage_month,
    vdt.total_quantity AS current_month_quantity,
    vdt.prior_3mo_avg,
    ROUND(vdt.total_quantity / NULLIF(vdt.prior_3mo_avg, 0), 2) AS trend_ratio,
    si.reorder_point AS current_reorder_point,
    -- Scale the existing reorder point by the same ratio demand has grown by
    -- -- a simple, explainable starting point for a human to refine, not a
    -- claim of optimality.
    CEIL(si.reorder_point * (vdt.total_quantity / NULLIF(vdt.prior_3mo_avg, 0)))
        AS suggested_reorder_point
FROM vw_demand_trend vdt
JOIN supply_items si ON si.item_id = vdt.item_id
WHERE vdt.usage_month = (SELECT MAX(usage_month) FROM vw_demand_trend)
  AND vdt.prior_3mo_avg IS NOT NULL
  AND vdt.prior_3mo_avg > 0
  AND vdt.total_quantity >= 1.5 * vdt.prior_3mo_avg
ORDER BY trend_ratio DESC;

COMMENT ON VIEW vw_demand_trend_alerts IS
    'Items whose most recent month of usage is running 50%+ above their own trailing 3-month baseline -- candidates for raising reorder_point/safety_stock_level before the trend causes a stockout. Deliberately catches the flu-season items (Influenza Vaccine, Oseltamivir, Rapid Influenza Test Kit) during Oct-Feb.';

-- Example usage: the demand trend line for one item, to see the seasonal
-- shape directly.
-- SELECT usage_month, total_quantity, moving_avg_3mo
-- FROM vw_demand_trend
-- WHERE item_name LIKE 'Influenza Vaccine%'
-- ORDER BY usage_month;
--
-- Running that query against the seed data shows the expected Oct-Jan
-- ordering/issuing spike -- but also a secondary, unseasonal bump the
-- following July. That's not noise: 'total_quantity' counts waste as well
-- as issues (see header comment), and flu vaccine carries a 240-day shelf
-- life, so lots received for one flu season that weren't fully used age out
-- and get wasted in a cluster the following summer. Real over-provisioned
-- seasonal stock behaves exactly this way — see queries/06_waste_analysis.sql
-- for the same pattern from the cost side.

-- Example usage: everything flagged as trending up sharply this month.
-- SELECT * FROM vw_demand_trend_alerts;
