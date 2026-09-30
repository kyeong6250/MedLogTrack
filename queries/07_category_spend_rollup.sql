-- =============================================================================
-- Query 7: Recursive category spend roll-up
--
-- BUSINESS QUESTION
-- "How much are we spending in each category, all the way up the hierarchy
--  -- not just at the leaf ('Antibiotics') but rolled up into its parent
--  ('Pharmaceuticals') too?" A single GROUP BY item_categories.category_id
--  only gives leaf-level totals; it can't roll a subcategory's spend up into
--  its parent without knowing the tree shape, which is exactly what a
--  recursive CTE is for.
--
-- APPROACH
-- 1. Recursively walk item_categories from every root (parent_category_id
--    IS NULL) down, building each category's full path and depth.
-- 2. Compute leaf-level spend directly from requisition_lines.
-- 3. Roll leaf spend up to every ancestor by joining the category closure
--    (every category paired with all of its descendants) against leaf
--    spend and summing.
-- =============================================================================

CREATE OR REPLACE VIEW vw_category_spend_rollup AS
WITH RECURSIVE category_tree AS (
    -- anchor: root categories (Pharmaceuticals, Consumables, Durable Medical
    -- Equipment, Controlled Substances)
    SELECT
        category_id,
        category_name,
        parent_category_id,
        category_id AS root_category_id,
        category_name::TEXT AS path,
        0 AS depth
    FROM item_categories
    WHERE parent_category_id IS NULL

    UNION ALL

    -- recursive step: each child inherits its parent's path/root, one level deeper
    SELECT
        c.category_id,
        c.category_name,
        c.parent_category_id,
        ct.root_category_id,
        ct.path || ' > ' || c.category_name,
        ct.depth + 1
    FROM item_categories c
    JOIN category_tree ct ON c.parent_category_id = ct.category_id
),
-- Every (ancestor, descendant-or-self) pair -- this is the "closure table"
-- that makes the roll-up a plain join instead of a second recursive walk.
category_closure AS (
    SELECT category_id AS ancestor_id, category_id AS descendant_id FROM item_categories
    UNION ALL
    SELECT ct_ancestor.category_id, ct_descendant.category_id
    FROM category_tree ct_descendant
    JOIN category_tree ct_ancestor
        ON ct_descendant.path LIKE ct_ancestor.path || ' > %'
       AND ct_ancestor.root_category_id = ct_descendant.root_category_id
),
leaf_spend AS (
    SELECT
        si.category_id,
        SUM(rl.quantity_fulfilled * rl.unit_cost_at_order) AS spend
    FROM requisition_lines rl
    JOIN supply_items si ON si.item_id = rl.item_id
    WHERE rl.quantity_fulfilled > 0
    GROUP BY si.category_id
)
SELECT
    ct.category_id,
    ct.category_name,
    ct.path AS category_path,
    ct.depth,
    ROUND(COALESCE(ls_direct.spend, 0), 2) AS direct_spend,
    ROUND(COALESCE(SUM(ls_rolled.spend), 0), 2) AS total_spend_incl_subcategories
FROM category_tree ct
LEFT JOIN leaf_spend ls_direct ON ls_direct.category_id = ct.category_id
LEFT JOIN category_closure cc ON cc.ancestor_id = ct.category_id
LEFT JOIN leaf_spend ls_rolled ON ls_rolled.category_id = cc.descendant_id
GROUP BY ct.category_id, ct.category_name, ct.path, ct.depth, ls_direct.spend
ORDER BY ct.path;

COMMENT ON VIEW vw_category_spend_rollup IS
    'Requisition spend per category AND rolled up through the item_categories hierarchy via a recursive CTE + closure table, so a root category (e.g. Pharmaceuticals) shows total spend across every subcategory beneath it, not just items filed directly under it.';

-- Example usage: top-level category totals only (depth = 0).
-- SELECT category_name, total_spend_incl_subcategories
-- FROM vw_category_spend_rollup WHERE depth = 0
-- ORDER BY total_spend_incl_subcategories DESC;

-- Example usage: the full indented tree.
-- SELECT repeat('  ', depth) || category_name AS category, direct_spend, total_spend_incl_subcategories
-- FROM vw_category_spend_rollup ORDER BY category_path;
