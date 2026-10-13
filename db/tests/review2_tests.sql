\set ON_ERROR_STOP on
BEGIN;

SET search_path = pharmachain, public;

CREATE OR REPLACE FUNCTION pg_temp.assert_true(
    p_condition BOOLEAN,
    p_message TEXT
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_condition IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED: %', p_message;
    END IF;
END;
$$;

SELECT branch_id
FROM branches WHERE branch_code = 'CENTRAL'
\gset central_

SELECT branch_id
FROM branches WHERE branch_code = 'NORTH'
\gset north_

SELECT drug_id
FROM drugs WHERE brand_name = 'ParaValue'
\gset para_value_

SELECT batch_id
FROM batches WHERE batch_number = 'PARA-LATE'
\gset para_late_

\echo 'TC-R2-01: expiry-aware, multi-batch FEFO dispensing'

INSERT INTO prescriptions (
    branch_id, external_reference, patient_reference, created_by
)
SELECT branch_id, 'RX-FEFO-001', 'PATIENT-DEMO-01', 'test-suite'
FROM branches WHERE branch_code = 'CENTRAL'
RETURNING prescription_id \gset fefo_

INSERT INTO prescription_items (
    prescription_id, drug_id, quantity_requested
)
SELECT :fefo_prescription_id, drug_id, 50
FROM drugs WHERE brand_name = 'ParaPrime'
RETURNING prescription_item_id \gset fefo_

CALL dispense_prescription_item(
    :fefo_prescription_item_id,
    'pharmacist-01',
    '10000000-0000-0000-0000-000000000001',
    0
);

SELECT pg_temp.assert_true(
    (SELECT quantity_on_hand = 20 FROM batches WHERE batch_number = 'PARA-EXPIRED'),
    'expired batch stock must remain untouched'
);

SELECT pg_temp.assert_true(
    (SELECT quantity_on_hand = 0 FROM batches WHERE batch_number = 'PARA-SOON'),
    'earliest valid batch must be exhausted first'
);

SELECT pg_temp.assert_true(
    (SELECT quantity_on_hand = 80 FROM batches WHERE batch_number = 'PARA-LATE'),
    'remaining quantity must come from the next valid batch'
);

SELECT pg_temp.assert_true(
    (SELECT COUNT(*) = 2
     FROM dispense_allocations
     WHERE prescription_item_id = :fefo_prescription_item_id),
    'a 50-unit request must split across two batches'
);

INSERT INTO prescriptions (
    branch_id, external_reference, patient_reference, created_by
)
SELECT branch_id, 'RX-RAW-EXPIRED-001', 'PATIENT-DEMO-RAW', 'test-suite'
FROM branches WHERE branch_code = 'CENTRAL'
RETURNING prescription_id \gset expired_

INSERT INTO prescription_items (
    prescription_id, drug_id, quantity_requested
)
SELECT :expired_prescription_id, drug_id, 1
FROM drugs WHERE brand_name = 'ParaPrime'
RETURNING prescription_item_id \gset expired_

DO $$
BEGIN
    BEGIN
        INSERT INTO dispense_allocations (
            transaction_uuid, prescription_item_id, batch_id,
            quantity_dispensed, dispensed_by
        )
        SELECT
            '10000000-0000-0000-0000-000000000002',
            pi.prescription_item_id,
            b.batch_id,
            1,
            'raw-sql-user'
        FROM prescription_items AS pi
        CROSS JOIN batches AS b
        JOIN prescriptions AS p ON p.prescription_id = pi.prescription_id
        WHERE p.external_reference = 'RX-RAW-EXPIRED-001'
          AND b.batch_number = 'PARA-EXPIRED';

        RAISE EXCEPTION 'TEST FAILED: direct expired-batch allocation was accepted';
    EXCEPTION
        WHEN check_violation THEN
            IF SQLERRM NOT LIKE 'Expired batch blocked:%' THEN
                RAISE;
            END IF;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    (SELECT COUNT(*) = 0
     FROM dispense_allocations
     WHERE prescription_item_id = :expired_prescription_item_id),
    'raw SQL must not bypass the expired-batch guard'
);

\echo 'TC-R2-02: drug-interaction blocking'

INSERT INTO prescriptions (
    branch_id, external_reference, patient_reference, created_by
)
SELECT branch_id, 'RX-INTERACTION-001', 'PATIENT-DEMO-02', 'test-suite'
FROM branches WHERE branch_code = 'CENTRAL';

