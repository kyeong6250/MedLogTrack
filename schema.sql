-- =============================================================================
-- MedLogTrack — Schema DDL
-- A medical supply chain / inventory management data model for a multi-site
-- hospital network — multiple facilities (medical centers, hospitals, and
-- clinics) each holding their own inventory and requisitioning from a shared
-- pool of vendors.
--
-- NOTE: This is a portfolio/demo project. Every facility, supplier, price,
-- and transaction in this repo's seed data is fictional and synthetically
-- generated — none of it reflects any real hospital, vendor, or pricing.
--
-- Target: PostgreSQL 14+ (developed/validated on PostgreSQL 17).
-- Design notes on normalization, lot-level tracking, and FEFO live in the
-- top-level README — this file focuses on the "what" and the "why" of each
-- constraint/index decision inline.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Extensions
-- -----------------------------------------------------------------------------
-- pgcrypto gives us gen_random_uuid() if we ever want external-facing surrogate
-- keys; not required for the core model (we use plain serial/identity PKs
-- because every FK chain here is purely internal), but harmless to keep on.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Enumerated types
-- -----------------------------------------------------------------------------
-- Using real ENUM types (rather than free-text + CHECK) where the value set is
-- small, closed, and unlikely to need per-row metadata. This buys cheap storage
-- (4 bytes), index-friendly equality/ordering, and a schema-level guarantee
-- that bad values can't sneak in from application bugs.

CREATE TYPE facility_type_enum AS ENUM (
    'Medical Center',
    'Hospital',
    'Ambulatory Care Clinic',
    'Medical Clinic',
    'Dental Clinic'
);

CREATE TYPE requisition_status_enum AS ENUM (
    'draft',
    'submitted',
    'approved',
    'partially_fulfilled',
    'fulfilled',
    'cancelled'
);

-- Split further than the prompt's four words (issue/waste/transfer/adjustment)
-- on purpose: transfers and adjustments are inherently directional (stock
-- either leaves or enters a facility), and the "does this increase or
-- decrease quantity_on_hand" question has to be answerable from the type
-- alone for the stock-guard trigger below to work without a separate sign
-- column. See README "Schema design decisions" for the full rationale.
CREATE TYPE transaction_type_enum AS ENUM (
    'issue',               -- dispensed/consumed in patient care (decreases stock)
    'waste',                -- expired/damaged/contaminated, discarded (decreases stock)
    'transfer_out',          -- shipped to another facility (decreases stock)
    'transfer_in',            -- received from another facility (increases stock)
    'adjustment_increase',     -- positive inventory correction, e.g. count error (increases stock)
    'adjustment_decrease'       -- negative inventory correction (decreases stock)
);

CREATE TYPE lot_status_enum AS ENUM (
    'active',           -- normal, usable stock
    'expiring_soon',    -- inside the facility's expiration-warning window
    'expired',          -- past expiration_date, must not be issued
    'depleted',         -- quantity_on_hand = 0, kept for audit history
    'returned'          -- sent back to supplier / disposed, out of usable stock
);

CREATE TYPE personnel_role_enum AS ENUM (
    'Supply Chain Technician',
    'Supply Chain Manager',
    'Inventory Supervisor',
    'Materials Manager',
    'Approving Official',
    'Pharmacy Technician',
    'Biomedical Equipment Technician'
);

-- =============================================================================
-- Core reference tables
-- =============================================================================

CREATE TABLE facilities (
    facility_id     SERIAL PRIMARY KEY,
    name            VARCHAR(120) NOT NULL,
    location        VARCHAR(120) NOT NULL,          -- "city, state" or "city, country"
    region          VARCHAR(40)  NOT NULL,           -- e.g. 'Northeast', 'Midwest', 'South', 'West'
    facility_type   facility_type_enum NOT NULL,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_facilities_name UNIQUE (name)
);
COMMENT ON TABLE facilities IS 'Facilities in the hospital network: medical centers, hospitals, and clinics that hold inventory and submit requisitions.';

