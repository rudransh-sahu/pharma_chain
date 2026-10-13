BEGIN;

SET search_path = pharmachain, public;

CREATE SEQUENCE po_number_seq START WITH 1;

CREATE OR REPLACE FUNCTION branch_business_date(
    p_branch_id BIGINT,
    p_timestamp TIMESTAMPTZ
) RETURNS DATE
LANGUAGE sql
STABLE
SET search_path = pharmachain, pg_temp
AS $$
    SELECT (p_timestamp AT TIME ZONE b.time_zone)::DATE
    FROM branches AS b
    WHERE b.branch_id = p_branch_id;
$$;

CREATE OR REPLACE FUNCTION fn_reject_mutation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION '% is append-only: % is not permitted', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'integrity_constraint_violation';
END;
$$;

CREATE OR REPLACE FUNCTION fn_batch_identity_guard()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
BEGIN
    IF (NEW.branch_id, NEW.drug_id, NEW.supplier_id, NEW.po_item_id,
        NEW.batch_number, NEW.unit_cost, NEW.manufactured_on, NEW.expires_on)
       IS DISTINCT FROM
       (OLD.branch_id, OLD.drug_id, OLD.supplier_id, OLD.po_item_id,
        OLD.batch_number, OLD.unit_cost, OLD.manufactured_on, OLD.expires_on)
    THEN
        RAISE EXCEPTION 'Batch identity is immutable for batch_id %', OLD.batch_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF OLD.is_recalled AND NOT NEW.is_recalled THEN
        RAISE EXCEPTION 'A recall cannot be cleared for batch_id %', OLD.batch_id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_batch_identity_guard
BEFORE UPDATE ON batches
FOR EACH ROW EXECUTE FUNCTION fn_batch_identity_guard();

CREATE OR REPLACE FUNCTION fn_apply_inventory_movement()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_batch batches%ROWTYPE;
    v_after INTEGER;
    v_business_date DATE;
BEGIN
    SELECT *
    INTO v_batch
    FROM batches
    WHERE batch_id = NEW.batch_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown batch_id %', NEW.batch_id;
    END IF;

    v_business_date := branch_business_date(v_batch.branch_id, NEW.occurred_at);

    IF NEW.quantity_delta > 0
       AND NEW.movement_type IN (
           'OPENING_BALANCE', 'RECEIPT', 'TRANSFER_IN', 'CUSTOMER_RETURN'
       )
       AND v_batch.expires_on <= v_business_date
    THEN
        RAISE EXCEPTION 'Expired stock rejected for batch %: expiry %, movement date %',
            v_batch.batch_number, v_batch.expires_on, v_business_date
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.quantity_delta > 0
       AND NEW.movement_type IN ('RECEIPT', 'TRANSFER_IN', 'CUSTOMER_RETURN')
       AND v_batch.is_recalled
    THEN
        RAISE EXCEPTION 'Recalled stock rejected for batch %', v_batch.batch_number
            USING ERRCODE = 'check_violation';
    END IF;

    v_after := v_batch.quantity_on_hand + NEW.quantity_delta;

    IF v_after < 0 THEN
        RAISE EXCEPTION 'Insufficient stock for batch %: on hand %, delta %',
            v_batch.batch_number, v_batch.quantity_on_hand, NEW.quantity_delta
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_after < v_batch.quantity_reserved THEN
        RAISE EXCEPTION 'Movement would reduce batch % below its reserved quantity %',
            v_batch.batch_number, v_batch.quantity_reserved
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE batches
    SET quantity_on_hand = v_after
    WHERE batch_id = NEW.batch_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_apply_inventory_movement
BEFORE INSERT ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION fn_apply_inventory_movement();

CREATE TRIGGER trg_inventory_movements_immutable
BEFORE UPDATE OR DELETE ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION fn_reject_mutation();

CREATE TRIGGER trg_inventory_movements_no_truncate
BEFORE TRUNCATE ON inventory_movements
FOR EACH STATEMENT EXECUTE FUNCTION fn_reject_mutation();

CREATE TRIGGER trg_stock_adjustments_immutable
BEFORE UPDATE OR DELETE ON stock_adjustments
FOR EACH ROW EXECUTE FUNCTION fn_reject_mutation();

CREATE OR REPLACE FUNCTION fn_check_drug_interaction()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_severity interaction_severity;
    v_description TEXT;
    v_other_drug BIGINT;
