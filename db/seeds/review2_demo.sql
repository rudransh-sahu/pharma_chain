BEGIN;

SET search_path = pharmachain, public;

INSERT INTO branches (branch_code, branch_name, address)
VALUES
    ('CENTRAL', 'Central Pharmacy', 'Vellore'),
    ('NORTH', 'North Pharmacy', 'Vellore');

INSERT INTO ingredients (
    generic_name, atc_code, therapeutic_class, is_narrow_therapeutic_index
)
VALUES
    ('Paracetamol', 'N02BE01', 'Analgesic and antipyretic', FALSE),
    ('Warfarin', 'B01AA03', 'Anticoagulant', TRUE),
    ('Aspirin', 'B01AC06', 'Antiplatelet', FALSE),
    ('Amoxicillin', 'J01CA04', 'Antibiotic', FALSE);

INSERT INTO drugs (
    ingredient_id, brand_name, dosage_form, strength_mg,
    unit_price, is_prescription_only, manufacturer
)
SELECT ingredient_id, 'ParaPrime', 'TABLET', 500, 2.50, FALSE, 'Demo Pharma'
FROM ingredients WHERE generic_name = 'Paracetamol'
UNION ALL
SELECT ingredient_id, 'ParaValue', 'TABLET', 500, 1.75, FALSE, 'Value Labs'
FROM ingredients WHERE generic_name = 'Paracetamol'
UNION ALL
SELECT ingredient_id, 'WarfarinSafe', 'TABLET', 5, 8.00, TRUE, 'Clinical Pharma'
FROM ingredients WHERE generic_name = 'Warfarin'
UNION ALL
SELECT ingredient_id, 'AspirinCare', 'TABLET', 75, 3.00, TRUE, 'Clinical Pharma'
FROM ingredients WHERE generic_name = 'Aspirin'
UNION ALL
SELECT ingredient_id, 'AmoxiCare', 'CAPSULE', 500, 12.00, TRUE, 'Antibiotic Labs'
FROM ingredients WHERE generic_name = 'Amoxicillin';

INSERT INTO drug_interactions (drug_a_id, drug_b_id, severity, description)
SELECT
    LEAST(w.drug_id, a.drug_id),
    GREATEST(w.drug_id, a.drug_id),
    'MAJOR',
    'Concurrent use can substantially increase bleeding risk.'
FROM drugs AS w
CROSS JOIN drugs AS a
WHERE w.brand_name = 'WarfarinSafe'
  AND a.brand_name = 'AspirinCare';

INSERT INTO suppliers (
    supplier_name, license_no, contact_person, email, phone, reliability_score
)
VALUES
    ('MedSource Distributors', 'SUP-LIC-001', 'Asha Rao', 'orders@medsource.example',
     '+91-9000000001', 0.970),
    ('Value Pharma Supply', 'SUP-LIC-002', 'Ravi Shah', 'orders@valuepharma.example',
     '+91-9000000002', 0.940);

INSERT INTO supplier_drugs (
    supplier_id, drug_id, lead_time_days, unit_cost, minimum_order_quantity
)
SELECT s.supplier_id, d.drug_id,
       CASE d.brand_name WHEN 'AspirinCare' THEN 3 ELSE 4 END,
       CASE d.brand_name
           WHEN 'ParaPrime' THEN 1.20
           WHEN 'ParaValue' THEN 0.85
           WHEN 'WarfarinSafe' THEN 5.50
           WHEN 'AspirinCare' THEN 1.40
           ELSE 8.00
       END,
       CASE d.brand_name WHEN 'AspirinCare' THEN 50 ELSE 10 END
FROM suppliers AS s
CROSS JOIN drugs AS d
WHERE s.supplier_name = 'MedSource Distributors';

INSERT INTO supplier_drugs (
    supplier_id, drug_id, lead_time_days, unit_cost, minimum_order_quantity
)
SELECT s.supplier_id, d.drug_id, 6,
       CASE d.brand_name
           WHEN 'ParaPrime' THEN 1.10
           WHEN 'ParaValue' THEN 0.80
           WHEN 'WarfarinSafe' THEN 5.25
           WHEN 'AspirinCare' THEN 1.30
           ELSE 7.75
       END,
       20
