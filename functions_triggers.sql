-- =============================================================================
-- MedLogTrack — Business-logic functions, triggers, and procedures
-- Run after schema.sql.
-- =============================================================================

-- =============================================================================
-- 1. Stock guard trigger
-- Prevents a usage_transaction from ever driving inventory_lots.quantity_on_hand
-- below zero, and is also the single place that actually applies a usage
-- transaction's effect to the lot (so lot quantity and the transaction ledger
-- can never drift apart — there is no code path that updates one without the
-- other).
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_apply_usage_transaction()
RETURNS TRIGGER AS $$
DECLARE
    v_current_qty INTEGER;
    v_is_increase BOOLEAN;
BEGIN
    v_is_increase := NEW.transaction_type IN ('transfer_in', 'adjustment_increase');

    -- Lock the lot row for the duration of this transaction so two concurrent
    -- usage_transactions against the same lot can't both read the same
    -- quantity_on_hand and both believe they have enough stock (classic
    -- lost-update race). FOR UPDATE blocks the second writer until the first
    -- commits, at which point it re-reads the now-current quantity.
    SELECT quantity_on_hand INTO v_current_qty
    FROM inventory_lots
    WHERE lot_id = NEW.lot_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'inventory_lots.lot_id % does not exist', NEW.lot_id;
    END IF;

    IF v_is_increase THEN
        UPDATE inventory_lots
        SET quantity_on_hand = quantity_on_hand + NEW.quantity
        WHERE lot_id = NEW.lot_id;
    ELSE
        IF v_current_qty - NEW.quantity < 0 THEN
            RAISE EXCEPTION
                'usage_transaction would drive lot % quantity_on_hand negative (on hand: %, requested: %, type: %)',
                NEW.lot_id, v_current_qty, NEW.quantity, NEW.transaction_type;
        END IF;

        UPDATE inventory_lots
        SET quantity_on_hand = quantity_on_hand - NEW.quantity,
            status = CASE WHEN quantity_on_hand - NEW.quantity = 0 THEN 'depleted'::lot_status_enum ELSE status END
        WHERE lot_id = NEW.lot_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_apply_usage_transaction
    BEFORE INSERT ON usage_transactions
    FOR EACH ROW EXECUTE FUNCTION fn_apply_usage_transaction();

COMMENT ON FUNCTION fn_apply_usage_transaction() IS
    'Applies a usage_transactions row to inventory_lots.quantity_on_hand and rejects any transaction that would take a lot negative. BEFORE INSERT (not AFTER) so the exception aborts the insert itself — the ledger never contains a transaction that was not actually applied.';

-- =============================================================================
-- 2. Lot status lifecycle
-- -----------------------------------------------------------------------------
-- 2a. Trigger: set the *initial* status of a lot at insert/update time based
--     on its expiration_date as of right now. This handles the data-driven
--     half of the lifecycle (a row being inserted or its expiration_date
--     being corrected).
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_set_initial_lot_status()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.quantity_on_hand = 0 THEN
        NEW.status := 'depleted';
    ELSIF NEW.expiration_date IS NOT NULL AND NEW.expiration_date <= CURRENT_DATE THEN
        NEW.status := 'expired';
    ELSIF NEW.expiration_date IS NOT NULL AND NEW.expiration_date <= CURRENT_DATE + INTERVAL '30 days' THEN
        NEW.status := 'expiring_soon';
    ELSIF NEW.status IN ('expired', 'expiring_soon', 'depleted') THEN
        -- A previously-flagged lot whose expiration_date just got corrected
        -- further out, or whose quantity just got corrected up from zero,
        -- goes back to active.
        NEW.status := 'active';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_set_initial_lot_status
    BEFORE INSERT OR UPDATE OF expiration_date, quantity_on_hand ON inventory_lots
    FOR EACH ROW EXECUTE FUNCTION fn_set_initial_lot_status();