BEGIN
    SELECT di.severity, di.description, pi.drug_id
    INTO v_severity, v_description, v_other_drug
    FROM prescription_items AS pi
    JOIN drug_interactions AS di
      ON di.drug_a_id = LEAST(NEW.drug_id, pi.drug_id)
     AND di.drug_b_id = GREATEST(NEW.drug_id, pi.drug_id)
    WHERE pi.prescription_id = NEW.prescription_id
      AND pi.status <> 'CANCELLED'
      AND (TG_OP = 'INSERT' OR pi.prescription_item_id <> NEW.prescription_item_id)
    ORDER BY di.severity DESC
    LIMIT 1;

    IF FOUND THEN
        RAISE EXCEPTION 'Drug interaction blocked between drug % and drug % [%]: %',
            NEW.drug_id, v_other_drug, v_severity, v_description
            USING ERRCODE = 'check_violation',
                  DETAIL = format('severity=%s; description=%s', v_severity, v_description);
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_prescription_item_interaction_guard
BEFORE INSERT OR UPDATE OF prescription_id, drug_id ON prescription_items
FOR EACH ROW EXECUTE FUNCTION fn_check_drug_interaction();

CREATE OR REPLACE FUNCTION fn_validate_dispense_allocation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_item prescription_items%ROWTYPE;
    v_batch batches%ROWTYPE;
    v_branch_id BIGINT;
    v_already_dispensed BIGINT;
    v_business_date DATE;
BEGIN
    SELECT pi.*
    INTO v_item
    FROM prescription_items AS pi
    WHERE pi.prescription_item_id = NEW.prescription_item_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown prescription_item_id %', NEW.prescription_item_id;
    END IF;

    IF v_item.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Prescription item % is %, not PENDING',
            v_item.prescription_item_id, v_item.status;
    END IF;

    SELECT *
    INTO v_batch
    FROM batches
    WHERE batch_id = NEW.batch_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown batch_id %', NEW.batch_id;
    END IF;

    SELECT branch_id INTO v_branch_id
    FROM prescriptions
    WHERE prescription_id = v_item.prescription_id;

    IF v_batch.branch_id <> v_branch_id THEN
        RAISE EXCEPTION 'Batch % belongs to branch %, prescription belongs to branch %',
            v_batch.batch_id, v_batch.branch_id, v_branch_id
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_batch.drug_id <> v_item.drug_id THEN
        RAISE EXCEPTION 'Drug/batch mismatch: item drug %, batch drug %',
            v_item.drug_id, v_batch.drug_id
            USING ERRCODE = 'check_violation';
    END IF;

    v_business_date := branch_business_date(v_batch.branch_id, NEW.dispensed_at);

    IF v_batch.expires_on <= v_business_date THEN
        RAISE EXCEPTION 'Expired batch blocked: batch % expired on %',
            v_batch.batch_number, v_batch.expires_on
            USING ERRCODE = 'check_violation';
    END IF;

    IF v_batch.is_recalled THEN
        RAISE EXCEPTION 'Recalled batch blocked: %', v_batch.batch_number
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.quantity_dispensed > v_batch.quantity_on_hand - v_batch.quantity_reserved THEN
        RAISE EXCEPTION 'Insufficient available stock in batch %: available %, requested %',
            v_batch.batch_number,
            v_batch.quantity_on_hand - v_batch.quantity_reserved,
            NEW.quantity_dispensed
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT COALESCE(SUM(quantity_dispensed), 0)
    INTO v_already_dispensed
    FROM dispense_allocations
    WHERE prescription_item_id = NEW.prescription_item_id;

    IF v_already_dispensed + NEW.quantity_dispensed > v_item.quantity_requested THEN
        RAISE EXCEPTION 'Allocation exceeds requested quantity for prescription item %',
            NEW.prescription_item_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_validate_dispense_allocation
BEFORE INSERT ON dispense_allocations
FOR EACH ROW EXECUTE FUNCTION fn_validate_dispense_allocation();

CREATE OR REPLACE FUNCTION fn_post_dispense_allocation()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_branch_id BIGINT;
    v_drug_id BIGINT;
    v_sale_date DATE;
BEGIN
    SELECT p.branch_id, pi.drug_id
    INTO v_branch_id, v_drug_id
    FROM prescription_items AS pi
    JOIN prescriptions AS p USING (prescription_id)
    WHERE pi.prescription_item_id = NEW.prescription_item_id;

    INSERT INTO inventory_movements (
        transaction_uuid,
        batch_id,
        movement_type,
        quantity_delta,
        reference_type,
        reference_id,
        actor_id,
        occurred_at
    ) VALUES (
        NEW.transaction_uuid,
        NEW.batch_id,
        'DISPENSE',
        -NEW.quantity_dispensed,
        'DISPENSE_ALLOCATION',
        NEW.allocation_id,
        NEW.dispensed_by,
        NEW.dispensed_at
    );

    v_sale_date := branch_business_date(v_branch_id, NEW.dispensed_at);

    INSERT INTO daily_dispense_log (
        branch_id, drug_id, sale_date, quantity_dispensed, updated_at
    ) VALUES (
        v_branch_id, v_drug_id, v_sale_date, NEW.quantity_dispensed, clock_timestamp()
    )
    ON CONFLICT (branch_id, drug_id, sale_date)
    DO UPDATE SET
        quantity_dispensed = daily_dispense_log.quantity_dispensed
            + EXCLUDED.quantity_dispensed,
        updated_at = clock_timestamp();

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_post_dispense_allocation
AFTER INSERT ON dispense_allocations
FOR EACH ROW EXECUTE FUNCTION fn_post_dispense_allocation();