FROM suppliers AS s
CROSS JOIN drugs AS d
WHERE s.supplier_name = 'Value Pharma Supply';

INSERT INTO branch_drug_policies (
    branch_id, drug_id, preferred_supplier_id,
    safety_stock_days, review_period_days, forecast_min_shelf_days
)
SELECT b.branch_id, d.drug_id, s.supplier_id, 7, 14, 30
FROM branches AS b
CROSS JOIN drugs AS d
CROSS JOIN suppliers AS s
WHERE b.branch_code IN ('CENTRAL', 'NORTH')
  AND s.supplier_name = 'MedSource Distributors';

INSERT INTO substitutes (
    source_drug_id, target_drug_id, preference_priority, clinical_rationale
)
SELECT source.drug_id, target.drug_id, 1,
       'Same active ingredient, dosage form, and strength; pharmacist approval required.'
FROM drugs AS source
CROSS JOIN drugs AS target
WHERE source.brand_name = 'ParaPrime'
  AND target.brand_name = 'ParaValue';

WITH new_batch AS (
    INSERT INTO batches (
        branch_id, drug_id, supplier_id, batch_number,
        unit_cost, manufactured_on, expires_on, received_at
    )
    SELECT b.branch_id, d.drug_id, s.supplier_id, 'PARA-EXPIRED',
           1.20, CURRENT_DATE - 400, CURRENT_DATE - 1,
           clock_timestamp() - INTERVAL '200 days'
    FROM branches AS b, drugs AS d, suppliers AS s
    WHERE b.branch_code = 'CENTRAL'
      AND d.brand_name = 'ParaPrime'
      AND s.supplier_name = 'MedSource Distributors'
    RETURNING batch_id
)
INSERT INTO inventory_movements (
    transaction_uuid, batch_id, movement_type, quantity_delta,
    reference_type, actor_id, occurred_at
)
SELECT '00000000-0000-0000-0000-000000000001', batch_id,
       'OPENING_BALANCE', 20, 'DEMO_SEED', 'seed',
       clock_timestamp() - INTERVAL '200 days'
FROM new_batch;

WITH new_batch AS (
    INSERT INTO batches (
        branch_id, drug_id, supplier_id, batch_number,
        unit_cost, manufactured_on, expires_on
    )
    SELECT b.branch_id, d.drug_id, s.supplier_id, 'PARA-SOON',
           1.20, CURRENT_DATE - 300, CURRENT_DATE + 30
    FROM branches AS b, drugs AS d, suppliers AS s
    WHERE b.branch_code = 'CENTRAL'
      AND d.brand_name = 'ParaPrime'
      AND s.supplier_name = 'MedSource Distributors'
    RETURNING batch_id
)
INSERT INTO inventory_movements (
    transaction_uuid, batch_id, movement_type, quantity_delta,
    reference_type, actor_id
)
SELECT '00000000-0000-0000-0000-000000000002', batch_id,
       'OPENING_BALANCE', 30, 'DEMO_SEED', 'seed'
FROM new_batch;

WITH new_batch AS (
    INSERT INTO batches (
        branch_id, drug_id, supplier_id, batch_number,
        unit_cost, manufactured_on, expires_on
    )
    SELECT b.branch_id, d.drug_id, s.supplier_id, 'PARA-LATE',
           1.20, CURRENT_DATE - 100, CURRENT_DATE + 180
    FROM branches AS b, drugs AS d, suppliers AS s
    WHERE b.branch_code = 'CENTRAL'
      AND d.brand_name = 'ParaPrime'
      AND s.supplier_name = 'MedSource Distributors'
    RETURNING batch_id
)
INSERT INTO inventory_movements (
    transaction_uuid, batch_id, movement_type, quantity_delta,
    reference_type, actor_id
)
SELECT '00000000-0000-0000-0000-000000000003', batch_id,
       'OPENING_BALANCE', 100, 'DEMO_SEED', 'seed'