-- -----------------------------------------------------------------------------
-- 2b. Scheduled-job design (the time-driven half).
--
-- A lot can cross from 'active' into 'expiring_soon', or from 'expiring_soon'
-- into 'expired', purely because a day passed — with no INSERT/UPDATE against
-- the row to hang a trigger off of. Postgres triggers fire on DML, not on the
-- clock, so this half of the lifecycle has to be a scheduled job instead.
--
-- Design (as it would run in production):
--   - Extension: pg_cron (or an external scheduler — Airflow, a Kubernetes
--     CronJob, cron + psql — calling the same procedure).
--   - Schedule: nightly at 06:00 facility-local/UTC, well before the morning
--     pick-and-pull shift starts, so the status board is accurate for the day.
--   - Job body: CALL sp_refresh_lot_status();
--   - Idempotent and safe to re-run: it only ever recomputes status from
--     (expiration_date, quantity_on_hand), never accumulates state.
--
-- Example pg_cron registration (commented out — requires the pg_cron
-- extension to be installed and shared_preload_libraries configured, which
-- is a superuser/server-config step outside the scope of this repo's DDL):
--
--   -- CREATE EXTENSION IF NOT EXISTS pg_cron;
--   -- SELECT cron.schedule('medlogtrack-nightly-lot-status',
--   --                       '0 6 * * *',
--   --                       $$CALL sp_refresh_lot_status()$$);
--
-- We implement and validate the procedure itself below so it is runnable
-- today (call it manually, or wire it into any scheduler) even without
-- pg_cron installed.
-- -----------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE sp_refresh_lot_status()
LANGUAGE plpgsql AS $$
DECLARE
    v_updated_count INTEGER;
BEGIN
    UPDATE inventory_lots
    SET status = CASE
        WHEN quantity_on_hand = 0 THEN 'depleted'
        WHEN expiration_date IS NOT NULL AND expiration_date <= CURRENT_DATE THEN 'expired'
        WHEN expiration_date IS NOT NULL AND expiration_date <= CURRENT_DATE + INTERVAL '30 days' THEN 'expiring_soon'
        ELSE 'active'
    END::lot_status_enum
    WHERE status <> CASE
        WHEN quantity_on_hand = 0 THEN 'depleted'
        WHEN expiration_date IS NOT NULL AND expiration_date <= CURRENT_DATE THEN 'expired'
        WHEN expiration_date IS NOT NULL AND expiration_date <= CURRENT_DATE + INTERVAL '30 days' THEN 'expiring_soon'
        ELSE 'active'
    END::lot_status_enum
    AND status <> 'returned';  -- returned lots are a manual terminal state; the nightly job never touches them

    GET DIAGNOSTICS v_updated_count = ROW_COUNT;
    RAISE NOTICE 'sp_refresh_lot_status: % lot(s) updated', v_updated_count;
END;
$$;

COMMENT ON PROCEDURE sp_refresh_lot_status() IS
    'Time-driven half of the lot status lifecycle — recomputes status for every lot from today''s date. Intended to run nightly via pg_cron or an external scheduler; see comment block above for the production wiring.';

-- =============================================================================
-- 3. Recommended reorder quantity
-- Given a facility + item, recommends how much to reorder using the classic
-- (demand during lead time) + safety stock − on hand formula.
-- =============================================================================

CREATE OR REPLACE FUNCTION fn_recommended_reorder_qty(
    p_facility_id INTEGER,
    p_item_id INTEGER,
    p_lookback_days INTEGER DEFAULT 90
)
RETURNS INTEGER AS $$
DECLARE
    v_avg_daily_usage NUMERIC;
    v_lead_time_days NUMERIC;
    v_safety_stock INTEGER;
    v_on_hand INTEGER;
    v_recommended INTEGER;
BEGIN
    -- Recent demand: average daily quantity issued/wasted/transferred out at
    -- this facility for this item over the trailing lookback window. Only
    -- outbound movement counts as "demand" — transfer_in and adjustments are
    -- corrections, not consumption.
    SELECT COALESCE(SUM(quantity), 0) / GREATEST(p_lookback_days, 1)::NUMERIC
    INTO v_avg_daily_usage
    FROM usage_transactions
    WHERE facility_id = p_facility_id
      AND item_id = p_item_id
      AND transaction_type IN ('issue', 'waste', 'transfer_out')
      AND transaction_date >= CURRENT_DATE - p_lookback_days;

    -- Lead time: the contracted lead time of whichever supplier most recently
    -- supplied this item to this facility (falls back to the fleet-wide
    -- average contracted lead time if the pair has no receiving history yet).
    SELECT s.contracted_lead_time_days INTO v_lead_time_days
    FROM inventory_lots il
    JOIN suppliers s ON s.supplier_id = il.supplier_id
    WHERE il.facility_id = p_facility_id AND il.item_id = p_item_id
    ORDER BY il.received_date DESC
    LIMIT 1;

    IF v_lead_time_days IS NULL THEN
        SELECT AVG(contracted_lead_time_days) INTO v_lead_time_days FROM suppliers WHERE is_active;
    END IF;

    SELECT safety_stock_level INTO v_safety_stock FROM supply_items WHERE item_id = p_item_id;

    SELECT COALESCE(SUM(quantity_on_hand), 0) INTO v_on_hand
    FROM inventory_lots
    WHERE facility_id = p_facility_id AND item_id = p_item_id AND status <> 'returned';

    v_recommended := CEIL(
        (v_avg_daily_usage * v_lead_time_days) + v_safety_stock - v_on_hand
    );

    RETURN GREATEST(v_recommended, 0);
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION fn_recommended_reorder_qty(INTEGER, INTEGER, INTEGER) IS
    'Recommended reorder quantity = (avg daily usage over trailing p_lookback_days * supplier lead time) + safety stock - current on-hand, floored at 0. Mirrors the classic reorder-point/EOQ demand-during-lead-time formula used in real supply systems.';

-- =============================================================================
-- 4. Receiving a shipment — multi-table transactional update
-- Receiving a shipment against a requisition touches three tables at once:
--   - inventory_lots: insert the newly-received lot(s)
--   - requisition_lines: bump quantity_fulfilled
--   - requisitions: roll the header status up to partially_fulfilled/fulfilled
-- All three have to succeed together or not at all — a partial write here
-- (say, the lot gets created but the requisition line doesn't get marked
-- fulfilled) would silently desync on-hand stock from what the paperwork
-- says was ordered, which is exactly the kind of discrepancy an audit would
-- flag. PL/pgSQL procedures already run inside an implicit transaction for
-- the duration of the CALL and roll back automatically on an unhandled
-- exception, so this needs no explicit BEGIN/COMMIT — the EXCEPTION block
-- below exists to add a clear, logged rollback reason rather than to trigger
-- the rollback itself (RAISE re-throws, which is what actually aborts it).
-- =============================================================================

CREATE OR REPLACE PROCEDURE sp_receive_shipment(
    p_requisition_id INTEGER,
    p_item_id INTEGER,
    p_lot_number VARCHAR,
    p_quantity_received INTEGER,
    p_unit_cost NUMERIC,
    p_expiration_date DATE,
    p_received_date DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_facility_id INTEGER;
    v_supplier_id INTEGER;
    v_line_id INTEGER;
    v_quantity_requested INTEGER;
    v_quantity_already_fulfilled INTEGER;
    v_new_fulfilled INTEGER;
    v_total_requested INTEGER;
    v_total_fulfilled INTEGER;
BEGIN
    IF p_quantity_received <= 0 THEN
        RAISE EXCEPTION 'p_quantity_received must be positive (got %)', p_quantity_received;
    END IF;

    SELECT facility_id, supplier_id INTO v_facility_id, v_supplier_id
    FROM requisitions WHERE requisition_id = p_requisition_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'requisition_id % does not exist', p_requisition_id;
    END IF;

    SELECT requisition_line_id, quantity_requested, quantity_fulfilled
    INTO v_line_id, v_quantity_requested, v_quantity_already_fulfilled
    FROM requisition_lines
    WHERE requisition_id = p_requisition_id AND item_id = p_item_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'requisition % has no line for item_id %', p_requisition_id, p_item_id;
    END IF;

    v_new_fulfilled := v_quantity_already_fulfilled + p_quantity_received;

    IF v_new_fulfilled > v_quantity_requested THEN
        RAISE EXCEPTION
            'receiving % units of item % on requisition % would fulfill % / % requested — rejecting overfulfillment',
            p_quantity_received, p_item_id, p_requisition_id, v_new_fulfilled, v_quantity_requested;
    END IF;

    -- Step 1: the physical stock arrives as a new lot.
    -- (trg_validate_lot_expiration_tracking and trg_set_initial_lot_status
    -- both fire here — an expiration mismatch with the catalog definition
    -- aborts the whole procedure, which is exactly the "partial failure
    -- rolls back cleanly" behavior this procedure is meant to demonstrate.)
    INSERT INTO inventory_lots (
        facility_id, item_id, supplier_id, lot_number,
        quantity_on_hand, unit_cost_at_receipt, expiration_date, received_date
    ) VALUES (
        v_facility_id, p_item_id, v_supplier_id, p_lot_number,
        p_quantity_received, p_unit_cost, p_expiration_date, p_received_date
    );

    -- Step 2: the paperwork catches up to the physical receipt.
    UPDATE requisition_lines
    SET quantity_fulfilled = v_new_fulfilled
    WHERE requisition_line_id = v_line_id;

    -- Step 3: roll the requisition header status up from its lines.
    SELECT SUM(quantity_requested), SUM(quantity_fulfilled)
    INTO v_total_requested, v_total_fulfilled
    FROM requisition_lines
    WHERE requisition_id = p_requisition_id;

    UPDATE requisitions
    SET status = CASE
            WHEN v_total_fulfilled >= v_total_requested THEN 'fulfilled'
            WHEN v_total_fulfilled > 0 THEN 'partially_fulfilled'
            ELSE status
        END,
        date_fulfilled = CASE
            WHEN v_total_fulfilled >= v_total_requested THEN p_received_date
            ELSE date_fulfilled
        END
    WHERE requisition_id = p_requisition_id;

EXCEPTION
    WHEN OTHERS THEN
        RAISE NOTICE 'sp_receive_shipment rolled back for requisition % / item %: %', p_requisition_id, p_item_id, SQLERRM;
        RAISE;  -- re-raise so the caller's transaction actually aborts; this NOTICE is purely for audit-log visibility into *why*.
END;
$$;

COMMENT ON PROCEDURE sp_receive_shipment(INTEGER, INTEGER, VARCHAR, INTEGER, NUMERIC, DATE, DATE) IS
    'Receives one shipment line against a requisition: creates the inventory_lots row, updates requisition_lines.quantity_fulfilled, and rolls the parent requisitions.status up — atomically. Any failure (bad quantity, expiration-tracking mismatch, overfulfillment) rolls back all three effects together.';