CREATE TRIGGER trg_dispense_allocations_immutable
BEFORE UPDATE OR DELETE ON dispense_allocations
FOR EACH ROW EXECUTE FUNCTION fn_reject_mutation();

CREATE OR REPLACE PROCEDURE dispense_prescription_item(
    p_prescription_item_id BIGINT,
    p_dispensed_by VARCHAR,
    p_transaction_uuid UUID,
    p_min_shelf_days INTEGER DEFAULT 0
)
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_item RECORD;
    v_remaining INTEGER;
    v_take INTEGER;
    v_business_date DATE;
    v_batch RECORD;
BEGIN
    IF p_min_shelf_days < 0 THEN
        RAISE EXCEPTION 'Minimum shelf-life days cannot be negative';
    END IF;

    SELECT pi.prescription_item_id,
           pi.prescription_id,
           pi.drug_id,
           pi.quantity_requested,
           pi.status,
           p.branch_id
    INTO v_item
    FROM prescription_items AS pi
    JOIN prescriptions AS p USING (prescription_id)
    WHERE pi.prescription_item_id = p_prescription_item_id
    FOR UPDATE OF pi;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown prescription_item_id %', p_prescription_item_id;
    END IF;

    IF v_item.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Prescription item % is %, not PENDING',
            p_prescription_item_id, v_item.status;
    END IF;

    IF EXISTS (
        SELECT 1 FROM dispense_allocations
        WHERE prescription_item_id = p_prescription_item_id
    ) THEN
        RAISE EXCEPTION 'Prescription item % already has allocations', p_prescription_item_id;
    END IF;

    v_business_date := branch_business_date(v_item.branch_id, clock_timestamp());
    v_remaining := v_item.quantity_requested;

    FOR v_batch IN
        SELECT b.batch_id,
               b.quantity_on_hand - b.quantity_reserved AS available_quantity
        FROM batches AS b
        WHERE b.branch_id = v_item.branch_id
          AND b.drug_id = v_item.drug_id
          AND b.quantity_on_hand - b.quantity_reserved > 0
          AND NOT b.is_recalled
          AND b.expires_on > v_business_date + p_min_shelf_days
        ORDER BY b.expires_on, b.batch_id
        FOR UPDATE
    LOOP
        EXIT WHEN v_remaining = 0;
        v_take := LEAST(v_batch.available_quantity, v_remaining);

        INSERT INTO dispense_allocations (
            transaction_uuid,
            prescription_item_id,
            batch_id,
            quantity_dispensed,
            dispensed_by
        ) VALUES (
            p_transaction_uuid,
            p_prescription_item_id,
            v_batch.batch_id,
            v_take,
            p_dispensed_by
        );

        v_remaining := v_remaining - v_take;
    END LOOP;

    IF v_remaining > 0 THEN
        RAISE EXCEPTION 'Insufficient valid stock for drug %, short by % units',
            v_item.drug_id, v_remaining
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE prescription_items
    SET status = 'DISPENSED'
    WHERE prescription_item_id = p_prescription_item_id;

    UPDATE prescriptions AS p
    SET status = CASE
        WHEN NOT EXISTS (
            SELECT 1 FROM prescription_items AS pi
            WHERE pi.prescription_id = p.prescription_id
              AND pi.status = 'PENDING'
        ) THEN 'DISPENSED'::prescription_status
        ELSE 'PARTIALLY_DISPENSED'::prescription_status
    END
    WHERE p.prescription_id = v_item.prescription_id;
END;
$$;

CREATE OR REPLACE PROCEDURE adjust_stock(
    p_batch_id BIGINT,
    p_quantity_delta INTEGER,
    p_reason stock_adjustment_reason,
    p_adjusted_by VARCHAR,
    p_transaction_uuid UUID
)
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_before INTEGER;
    v_after INTEGER;
    v_movement_id BIGINT;
BEGIN
    IF p_quantity_delta = 0 THEN
        RAISE EXCEPTION 'Adjustment quantity cannot be zero';
    END IF;

    SELECT quantity_on_hand
    INTO v_before
    FROM batches
    WHERE batch_id = p_batch_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown batch_id %', p_batch_id;
    END IF;

    INSERT INTO inventory_movements (
        transaction_uuid, batch_id, movement_type, quantity_delta,
        reference_type, actor_id
    ) VALUES (
        p_transaction_uuid, p_batch_id, 'ADJUSTMENT', p_quantity_delta,
        'STOCK_ADJUSTMENT', p_adjusted_by
    )
    RETURNING movement_id INTO v_movement_id;

    SELECT quantity_on_hand
    INTO v_after
    FROM batches
    WHERE batch_id = p_batch_id;

    INSERT INTO stock_adjustments (
        batch_id, movement_id, quantity_delta, reason,
        stock_before, stock_after, adjusted_by
    ) VALUES (
        p_batch_id, v_movement_id, p_quantity_delta, p_reason,
        v_before, v_after, p_adjusted_by
    );