INSERT INTO prescription_items (
    prescription_id, drug_id, quantity_requested
)
SELECT p.prescription_id, d.drug_id, 5
FROM prescriptions AS p
CROSS JOIN drugs AS d
WHERE p.external_reference = 'RX-INTERACTION-001'
  AND d.brand_name = 'WarfarinSafe';

DO $$
BEGIN
    BEGIN
        INSERT INTO prescription_items (
            prescription_id, drug_id, quantity_requested
        )
        SELECT p.prescription_id, d.drug_id, 5
        FROM prescriptions AS p
        CROSS JOIN drugs AS d
        WHERE p.external_reference = 'RX-INTERACTION-001'
          AND d.brand_name = 'AspirinCare';

        RAISE EXCEPTION 'TEST FAILED: Warfarin and Aspirin insert was accepted';
    EXCEPTION
        WHEN check_violation THEN
            IF SQLERRM NOT LIKE 'Drug interaction blocked%' THEN
                RAISE;
            END IF;
    END;
END;
$$;

SELECT pg_temp.assert_true(
    (SELECT COUNT(*) = 1
     FROM prescription_items AS pi
     JOIN prescriptions AS p USING (prescription_id)
     WHERE p.external_reference = 'RX-INTERACTION-001'),
    'blocked interaction must not leave a second item behind'
);

\echo 'TC-R2-03: atomic cross-branch transfer and rollback'

