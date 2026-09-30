# Analytical queries

Each file below is self-contained: run it once (in order — some later views
build on earlier ones) to create a `CREATE OR REPLACE VIEW`/`FUNCTION`, then
query that view/function directly. All of them depend on `schema.sql` and
`functions_triggers.sql` (specifically `fn_recommended_reorder_qty`) already
being loaded.

```bash
for f in queries/0*.sql; do psql -U <user> -d medlogtrack -f "$f"; done
```

| File | Business question | Object created |
|---|---|---|
| [`01_low_stock_alert.sql`](01_low_stock_alert.sql) | Which items are below reorder point right now, at which facility, and how many days of supply are left? | `vw_low_stock_alert` |
| [`02_expiration_risk.sql`](02_expiration_risk.sql) | Which lots are expiring soon, and what should we do about each one — use first, transfer, or return to the vendor? | `fn_expiration_risk(p_window_days)` |
| [`03_vendor_scorecard.sql`](03_vendor_scorecard.sql) | Which suppliers actually hit their promised lead time and fill what we order? | `vw_vendor_scorecard` |
| [`04_demand_trend_analysis.sql`](04_demand_trend_analysis.sql) | Is usage of this item trending up sharply enough to justify raising its reorder point? | `vw_demand_trend`, `vw_demand_trend_alerts` |
| [`05_facility_comparison.sql`](05_facility_comparison.sql) | Which facilities are over/under-stocked relative to their peers, and where could we redistribute instead of buying more? | `vw_facility_stock_position`, `vw_redistribution_candidates` |
| [`06_waste_analysis.sql`](06_waste_analysis.sql) | How much are we losing to expired/wasted stock, by facility and category? | `vw_waste_analysis`, `vw_waste_by_item` |
| [`07_category_spend_rollup.sql`](07_category_spend_rollup.sql) | What's total spend per category, rolled all the way up the category hierarchy (recursive CTE)? | `vw_category_spend_rollup` |
| [`08_kit_bom_expansion.sql`](08_kit_bom_expansion.sql) | If we need to build N of a kit, how many of each raw component does that require, including nested sub-kits (recursive CTE)? | `fn_expand_kit(p_item_id, p_quantity)` |
| [`indexing_demo.sql`](indexing_demo.sql) | Documented before/after `EXPLAIN ANALYZE` for the schema's one load-bearing composite index. | — (reference only) |

Every file carries its own header comment explaining the approach and why
it's built the way it is — read the file for the reasoning, this table is
just the index.