END;
$$;

CREATE OR REPLACE FUNCTION transfer_stock(
    p_source_batch_id BIGINT,
    p_destination_branch_id BIGINT,
    p_quantity INTEGER,
    p_transferred_by VARCHAR,
    p_transfer_uuid UUID
) RETURNS BIGINT
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_source batches%ROWTYPE;
    v_destination_batch_id BIGINT;
    v_transfer_id BIGINT;
    v_transfer_item_id BIGINT;
    v_destination_date DATE;
BEGIN
    IF p_quantity <= 0 THEN
        RAISE EXCEPTION 'Transfer quantity must be greater than zero';
    END IF;

    SELECT * INTO v_source
    FROM batches
    WHERE batch_id = p_source_batch_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown source batch_id %', p_source_batch_id;
    END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(
        format('%s|%s|%s', v_source.drug_id, v_source.supplier_id, v_source.batch_number),
        0
    ));

    SELECT * INTO v_source
    FROM batches
    WHERE batch_id = p_source_batch_id
    FOR UPDATE;

    IF v_source.branch_id = p_destination_branch_id THEN
        RAISE EXCEPTION 'Source and destination branches must differ';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM branches
        WHERE branch_id = p_destination_branch_id AND is_active
    ) THEN
        RAISE EXCEPTION 'Unknown or inactive destination branch %', p_destination_branch_id;
    END IF;

    IF v_source.is_recalled THEN
        RAISE EXCEPTION 'Recalled batch % cannot be transferred', v_source.batch_number;
    END IF;

    IF p_quantity > v_source.quantity_on_hand - v_source.quantity_reserved THEN
        RAISE EXCEPTION 'Insufficient transferable stock: available %, requested %',
            v_source.quantity_on_hand - v_source.quantity_reserved, p_quantity
            USING ERRCODE = 'check_violation';
    END IF;

    v_destination_date := branch_business_date(p_destination_branch_id, clock_timestamp());
    IF v_source.expires_on <= v_destination_date THEN
        RAISE EXCEPTION 'Expired batch % cannot be transferred', v_source.batch_number
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO batches (
        branch_id, drug_id, supplier_id, batch_number,
        unit_cost, manufactured_on, expires_on, received_at
    ) VALUES (
        p_destination_branch_id,
        v_source.drug_id,
        v_source.supplier_id,
        v_source.batch_number,
        v_source.unit_cost,
        v_source.manufactured_on,
        v_source.expires_on,
        clock_timestamp()
    )
    ON CONFLICT (branch_id, drug_id, supplier_id, batch_number) DO NOTHING;

    SELECT batch_id
    INTO v_destination_batch_id
    FROM batches
    WHERE branch_id = p_destination_branch_id
      AND drug_id = v_source.drug_id
      AND supplier_id = v_source.supplier_id
      AND batch_number = v_source.batch_number
    FOR UPDATE;

    INSERT INTO transfers (
        transfer_uuid, source_branch_id, destination_branch_id, transferred_by
    ) VALUES (
        p_transfer_uuid, v_source.branch_id, p_destination_branch_id, p_transferred_by
    )
    RETURNING transfer_id INTO v_transfer_id;

    INSERT INTO transfer_items (
        transfer_id, source_batch_id, destination_batch_id,
        drug_id, quantity_transferred
    ) VALUES (
        v_transfer_id, v_source.batch_id, v_destination_batch_id,
        v_source.drug_id, p_quantity
    )
    RETURNING transfer_item_id INTO v_transfer_item_id;

    INSERT INTO inventory_movements (
        transaction_uuid, batch_id, movement_type, quantity_delta,
        reference_type, reference_id, actor_id
    ) VALUES
        (p_transfer_uuid, v_source.batch_id, 'TRANSFER_OUT', -p_quantity,
         'TRANSFER_ITEM', v_transfer_item_id, p_transferred_by),
        (p_transfer_uuid, v_destination_batch_id, 'TRANSFER_IN', p_quantity,
         'TRANSFER_ITEM', v_transfer_item_id, p_transferred_by);

    RETURN v_transfer_id;
END;
$$;

CREATE TRIGGER trg_transfers_immutable
BEFORE UPDATE OR DELETE ON transfers
FOR EACH ROW EXECUTE FUNCTION fn_reject_mutation();

CREATE TRIGGER trg_transfer_items_immutable
BEFORE UPDATE OR DELETE ON transfer_items
FOR EACH ROW EXECUTE FUNCTION fn_reject_mutation();