SELECT transfer_stock(
    (SELECT batch_id FROM batches WHERE batch_number = 'AMOXI-001'
     AND branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL')),
    (SELECT branch_id FROM branches WHERE branch_code = 'NORTH'),
    20,
    'inventory-manager-01',
    '30000000-0000-0000-0000-000000000001'
);

SELECT pg_temp.assert_true(
    (SELECT quantity_on_hand = 30
     FROM batches
     WHERE batch_number = 'AMOXI-001'
       AND branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL')),
    'source branch must be debited by 20'
);

SELECT pg_temp.assert_true(
    (SELECT quantity_on_hand = 20
     FROM batches
     WHERE batch_number = 'AMOXI-001'
       AND branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'NORTH')),
    'destination branch must be credited by 20'
);

SELECT pg_temp.assert_true(
    (SELECT SUM(quantity_on_hand) = 50
     FROM batches
     WHERE batch_number = 'AMOXI-001'),
    'successful transfer must preserve total stock'
);

DO $$
DECLARE
    v_transfer_count BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_transfer_count FROM transfers;

    BEGIN
        PERFORM transfer_stock(
            (SELECT batch_id FROM batches
             WHERE batch_number = 'AMOXI-001'
               AND branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL')),
            (SELECT branch_id FROM branches WHERE branch_code = 'NORTH'),
            1000,
            'inventory-manager-01',
            '30000000-0000-0000-0000-000000000002'
        );
        RAISE EXCEPTION 'TEST FAILED: over-transfer was accepted';
    EXCEPTION
        WHEN check_violation THEN NULL;
    END;

    PERFORM pg_temp.assert_true(
        (SELECT COUNT(*) = v_transfer_count FROM transfers),
        'failed transfer must not write a transfer header'
    );
    PERFORM pg_temp.assert_true(
        (SELECT SUM(quantity_on_hand) = 50 FROM batches WHERE batch_number = 'AMOXI-001'),
        'failed transfer must preserve total stock'
    );
END;
$$;

\echo 'TC-R2-04: mandatory rolling 14-day reorder forecast'

REFRESH MATERIALIZED VIEW mv_daily_demand;

SELECT pg_temp.assert_true(
    (SELECT average_14_day_demand = 10.0000
     FROM v_reorder_recommendations
     WHERE branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL')
       AND drug_id = (SELECT drug_id FROM drugs WHERE brand_name = 'AspirinCare')),
    '14-day average for AspirinCare must equal 10 units/day'
);

SELECT pg_temp.assert_true(
    (SELECT reorder_point = 36 AND suggested_reorder_quantity = 26
     FROM v_reorder_recommendations
     WHERE branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL')
       AND drug_id = (SELECT drug_id FROM drugs WHERE brand_name = 'AspirinCare')),
    'forecast must produce reorder point 36 and suggested quantity 26'
);

CALL refresh_reorder_alerts(
    :central_branch_id
);

SELECT pg_temp.assert_true(
    (SELECT suggested_quantity = 26 AND status = 'OPEN'
     FROM reorder_alerts
     WHERE branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL')
       AND drug_id = (SELECT drug_id FROM drugs WHERE brand_name = 'AspirinCare')),
    'forecast must create an open reorder alert'
);

\echo 'TC-R2-05: in-stock substitute selection and shared FEFO deduction'

CALL adjust_stock(
    :para_late_batch_id,
    -80,
    'COUNT_CORRECTION',
    'inventory-manager-01',
    '50000000-0000-0000-0000-000000000001'
);

SELECT pg_temp.assert_true(
    COALESCE((
        SELECT available_units = 0
        FROM v_available_stock
        WHERE branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL')
          AND drug_id = (SELECT drug_id FROM drugs WHERE brand_name = 'ParaPrime')
    ), TRUE),
    'requested drug must have no sellable stock'
);

SELECT pg_temp.assert_true(
    (SELECT COUNT(*) = 1
     FROM find_substitutes(
         (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL'),
         (SELECT drug_id FROM drugs WHERE brand_name = 'ParaPrime'),
         10,
         0
     )
     WHERE candidate_drug_id = (SELECT drug_id FROM drugs WHERE brand_name = 'ParaValue')),
    'in-stock equivalent must be suggested'
);

INSERT INTO prescriptions (
    branch_id, external_reference, patient_reference, created_by
)
SELECT branch_id, 'RX-SUBSTITUTE-001', 'PATIENT-DEMO-03', 'test-suite'
FROM branches WHERE branch_code = 'CENTRAL'
RETURNING prescription_id \gset sub_

INSERT INTO prescription_items (
    prescription_id, drug_id, quantity_requested
)
SELECT :sub_prescription_id, drug_id, 10
FROM drugs WHERE brand_name = 'ParaPrime'
RETURNING prescription_item_id \gset sub_

CALL record_substitution_and_dispense(
    :sub_prescription_item_id,
    :para_value_drug_id,
    'pharmacist-01',
    'OUT_OF_STOCK_APPROVED',
    '50000000-0000-0000-0000-000000000002',
    0
);

SELECT pg_temp.assert_true(
    (SELECT quantity_on_hand = 190 FROM batches WHERE batch_number = 'PARAVALUE-001'),
    'substitute dispense must use the central inventory movement path'
);

SELECT pg_temp.assert_true(
    (SELECT COUNT(*) = 1
     FROM substitution_audit_logs
     WHERE prescription_item_id = :sub_prescription_item_id),
    'approved substitution must be audited'
);

DO $$
BEGIN
    BEGIN
        PERFORM *
        FROM find_substitutes(
            (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL'),
            (SELECT drug_id FROM drugs WHERE brand_name = 'WarfarinSafe'),
            1,
            0
        );
        RAISE EXCEPTION 'TEST FAILED: NTI substitution search was accepted';
    EXCEPTION
        WHEN check_violation THEN
            IF SQLERRM NOT LIKE 'Substitution blocked for narrow therapeutic index drug%' THEN
                RAISE;
            END IF;
    END;
END;
$$;

\echo 'TC-R2-06: idempotent draft purchase-order generation'

SELECT *
FROM generate_draft_purchase_orders(
    (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL'),
    'procurement-manager-01'
);

SELECT pg_temp.assert_true(
    (SELECT COUNT(*) = 1
     FROM purchase_orders
     WHERE branch_id = (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL')
       AND status = 'DRAFT'),
    'one draft PO must be created for the selected supplier'
);

SELECT pg_temp.assert_true(
    (SELECT item.quantity_ordered = 50
     FROM purchase_order_items AS item
     JOIN purchase_orders AS po USING (po_id)
     JOIN drugs AS d USING (drug_id)
     WHERE po.status = 'DRAFT' AND d.brand_name = 'AspirinCare'),
    'draft PO must honor the supplier minimum order quantity of 50'
);

SELECT pg_temp.assert_true(
    (SELECT status = 'DRAFTED' AND linked_po_id IS NOT NULL
     FROM reorder_alerts
     WHERE drug_id = (SELECT drug_id FROM drugs WHERE brand_name = 'AspirinCare')),
    'drafted alert must link to its purchase order'
);

SELECT pg_temp.assert_true(
    (SELECT COUNT(*) = 0
     FROM generate_draft_purchase_orders(
         (SELECT branch_id FROM branches WHERE branch_code = 'CENTRAL'),
         'procurement-manager-01'
     )),
    'a repeated generation call must create no duplicate order'
);

\echo 'All Review 2 database tests passed.'

ROLLBACK;