CREATE TABLE suppliers (
    supplier_id             SERIAL PRIMARY KEY,
    name                    VARCHAR(120) NOT NULL,
    contracted_lead_time_days  SMALLINT NOT NULL CHECK (contracted_lead_time_days > 0),
    reliability_rating      NUMERIC(2,1) NOT NULL DEFAULT 3.0 CHECK (reliability_rating BETWEEN 0.0 AND 5.0),
    contact_name            VARCHAR(100),
    contact_email           VARCHAR(150),
    contact_phone           VARCHAR(30),
    is_active               BOOLEAN NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_suppliers_name UNIQUE (name)
);
COMMENT ON TABLE suppliers IS 'Vendors who fulfill requisitions. contracted_lead_time_days is the SLA promise; actual performance is derived from requisitions in the vendor scorecard view, never stored redundantly here.';
COMMENT ON COLUMN suppliers.reliability_rating IS 'Manually-assigned baseline rating (procurement team judgment call at vendor onboarding), distinct from the computed on-time-fulfillment metrics in vw_vendor_scorecard.';

-- Self-referencing hierarchy: top-level categories (Pharmaceuticals,
-- Consumables, Durable Medical Equipment, Controlled Substances) with nested
-- subcategories. NULL parent_category_id marks a root category.
CREATE TABLE item_categories (
    category_id         SERIAL PRIMARY KEY,
    category_name        VARCHAR(100) NOT NULL,
    parent_category_id    INTEGER REFERENCES item_categories(category_id) ON DELETE RESTRICT,
    description           TEXT,

    CONSTRAINT uq_item_categories_name_parent UNIQUE (category_name, parent_category_id)
);
COMMENT ON TABLE item_categories IS 'Self-referencing category hierarchy (root categories have parent_category_id IS NULL). Enables recursive roll-up of spend/usage from leaf subcategories up to top-level categories.';

-- -----------------------------------------------------------------------------
-- Catalog
-- -----------------------------------------------------------------------------

CREATE TABLE supply_items (
    item_id                SERIAL PRIMARY KEY,
    item_code               VARCHAR(20) NOT NULL,     -- internal catalog stock number, e.g. 'MS-6505-11234'
    item_name               VARCHAR(150) NOT NULL,
    category_id              INTEGER NOT NULL REFERENCES item_categories(category_id) ON DELETE RESTRICT,
    unit_of_issue             VARCHAR(10) NOT NULL,    -- EA, BX, CS, VI, BT, PR, RO, TU, KT ...
    reorder_point              INTEGER NOT NULL CHECK (reorder_point >= 0),
    safety_stock_level          INTEGER NOT NULL CHECK (safety_stock_level >= 0),
    unit_cost                    NUMERIC(10,2) NOT NULL CHECK (unit_cost >= 0),
    is_expiration_tracked         BOOLEAN NOT NULL DEFAULT TRUE,
    is_active                      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at                      TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_supply_items_code UNIQUE (item_code),
    -- Safety stock is a floor that should sit at or below the reorder point
    -- (you reorder before you dip into the safety cushion); flags data-entry
    -- mistakes at insert time instead of downstream in a report.
    CONSTRAINT ck_supply_items_safety_le_reorder CHECK (safety_stock_level <= reorder_point)
);
COMMENT ON TABLE supply_items IS 'Catalog of items a facility can stock — the "what", not the "how much is on hand where" (that is inventory_lots).';
COMMENT ON COLUMN supply_items.is_expiration_tracked IS 'FALSE for most durable equipment; TRUE for pharmaceuticals and most consumables. inventory_lots.expiration_date is expected to be NULL exactly when this is FALSE (enforced by trigger, not a CHECK, because it spans two tables).';