CREATE OR REPLACE VIEW v_available_stock AS
SELECT
    b.branch_id,
    b.drug_id,
    SUM(b.quantity_on_hand - b.quantity_reserved)::BIGINT AS available_units,
    MIN(b.expires_on) AS next_expiry,
    COUNT(*)::BIGINT AS live_batches
FROM batches AS b
WHERE b.quantity_on_hand - b.quantity_reserved > 0
  AND NOT b.is_recalled
  AND b.expires_on > branch_business_date(b.branch_id, clock_timestamp())
GROUP BY b.branch_id, b.drug_id;

CREATE OR REPLACE FUNCTION find_substitutes(
    p_branch_id BIGINT,
    p_drug_id BIGINT,
    p_required_quantity INTEGER,
    p_min_shelf_days INTEGER DEFAULT 0
)
RETURNS TABLE (
    suggestion_rank BIGINT,
    candidate_drug_id BIGINT,
    brand_name VARCHAR,
    manufacturer VARCHAR,
    dosage_form VARCHAR,
    strength_mg NUMERIC,
    unit_price NUMERIC,
    total_available_stock BIGINT,
    substitution_tier VARCHAR,
    tier_priority INTEGER,
    earliest_expiry DATE
)
LANGUAGE plpgsql
STABLE
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_is_nti BOOLEAN;
    v_business_date DATE;
BEGIN
    IF p_required_quantity <= 0 THEN
        RAISE EXCEPTION 'Required quantity must be greater than zero';
    END IF;

    IF p_min_shelf_days < 0 THEN
        RAISE EXCEPTION 'Minimum shelf-life days cannot be negative';
    END IF;

    SELECT i.is_narrow_therapeutic_index
    INTO v_is_nti
    FROM drugs AS d
    JOIN ingredients AS i USING (ingredient_id)
    WHERE d.drug_id = p_drug_id AND d.is_active;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown or inactive drug_id %', p_drug_id;
    END IF;

    IF v_is_nti THEN
        RAISE EXCEPTION 'Substitution blocked for narrow therapeutic index drug %', p_drug_id
            USING ERRCODE = 'check_violation';
    END IF;

    v_business_date := branch_business_date(p_branch_id, clock_timestamp());

    RETURN QUERY
    WITH explicit_candidates AS (
        SELECT
            s.target_drug_id AS drug_id,
            'TIER_1_EXPLICIT'::VARCHAR AS tier,
            s.preference_priority AS priority
        FROM substitutes AS s
        WHERE s.source_drug_id = p_drug_id
          AND s.is_active
    ),
    ingredient_candidates AS (
        SELECT
            alternative.drug_id,
            'TIER_2_INGREDIENT'::VARCHAR AS tier,
            99 AS priority
        FROM drugs AS requested
        JOIN drugs AS alternative
          ON alternative.ingredient_id = requested.ingredient_id
         AND alternative.dosage_form = requested.dosage_form
         AND alternative.strength_mg = requested.strength_mg
         AND alternative.is_active
        WHERE requested.drug_id = p_drug_id
          AND alternative.drug_id <> p_drug_id
          AND NOT EXISTS (
              SELECT 1
              FROM explicit_candidates AS explicit
              WHERE explicit.drug_id = alternative.drug_id
          )
    ),
    candidates AS (
        SELECT * FROM explicit_candidates
        UNION ALL
        SELECT * FROM ingredient_candidates
    ),
    available AS (
        SELECT
            b.drug_id,
            SUM(b.quantity_on_hand - b.quantity_reserved)::BIGINT AS available_stock,
            MIN(b.expires_on) AS next_expiry
        FROM batches AS b
        WHERE b.branch_id = p_branch_id
          AND b.drug_id IN (SELECT c.drug_id FROM candidates AS c)
          AND b.quantity_on_hand - b.quantity_reserved > 0
          AND NOT b.is_recalled
          AND b.expires_on > v_business_date + p_min_shelf_days
        GROUP BY b.drug_id
        HAVING SUM(b.quantity_on_hand - b.quantity_reserved) >= p_required_quantity
    )
    SELECT
        DENSE_RANK() OVER (
            ORDER BY c.priority, a.available_stock DESC, d.unit_price, d.drug_id
        ),
        d.drug_id,
        d.brand_name,
        d.manufacturer,
        d.dosage_form,
        d.strength_mg,
        d.unit_price,
        a.available_stock,
        c.tier,
        c.priority,
        a.next_expiry
    FROM candidates AS c
    JOIN available AS a USING (drug_id)
    JOIN drugs AS d USING (drug_id)
    ORDER BY 1, d.drug_id;
END;
$$;

