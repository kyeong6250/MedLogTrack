-- =============================================================================
-- Query 8: Kit / bill-of-materials expansion (bonus recursive CTE)
--
-- BUSINESS QUESTION
-- "If we need to build N of this kit, how many of each raw component does
--  that actually require?" Kits can nest (a kit can contain another kit as
--  a component), so the multiplier has to compound down the tree -- a flat
--  join against kit_components only captures one level.
--
-- APPROACH
-- fn_expand_kit(p_item_id, p_quantity) recursively walks kit_components
-- starting from p_item_id, multiplying quantity_per_kit down each level
-- (2 kits x 3 sub-kits each x 4 components each = 24 of that component),
-- and returns the fully flattened leaf-level parts list. A depth guard
-- (max 10 levels) protects against a bad data load introducing a cycle,
-- since kit_components has no DB-level cycle constraint (see schema.sql
-- comment on that table for why).
--
-- The seed data only nests one level deep (see scripts/generate_seed_data.py
-- -- the CAT tourniquet item doubles as an IFAK-style kit parent), but this
-- function handles arbitrarily deep nesting, which is the point of using a
-- recursive CTE here instead of a fixed number of self-joins.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_expand_kit(p_item_id INTEGER, p_quantity INTEGER DEFAULT 1)
RETURNS TABLE (
    component_item_id INTEGER,
    component_name VARCHAR,
    total_quantity_required BIGINT,
    depth INTEGER,
    is_leaf BOOLEAN
) AS $$
    WITH RECURSIVE bom AS (
        SELECT
            kc.component_item_id,
            kc.quantity_per_kit * p_quantity AS qty_required,
            1 AS depth
        FROM kit_components kc
        WHERE kc.parent_item_id = p_item_id

        UNION ALL

        SELECT
            kc.component_item_id,
            kc.quantity_per_kit * bom.qty_required,
            bom.depth + 1
        FROM kit_components kc
        JOIN bom ON kc.parent_item_id = bom.component_item_id
        WHERE bom.depth < 10  -- cycle guard; see header comment
    )
    SELECT
        bom.component_item_id,
        si.item_name,
        SUM(bom.qty_required)::BIGINT AS total_quantity_required,
        MIN(bom.depth) AS depth,
        NOT EXISTS (
            SELECT 1 FROM kit_components kc2 WHERE kc2.parent_item_id = bom.component_item_id
        ) AS is_leaf
    FROM bom
    JOIN supply_items si ON si.item_id = bom.component_item_id
    GROUP BY bom.component_item_id, si.item_name
    ORDER BY MIN(bom.depth), si.item_name;
$$ LANGUAGE sql STABLE;

COMMENT ON FUNCTION fn_expand_kit(INTEGER, INTEGER) IS
    'Recursively flattens a kit-style supply_item into its leaf-level component parts list via kit_components, multiplying quantity_per_kit down through any nested sub-kits. total_quantity_required is per p_quantity kits requested.';

-- Example usage: parts list to build 25 IFAK-style kits (component item is
-- "Combat Application Tourniquet (CAT) Gen 7" -- see kit_components seed data).
-- SELECT * FROM fn_expand_kit(
--     (SELECT item_id FROM supply_items WHERE item_name = 'Combat Application Tourniquet (CAT) Gen 7'),
--     25
-- );