-- Bill-of-materials style kit composition: a supply_item can itself be a "kit"
-- made of other supply_items (e.g. a trauma response kit made of a
-- tourniquet, gauze, and a chest seal). Components can themselves be kits,
-- enabling nested kits (e.g. a crash cart restock kit containing several
-- smaller trauma kits) — expanded recursively in
-- queries/08_kit_bom_expansion.sql.
CREATE TABLE kit_components (
    parent_item_id       INTEGER NOT NULL REFERENCES supply_items(item_id) ON DELETE CASCADE,
    component_item_id     INTEGER NOT NULL REFERENCES supply_items(item_id) ON DELETE RESTRICT,
    quantity_per_kit        INTEGER NOT NULL CHECK (quantity_per_kit > 0),

    PRIMARY KEY (parent_item_id, component_item_id),
    CONSTRAINT ck_kit_components_no_self_reference CHECK (parent_item_id <> component_item_id)
);
COMMENT ON TABLE kit_components IS 'Optional bill-of-materials edges for kit-style supply_items. A row means "1 unit of parent_item_id requires quantity_per_kit units of component_item_id". Components may themselves have rows as a parent (nested kits) — cycles are prevented at the application/load layer, not by a DB constraint, since true cycle-detection needs a recursive check.';

-- =============================================================================
-- Personnel (audit trail)
-- =============================================================================

CREATE TABLE personnel (
    personnel_id      SERIAL PRIMARY KEY,
    facility_id        INTEGER NOT NULL REFERENCES facilities(facility_id) ON DELETE RESTRICT,
    first_name          VARCHAR(60) NOT NULL,
    last_name            VARCHAR(60) NOT NULL,
    rank_or_title         VARCHAR(40),
    role                    personnel_role_enum NOT NULL,
    email                    VARCHAR(150) NOT NULL,
    is_active                BOOLEAN NOT NULL DEFAULT TRUE,

    CONSTRAINT uq_personnel_email UNIQUE (email)
);
COMMENT ON TABLE personnel IS 'Staff who request/approve requisitions or execute usage transactions — supports an audit-trail angle (who did what, where).';

-- =============================================================================
-- Inventory (lot-level)
-- =============================================================================

-- Why lot-level and not a single quantity_on_hand column on supply_items: see
-- README "Why lot-level tracking". Short version — expiration, FEFO issuing,
-- and recall traceability all require knowing *which* physical batch you're
-- looking at, not just a facility-wide total.
CREATE TABLE inventory_lots (
    lot_id               SERIAL PRIMARY KEY,
    facility_id            INTEGER NOT NULL REFERENCES facilities(facility_id) ON DELETE RESTRICT,
    item_id                  INTEGER NOT NULL REFERENCES supply_items(item_id) ON DELETE RESTRICT,
    supplier_id                INTEGER NOT NULL REFERENCES suppliers(supplier_id) ON DELETE RESTRICT,
    lot_number                   VARCHAR(40) NOT NULL,
    quantity_on_hand                INTEGER NOT NULL CHECK (quantity_on_hand >= 0),
    unit_cost_at_receipt              NUMERIC(10,2) NOT NULL CHECK (unit_cost_at_receipt >= 0),
    expiration_date                     DATE,                 -- NULL for non-expiring durable equipment
    received_date                         DATE NOT NULL,
    status                                   lot_status_enum NOT NULL DEFAULT 'active',
    created_at                                TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- A given supplier's lot number is only unique within one item at one
    -- facility (two different facilities can both receive lot "A1234" of the
    -- same item from the same supplier shipment split across destinations).
    CONSTRAINT uq_inventory_lots_facility_item_lot UNIQUE (facility_id, item_id, lot_number),
    CONSTRAINT ck_inventory_lots_expiration_after_received
        CHECK (expiration_date IS NULL OR expiration_date > received_date)
);
COMMENT ON TABLE inventory_lots IS 'Actual stock on hand, tracked per facility per item per received batch (lot). This is the row-level granularity every other inventory question (low-stock, expiration risk, FEFO, waste valuation) is computed from.';

-- Enforce is_expiration_tracked <-> expiration_date consistency across the
-- supply_items/inventory_lots boundary. A CHECK constraint can't reference
-- another table, so this has to be a trigger.
CREATE OR REPLACE FUNCTION fn_validate_lot_expiration_tracking()
RETURNS TRIGGER AS $$
DECLARE
    v_is_tracked BOOLEAN;