FROM new_batch;

WITH new_batch AS (
    INSERT INTO batches (
        branch_id, drug_id, supplier_id, batch_number,
        unit_cost, manufactured_on, expires_on
    )
    SELECT b.branch_id, d.drug_id, s.supplier_id, 'PARAVALUE-001',
           0.85, CURRENT_DATE - 100, CURRENT_DATE + 180
    FROM branches AS b, drugs AS d, suppliers AS s
    WHERE b.branch_code = 'CENTRAL'
      AND d.brand_name = 'ParaValue'
      AND s.supplier_name = 'MedSource Distributors'
    RETURNING batch_id
)
INSERT INTO inventory_movements (
    transaction_uuid, batch_id, movement_type, quantity_delta,
    reference_type, actor_id
)
SELECT '00000000-0000-0000-0000-000000000004', batch_id,
       'OPENING_BALANCE', 200, 'DEMO_SEED', 'seed'
FROM new_batch;

WITH new_batch AS (
    INSERT INTO batches (
        branch_id, drug_id, supplier_id, batch_number,
        unit_cost, manufactured_on, expires_on
    )
    SELECT b.branch_id, d.drug_id, s.supplier_id, 'AMOXI-001',
           8.00, CURRENT_DATE - 60, CURRENT_DATE + 365
    FROM branches AS b, drugs AS d, suppliers AS s
    WHERE b.branch_code = 'CENTRAL'
      AND d.brand_name = 'AmoxiCare'
      AND s.supplier_name = 'MedSource Distributors'
    RETURNING batch_id
)
INSERT INTO inventory_movements (
    transaction_uuid, batch_id, movement_type, quantity_delta,
    reference_type, actor_id
)
SELECT '00000000-0000-0000-0000-000000000005', batch_id,
       'OPENING_BALANCE', 50, 'DEMO_SEED', 'seed'
FROM new_batch;

WITH drug_batches AS (
    INSERT INTO batches (
        branch_id, drug_id, supplier_id, batch_number,
        unit_cost, manufactured_on, expires_on
    )
    SELECT b.branch_id, d.drug_id, s.supplier_id,
           CASE d.brand_name
               WHEN 'WarfarinSafe' THEN 'WARF-001'
               ELSE 'ASPR-001'
           END,
           CASE d.brand_name WHEN 'WarfarinSafe' THEN 5.50 ELSE 1.40 END,
           CURRENT_DATE - 60,
           CURRENT_DATE + 365
    FROM branches AS b
    CROSS JOIN drugs AS d
    CROSS JOIN suppliers AS s
    WHERE b.branch_code = 'CENTRAL'
      AND d.brand_name IN ('WarfarinSafe', 'AspirinCare')
      AND s.supplier_name = 'MedSource Distributors'
    RETURNING batch_id, drug_id
)
INSERT INTO inventory_movements (
    transaction_uuid, batch_id, movement_type, quantity_delta,
    reference_type, actor_id
)
SELECT
    CASE d.brand_name
        WHEN 'WarfarinSafe' THEN '00000000-0000-0000-0000-000000000006'::UUID
        ELSE '00000000-0000-0000-0000-000000000007'::UUID
    END,
    db.batch_id,
    'OPENING_BALANCE',
    CASE d.brand_name WHEN 'WarfarinSafe' THEN 40 ELSE 10 END,
    'DEMO_SEED',
    'seed'
FROM drug_batches AS db
JOIN drugs AS d USING (drug_id);

INSERT INTO daily_dispense_log (
    branch_id, drug_id, sale_date, quantity_dispensed
)
SELECT b.branch_id, d.drug_id, CURRENT_DATE - generated.days_ago, 10
FROM branches AS b
CROSS JOIN drugs AS d
CROSS JOIN generate_series(0, 13) AS generated(days_ago)
WHERE b.branch_code = 'CENTRAL'
  AND d.brand_name = 'AspirinCare';

REFRESH MATERIALIZED VIEW mv_daily_demand;

COMMIT;