CREATE OR REPLACE PROCEDURE record_substitution_and_dispense(
    p_prescription_item_id BIGINT,
    p_substitute_drug_id BIGINT,
    p_pharmacist_id VARCHAR,
    p_reason_code VARCHAR,
    p_transaction_uuid UUID,
    p_min_shelf_days INTEGER DEFAULT 0
)
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_item RECORD;
    v_tier VARCHAR(25);
BEGIN
    SELECT pi.drug_id, pi.quantity_requested, pi.status, p.branch_id
    INTO v_item
    FROM prescription_items AS pi
    JOIN prescriptions AS p USING (prescription_id)
    WHERE pi.prescription_item_id = p_prescription_item_id
    FOR UPDATE OF pi;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown prescription_item_id %', p_prescription_item_id;
    END IF;

    IF v_item.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Prescription item % is %, not PENDING',
            p_prescription_item_id, v_item.status;
    END IF;

    SELECT fs.substitution_tier
    INTO v_tier
    FROM find_substitutes(
        v_item.branch_id,
        v_item.drug_id,
        v_item.quantity_requested,
        p_min_shelf_days
    ) AS fs
    WHERE fs.candidate_drug_id = p_substitute_drug_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Drug % is not an eligible in-stock substitute for drug %',
            p_substitute_drug_id, v_item.drug_id
            USING ERRCODE = 'check_violation';
    END IF;

    UPDATE prescription_items
    SET drug_id = p_substitute_drug_id
    WHERE prescription_item_id = p_prescription_item_id;

    INSERT INTO substitution_audit_logs (
        transaction_uuid, prescription_item_id, original_drug_id,
        substituted_drug_id, quantity_dispensed, pharmacist_id,
        substitution_tier, clinical_reason_code
    ) VALUES (
        p_transaction_uuid, p_prescription_item_id, v_item.drug_id,
        p_substitute_drug_id, v_item.quantity_requested, p_pharmacist_id,
        v_tier, p_reason_code
    );

    CALL dispense_prescription_item(
        p_prescription_item_id,
        p_pharmacist_id,
        p_transaction_uuid,
        p_min_shelf_days
    );
END;
$$;

CREATE TRIGGER trg_substitution_audit_immutable
BEFORE UPDATE OR DELETE ON substitution_audit_logs
FOR EACH ROW EXECUTE FUNCTION fn_reject_mutation();

CREATE MATERIALIZED VIEW mv_daily_demand AS
WITH branch_dates AS (
    SELECT
        b.branch_id,
        branch_business_date(b.branch_id, clock_timestamp()) AS business_date
    FROM branches AS b
    WHERE b.is_active
),
calendar AS (
    SELECT
        bd.branch_id,
        d.drug_id,
        generated.day::DATE AS demand_date,
        bd.business_date - generated.day::DATE AS days_ago
    FROM branch_dates AS bd
    CROSS JOIN drugs AS d
    CROSS JOIN LATERAL generate_series(
        bd.business_date - 89,
        bd.business_date,
        INTERVAL '1 day'
    ) AS generated(day)
    WHERE d.is_active
)
SELECT
    c.branch_id,
    c.drug_id,
    c.demand_date,
    COALESCE(log.quantity_dispensed, 0)::BIGINT AS daily_units,
    c.days_ago
FROM calendar AS c
LEFT JOIN daily_dispense_log AS log
  ON log.branch_id = c.branch_id
 AND log.drug_id = c.drug_id
 AND log.sale_date = c.demand_date
WITH NO DATA;

CREATE UNIQUE INDEX idx_mv_daily_demand_branch_drug_date
    ON mv_daily_demand (branch_id, drug_id, demand_date);

CREATE OR REPLACE VIEW v_drug_usable_inventory AS
WITH batch_totals AS (
    SELECT
        b.branch_id,
        b.drug_id,
        SUM(b.quantity_on_hand)::BIGINT AS physical_stock,
        SUM(CASE
            WHEN NOT b.is_recalled
             AND b.expires_on > branch_business_date(b.branch_id, clock_timestamp())
            THEN GREATEST(b.quantity_on_hand - b.quantity_reserved, 0)
            ELSE 0
        END)::BIGINT AS sellable_stock,
        SUM(CASE
            WHEN b.expires_on <= branch_business_date(b.branch_id, clock_timestamp())
            THEN b.quantity_on_hand ELSE 0
        END)::BIGINT AS expired_stock,
        SUM(b.quantity_reserved)::BIGINT AS reserved_stock
    FROM batches AS b
    GROUP BY b.branch_id, b.drug_id
),
on_order AS (
    SELECT
        po.branch_id,
        poi.drug_id,
        SUM(poi.quantity_ordered - poi.quantity_received)::BIGINT AS stock_on_order
    FROM purchase_orders AS po
    JOIN purchase_order_items AS poi USING (po_id)
    WHERE po.status IN ('ORDERED', 'PARTIALLY_RECEIVED')
    GROUP BY po.branch_id, poi.drug_id
)
SELECT
    b.branch_id,
    d.drug_id,
    d.brand_name,
    COALESCE(bt.physical_stock, 0)::BIGINT AS physical_stock,
    COALESCE(bt.sellable_stock, 0)::BIGINT AS usable_stock,
    COALESCE(bt.expired_stock, 0)::BIGINT AS expired_stock,
    COALESCE(bt.reserved_stock, 0)::BIGINT AS reserved_stock,
    COALESCE(oo.stock_on_order, 0)::BIGINT AS stock_on_order,
    (COALESCE(bt.sellable_stock, 0) + COALESCE(oo.stock_on_order, 0))::BIGINT
        AS inventory_position