BEGIN
    SELECT is_expiration_tracked INTO v_is_tracked
    FROM supply_items WHERE item_id = NEW.item_id;

    IF v_is_tracked AND NEW.expiration_date IS NULL THEN
        RAISE EXCEPTION 'item_id % is expiration-tracked; inventory_lots.expiration_date cannot be NULL (lot %)', NEW.item_id, NEW.lot_number;
    ELSIF NOT v_is_tracked AND NEW.expiration_date IS NOT NULL THEN
        RAISE EXCEPTION 'item_id % is not expiration-tracked; inventory_lots.expiration_date must be NULL (lot %)', NEW.item_id, NEW.lot_number;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_lot_expiration_tracking
    BEFORE INSERT OR UPDATE OF item_id, expiration_date ON inventory_lots
    FOR EACH ROW EXECUTE FUNCTION fn_validate_lot_expiration_tracking();

-- =============================================================================
-- Requisitions (facility orders to suppliers)
-- =============================================================================

CREATE TABLE requisitions (
    requisition_id          SERIAL PRIMARY KEY,
    facility_id               INTEGER NOT NULL REFERENCES facilities(facility_id) ON DELETE RESTRICT,
    supplier_id                 INTEGER NOT NULL REFERENCES suppliers(supplier_id) ON DELETE RESTRICT,
    requested_by                  INTEGER NOT NULL REFERENCES personnel(personnel_id) ON DELETE RESTRICT,
    approved_by                     INTEGER REFERENCES personnel(personnel_id) ON DELETE RESTRICT,
    status                             requisition_status_enum NOT NULL DEFAULT 'draft',
    date_submitted                       DATE,
    date_approved                          DATE,
    date_fulfilled                           DATE,
    created_at                                 TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_requisitions_approved_after_submitted
        CHECK (date_approved IS NULL OR date_submitted IS NULL OR date_approved >= date_submitted),
    CONSTRAINT ck_requisitions_fulfilled_after_submitted
        CHECK (date_fulfilled IS NULL OR date_submitted IS NULL OR date_fulfilled >= date_submitted)
);
COMMENT ON TABLE requisitions IS 'A single order placed by a facility to a supplier. Line-item detail (what/how much) lives in requisition_lines.';

CREATE TABLE requisition_lines (
    requisition_line_id     SERIAL PRIMARY KEY,
    requisition_id            INTEGER NOT NULL REFERENCES requisitions(requisition_id) ON DELETE CASCADE,
    item_id                      INTEGER NOT NULL REFERENCES supply_items(item_id) ON DELETE RESTRICT,
    quantity_requested              INTEGER NOT NULL CHECK (quantity_requested > 0),
    quantity_fulfilled                 INTEGER NOT NULL DEFAULT 0 CHECK (quantity_fulfilled >= 0),
    unit_cost_at_order                    NUMERIC(10,2) NOT NULL CHECK (unit_cost_at_order >= 0),
    -- Generated column: this is pure arithmetic over two columns already on
    -- the row, so Postgres can maintain it for free (STORED) instead of every
    -- reporting query re-deriving quantity_fulfilled * unit_cost_at_order.
    line_total_cost                         NUMERIC(12,2) GENERATED ALWAYS AS (quantity_fulfilled * unit_cost_at_order) STORED,

    CONSTRAINT uq_requisition_lines_req_item UNIQUE (requisition_id, item_id),
    CONSTRAINT ck_requisition_lines_fulfilled_le_requested
        CHECK (quantity_fulfilled <= quantity_requested)
);
COMMENT ON TABLE requisition_lines IS 'Line items on a requisition. unit_cost_at_order is captured at order time (not looked up live from supply_items) so historical requisitions keep the price that was actually quoted, even after catalog prices change.';

-- =============================================================================
-- Usage transactions (stock movement ledger)
-- =============================================================================

