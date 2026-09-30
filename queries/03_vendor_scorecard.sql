-- =============================================================================
-- Query 3: Vendor performance scorecard
--
-- BUSINESS QUESTION
-- "Which suppliers are actually hitting their promised lead times and
--  filling what we order, and how do they rank against each other?" — the
--  data a contracting officer needs before a contract renewal conversation.
--
-- APPROACH
-- Only requisitions that were actually (at least partially) fulfilled carry
-- a date_fulfilled, so lead time and on-time rate are computed over those;
-- fill rate is computed over every non-cancelled requisition line regardless
-- of whether it's fully resolved yet, since "how much of what we asked for
-- did we get" is meaningful even for a partial fulfillment. Three RANK()
-- window functions expose the ranking from three angles (speed, reliability,
-- completeness) since a vendor can be fast-but-stingy or slow-but-thorough
-- and a single blended score would hide that distinction.
-- =============================================================================

CREATE OR REPLACE VIEW vw_vendor_scorecard AS
WITH fulfilled_reqs AS (
    SELECT
        r.requisition_id,
        r.supplier_id,
        r.date_submitted,
        r.date_fulfilled,
        (r.date_fulfilled - r.date_submitted) AS actual_lead_time_days
    FROM requisitions r
    WHERE r.date_fulfilled IS NOT NULL
      AND r.date_submitted IS NOT NULL
),
lead_time_stats AS (
    SELECT
        fr.supplier_id,
        COUNT(*) AS fulfilled_requisition_count,
        ROUND(AVG(fr.actual_lead_time_days), 1) AS avg_actual_lead_time_days,
        ROUND(
            100.0 * COUNT(*) FILTER (WHERE fr.actual_lead_time_days <= s.contracted_lead_time_days) / COUNT(*),
            1
        ) AS on_time_fulfillment_pct
    FROM fulfilled_reqs fr
    JOIN suppliers s ON s.supplier_id = fr.supplier_id
    GROUP BY fr.supplier_id, s.contracted_lead_time_days
),
fill_stats AS (
    SELECT
        r.supplier_id,
        SUM(rl.quantity_requested) AS total_quantity_requested,
        SUM(rl.quantity_fulfilled) AS total_quantity_fulfilled,
        ROUND(100.0 * SUM(rl.quantity_fulfilled) / NULLIF(SUM(rl.quantity_requested), 0), 1) AS fill_rate_pct
    FROM requisitions r
    JOIN requisition_lines rl ON rl.requisition_id = r.requisition_id
    WHERE r.status <> 'cancelled'
    GROUP BY r.supplier_id
),
requisition_volume AS (
    SELECT supplier_id, COUNT(*) AS total_requisitions,
           COUNT(*) FILTER (WHERE status = 'cancelled') AS cancelled_requisitions
    FROM requisitions
    GROUP BY supplier_id
)
SELECT
    s.supplier_id,
    s.name AS supplier_name,
    s.contracted_lead_time_days,
    s.reliability_rating,
    COALESCE(rv.total_requisitions, 0) AS total_requisitions,
    COALESCE(rv.cancelled_requisitions, 0) AS cancelled_requisitions,
    COALESCE(lts.fulfilled_requisition_count, 0) AS fulfilled_requisition_count,
    lts.avg_actual_lead_time_days,
    lts.on_time_fulfillment_pct,
    fs.fill_rate_pct,
    -- Three independent rankings — see header comment for why we don't
    -- collapse these into one blended score.
    RANK() OVER (ORDER BY lts.avg_actual_lead_time_days ASC NULLS LAST) AS rank_by_speed,
    RANK() OVER (ORDER BY lts.on_time_fulfillment_pct DESC NULLS LAST) AS rank_by_on_time_pct,
    RANK() OVER (ORDER BY fs.fill_rate_pct DESC NULLS LAST) AS rank_by_fill_rate
FROM suppliers s
LEFT JOIN lead_time_stats lts ON lts.supplier_id = s.supplier_id
LEFT JOIN fill_stats fs ON fs.supplier_id = s.supplier_id
LEFT JOIN requisition_volume rv ON rv.supplier_id = s.supplier_id
ORDER BY rank_by_on_time_pct;

COMMENT ON VIEW vw_vendor_scorecard IS
    'Per-supplier average actual lead time vs. contracted lead time, on-time fulfillment rate, and fill rate (qty fulfilled / qty requested), with RANK() window functions ranking suppliers by speed, reliability, and completeness independently.';

-- Example usage: the five best and five worst suppliers by on-time rate.
-- SELECT * FROM vw_vendor_scorecard ORDER BY rank_by_on_time_pct LIMIT 5;
-- SELECT * FROM vw_vendor_scorecard ORDER BY rank_by_on_time_pct DESC LIMIT 5;