FROM branches AS b
CROSS JOIN drugs AS d
LEFT JOIN batch_totals AS bt
  ON bt.branch_id = b.branch_id AND bt.drug_id = d.drug_id
LEFT JOIN on_order AS oo
  ON oo.branch_id = b.branch_id AND oo.drug_id = d.drug_id
WHERE b.is_active AND d.is_active;

CREATE OR REPLACE VIEW v_reorder_recommendations AS
WITH demand AS (
    SELECT
        branch_id,
        drug_id,
        AVG(daily_units) FILTER (WHERE days_ago BETWEEN 0 AND 13)
            AS average_14_day_demand,
        AVG(daily_units) AS average_90_day_demand
    FROM mv_daily_demand
    GROUP BY branch_id, drug_id
),
supplier_terms AS (
    SELECT
        b.branch_id,
        d.drug_id,
        COALESCE(preferred.lead_time_days, fallback.lead_time_days, 3) AS lead_time_days,
        COALESCE(policy.safety_stock_days, 7) AS safety_stock_days,
        COALESCE(policy.review_period_days, 14) AS review_period_days
    FROM branches AS b
    CROSS JOIN drugs AS d
    LEFT JOIN branch_drug_policies AS policy
      ON policy.branch_id = b.branch_id AND policy.drug_id = d.drug_id
    LEFT JOIN supplier_drugs AS preferred
      ON preferred.supplier_id = policy.preferred_supplier_id
     AND preferred.drug_id = d.drug_id
     AND preferred.is_active
    LEFT JOIN LATERAL (
        SELECT sd.lead_time_days
        FROM supplier_drugs AS sd
        JOIN suppliers AS s USING (supplier_id)
        WHERE sd.drug_id = d.drug_id
          AND sd.is_active
          AND s.is_active
        ORDER BY sd.lead_time_days, sd.unit_cost, sd.supplier_id
        LIMIT 1
    ) AS fallback ON TRUE
    WHERE b.is_active AND d.is_active
)
SELECT
    inv.branch_id,
    inv.drug_id,
    inv.brand_name,
    ROUND(COALESCE(d.average_14_day_demand, 0), 4) AS average_14_day_demand,
    ROUND(COALESCE(d.average_90_day_demand, 0), 4) AS average_90_day_demand,
    terms.lead_time_days,
    inv.usable_stock,
    inv.stock_on_order,
    inv.inventory_position,
    CEIL(COALESCE(d.average_14_day_demand, 0) * terms.lead_time_days * 1.20)::INTEGER
        AS reorder_point,
    GREATEST(
        CEIL(COALESCE(d.average_14_day_demand, 0) * terms.lead_time_days * 1.20)::BIGINT
            - inv.inventory_position,
        0
    )::INTEGER AS suggested_reorder_quantity,
    CASE
        WHEN COALESCE(d.average_14_day_demand, 0) = 0 THEN 'OK'
        WHEN inv.usable_stock < CEIL(d.average_14_day_demand * terms.lead_time_days)
            THEN 'CRITICAL'
        WHEN inv.inventory_position <= CEIL(d.average_14_day_demand * terms.lead_time_days * 1.20)
            THEN 'WARNING'
        ELSE 'OK'
    END AS alert_status
FROM v_drug_usable_inventory AS inv
JOIN demand AS d USING (branch_id, drug_id)
JOIN supplier_terms AS terms USING (branch_id, drug_id);