CREATE TABLE usage_transactions (
    transaction_id         SERIAL PRIMARY KEY,
    facility_id               INTEGER NOT NULL REFERENCES facilities(facility_id) ON DELETE RESTRICT,
    item_id                     INTEGER NOT NULL REFERENCES supply_items(item_id) ON DELETE RESTRICT,
    lot_id                         INTEGER NOT NULL REFERENCES inventory_lots(lot_id) ON DELETE RESTRICT,
    performed_by                      INTEGER REFERENCES personnel(personnel_id) ON DELETE RESTRICT,
    transaction_type                     transaction_type_enum NOT NULL,
    quantity                                INTEGER NOT NULL CHECK (quantity > 0),
    transaction_date                           DATE NOT NULL,
    notes                                         TEXT,
    created_at                                     TIMESTAMPTZ NOT NULL DEFAULT now()
);
COMMENT ON TABLE usage_transactions IS 'Append-only ledger of stock movement against a specific lot. quantity is always positive; transaction_type determines direction (see trg_apply_usage_transaction). This is the source of truth for demand/usage analytics.';
COMMENT ON COLUMN usage_transactions.transaction_type IS 'issue/waste/transfer_out/adjustment_decrease reduce inventory_lots.quantity_on_hand; transfer_in/adjustment_increase increase it. Enforced and applied by trg_apply_usage_transaction.';

-- =============================================================================
-- Indexes
-- =============================================================================
-- Every index below is justified by a specific access pattern this system
-- actually needs (the seven analytical views in queries/, plus the OLTP-ish
-- paths of receiving a shipment and recording usage). We deliberately did NOT
-- index every FK blindly — e.g. requisition_lines.requisition_id is covered
-- well enough by the UNIQUE(requisition_id, item_id) constraint's implicit
-- index for our query patterns, so a second single-column index would just be
-- write overhead with no read benefit here.

-- Catalog browsing / category rollups filter or join on category_id constantly.
CREATE INDEX idx_supply_items_category ON supply_items(category_id);

-- The single hottest lookup in the whole system: "what do we have on hand for
-- item X at facility Y". Every analytical view (low-stock, expiration risk,
-- facility comparison) starts here. Composite, facility first, because most
-- calling code is scoped to one facility.
CREATE INDEX idx_inventory_lots_facility_item ON inventory_lots(facility_id, item_id);

-- Expiration risk scans only ever care about rows that actually expire.
-- Partial index skips the ~40% of lots (non-expiration-tracked durable
-- equipment) that would otherwise bloat the index for a query that never
-- looks at them.
CREATE INDEX idx_inventory_lots_expiration ON inventory_lots(expiration_date)
    WHERE expiration_date IS NOT NULL;

-- Vendor scorecard and "what's outstanding" dashboards both filter by
-- facility + status together.
CREATE INDEX idx_requisitions_facility_status ON requisitions(facility_id, status);
CREATE INDEX idx_requisitions_supplier ON requisitions(supplier_id);

-- Requisition -> line fan-out, and "everywhere this item was ever ordered".
CREATE INDEX idx_requisition_lines_item ON requisition_lines(item_id);

-- This is the big one, sized for the query pattern that matters most: trailing
-- 30/60/90-day usage aggregated per facility per item (low-stock alert, demand
-- trend, facility comparison all hit this). Composite + covering the exact
-- WHERE/GROUP BY shape means Postgres can use an index-only-ish scan instead
-- of a sequential scan over what will be, at production volume, the largest
-- table in the schema. See queries/indexing_demo.sql for a measured
-- before/after with EXPLAIN ANALYZE.
CREATE INDEX idx_usage_transactions_facility_item_date
    ON usage_transactions(facility_id, item_id, transaction_date);

-- usage_transactions is append-only and time-ordered by nature (new rows land
-- at "now"), so a BRIN index on transaction_date gives range-scan performance
-- close to a B-tree at a small fraction of the storage/maintenance cost —
-- exactly the tradeoff BRIN is built for on large, naturally-ordered tables.
CREATE INDEX idx_usage_transactions_date_brin ON usage_transactions USING BRIN (transaction_date);

CREATE INDEX idx_usage_transactions_lot ON usage_transactions(lot_id);

CREATE INDEX idx_personnel_facility ON personnel(facility_id);

CREATE INDEX idx_item_categories_parent ON item_categories(parent_category_id);