CREATE OR REPLACE PROCEDURE refresh_reorder_alerts(p_branch_id BIGINT)
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
BEGIN
    UPDATE reorder_alerts AS alert
    SET status = 'RESOLVED'
    WHERE alert.branch_id = p_branch_id
      AND alert.status = 'OPEN'
      AND NOT EXISTS (
          SELECT 1
          FROM v_reorder_recommendations AS recommendation
          WHERE recommendation.branch_id = alert.branch_id
            AND recommendation.drug_id = alert.drug_id
            AND recommendation.suggested_reorder_quantity > 0
      );

    INSERT INTO reorder_alerts (
        branch_id, drug_id, forecast_date, average_14_day_demand,
        usable_stock, stock_on_order, reorder_point, suggested_quantity
    )
    SELECT
        recommendation.branch_id,
        recommendation.drug_id,
        branch_business_date(recommendation.branch_id, clock_timestamp()),
        recommendation.average_14_day_demand,
        recommendation.usable_stock,
        recommendation.stock_on_order,
        recommendation.reorder_point,
        recommendation.suggested_reorder_quantity
    FROM v_reorder_recommendations AS recommendation
    WHERE recommendation.branch_id = p_branch_id
      AND recommendation.suggested_reorder_quantity > 0
    ON CONFLICT (branch_id, drug_id) WHERE status = 'OPEN'
    DO UPDATE SET
        forecast_date = EXCLUDED.forecast_date,
        average_14_day_demand = EXCLUDED.average_14_day_demand,
        usable_stock = EXCLUDED.usable_stock,
        stock_on_order = EXCLUDED.stock_on_order,
        reorder_point = EXCLUDED.reorder_point,
        suggested_quantity = EXCLUDED.suggested_quantity;
END;
$$;

CREATE OR REPLACE FUNCTION generate_draft_purchase_orders(
    p_branch_id BIGINT,
    p_created_by VARCHAR
)
RETURNS TABLE (
    out_po_id BIGINT,
    out_po_number VARCHAR,
    out_supplier_id BIGINT,
    out_line_count BIGINT,
    out_total_amount NUMERIC
)
LANGUAGE plpgsql
SET search_path = pharmachain, pg_temp
AS $$
DECLARE
    v_alert RECORD;
    v_supplier RECORD;
    v_po_id BIGINT;
    v_touched BIGINT[] := ARRAY[]::BIGINT[];
BEGIN
    FOR v_alert IN
        SELECT *
        FROM reorder_alerts
        WHERE branch_id = p_branch_id
          AND status = 'OPEN'
        ORDER BY alert_id
        FOR UPDATE
    LOOP
        SELECT
            sd.supplier_id,
            sd.unit_cost,
            sd.minimum_order_quantity
        INTO v_supplier
        FROM supplier_drugs AS sd
        JOIN suppliers AS s USING (supplier_id)
        LEFT JOIN branch_drug_policies AS policy
          ON policy.branch_id = p_branch_id
         AND policy.drug_id = v_alert.drug_id
        WHERE sd.drug_id = v_alert.drug_id
          AND sd.is_active
          AND s.is_active
        ORDER BY
            (sd.supplier_id = policy.preferred_supplier_id) DESC NULLS LAST,
            sd.lead_time_days,
            sd.unit_cost,
            sd.supplier_id
        LIMIT 1;

        IF NOT FOUND THEN
            CONTINUE;
        END IF;

        INSERT INTO purchase_orders (
            po_number, branch_id, supplier_id, created_by
        ) VALUES (
            'PO-' || to_char(clock_timestamp(), 'YYYY') || '-'
                || lpad(nextval('po_number_seq')::TEXT, 6, '0'),
            p_branch_id,
            v_supplier.supplier_id,
            p_created_by
        )
        ON CONFLICT (branch_id, supplier_id) WHERE status = 'DRAFT'
        DO UPDATE SET created_by = purchase_orders.created_by
        RETURNING purchase_orders.po_id INTO v_po_id;

        INSERT INTO purchase_order_items (
            po_id, drug_id, quantity_ordered, unit_cost
        ) VALUES (
            v_po_id,
            v_alert.drug_id,
            GREATEST(v_alert.suggested_quantity, v_supplier.minimum_order_quantity),
            v_supplier.unit_cost
        )
        ON CONFLICT (po_id, drug_id)
        DO UPDATE SET
            quantity_ordered = GREATEST(
                purchase_order_items.quantity_ordered,
                EXCLUDED.quantity_ordered
            ),
            unit_cost = EXCLUDED.unit_cost;

        UPDATE reorder_alerts
        SET status = 'DRAFTED', linked_po_id = v_po_id
        WHERE alert_id = v_alert.alert_id;

        IF NOT v_po_id = ANY(v_touched) THEN
            v_touched := array_append(v_touched, v_po_id);
        END IF;
    END LOOP;

    UPDATE purchase_orders AS po
    SET total_amount = totals.total_amount
    FROM (
        SELECT item.po_id, SUM(item.line_total) AS total_amount
        FROM purchase_order_items AS item
        WHERE item.po_id = ANY(v_touched)
        GROUP BY item.po_id
    ) AS totals
    WHERE po.po_id = totals.po_id;

    RETURN QUERY
    SELECT
        po.po_id,
        po.po_number,
        po.supplier_id,
        COUNT(item.po_item_id)::BIGINT,
        po.total_amount
    FROM purchase_orders AS po
    JOIN purchase_order_items AS item USING (po_id)
    WHERE po.po_id = ANY(v_touched)
    GROUP BY po.po_id
    ORDER BY po.po_id;
END;
$$;

COMMIT;
