BEGIN;

CREATE SCHEMA IF NOT EXISTS pharmachain;
SET search_path = pharmachain, public;

CREATE TYPE prescription_status AS ENUM (
    'DRAFT',
    'READY',
    'PARTIALLY_DISPENSED',
    'DISPENSED',
    'CANCELLED'
);

CREATE TYPE prescription_item_status AS ENUM (
    'PENDING',
    'DISPENSED',
    'CANCELLED'
);

CREATE TYPE interaction_severity AS ENUM (
    'MINOR',
    'MODERATE',
    'MAJOR',
    'CONTRAINDICATED'
);

CREATE TYPE inventory_movement_type AS ENUM (
    'OPENING_BALANCE',
    'RECEIPT',
    'DISPENSE',
    'TRANSFER_OUT',
    'TRANSFER_IN',
    'ADJUSTMENT',
    'CUSTOMER_RETURN',
    'WRITE_OFF'
);

CREATE TYPE stock_adjustment_reason AS ENUM (
    'DAMAGE',
    'EXPIRY_WRITE_OFF',
    'COUNT_CORRECTION',
    'RECALL_RETURN',
    'CUSTOMER_RETURN'
);

CREATE TYPE reorder_alert_status AS ENUM (
    'OPEN',
    'DRAFTED',
    'DISMISSED',
    'RESOLVED'
);

CREATE TYPE po_status AS ENUM (
    'DRAFT',
    'APPROVED',
    'ORDERED',
    'PARTIALLY_RECEIVED',
    'RECEIVED',
    'CANCELLED'
);

CREATE TABLE branches (
    branch_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_code VARCHAR(30) NOT NULL UNIQUE,
    branch_name VARCHAR(150) NOT NULL,
    address TEXT,
    time_zone TEXT NOT NULL DEFAULT 'Asia/Kolkata',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE ingredients (
    ingredient_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    generic_name VARCHAR(150) NOT NULL UNIQUE,
    chemical_formula VARCHAR(100),
    atc_code VARCHAR(10) UNIQUE,
    therapeutic_class VARCHAR(100) NOT NULL,
    is_narrow_therapeutic_index BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE drugs (
    drug_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ingredient_id BIGINT NOT NULL REFERENCES ingredients(ingredient_id) ON DELETE RESTRICT,
    brand_name VARCHAR(150) NOT NULL,
    dosage_form VARCHAR(50) NOT NULL,
    strength_mg NUMERIC(10, 3) NOT NULL CHECK (strength_mg > 0),
    unit_price NUMERIC(12, 2) NOT NULL CHECK (unit_price > 0),
    is_prescription_only BOOLEAN NOT NULL DEFAULT TRUE,
    manufacturer VARCHAR(150) NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_drug_formulation
        UNIQUE (ingredient_id, brand_name, dosage_form, strength_mg, manufacturer)
);

CREATE INDEX idx_drugs_ingredient_form
    ON drugs (ingredient_id, dosage_form, strength_mg)
    WHERE is_active;

CREATE TABLE drug_interactions (
    interaction_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    drug_a_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    drug_b_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    severity interaction_severity NOT NULL,
    description TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_interaction_pair_order CHECK (drug_a_id < drug_b_id),
    CONSTRAINT uq_drug_interaction_pair UNIQUE (drug_a_id, drug_b_id)
);

CREATE TABLE suppliers (
    supplier_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_name VARCHAR(150) NOT NULL UNIQUE,
    license_no VARCHAR(50) NOT NULL UNIQUE,
    contact_person VARCHAR(100),
    email VARCHAR(150),
    phone VARCHAR(30),
    address TEXT,
    reliability_score NUMERIC(4, 3) NOT NULL DEFAULT 0.950
        CHECK (reliability_score BETWEEN 0 AND 1),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_supplier_email
        CHECK (email IS NULL OR email ~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$')
);

CREATE TABLE supplier_drugs (
    supplier_id BIGINT NOT NULL REFERENCES suppliers(supplier_id) ON DELETE CASCADE,
    drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    lead_time_days INTEGER NOT NULL CHECK (lead_time_days BETWEEN 1 AND 180),
    unit_cost NUMERIC(12, 2) NOT NULL CHECK (unit_cost > 0),
    minimum_order_quantity INTEGER NOT NULL DEFAULT 1 CHECK (minimum_order_quantity > 0),
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (supplier_id, drug_id)
);

CREATE INDEX idx_supplier_drugs_selection
    ON supplier_drugs (drug_id, lead_time_days, unit_cost)
    WHERE is_active;

CREATE TABLE branch_drug_policies (
    branch_id BIGINT NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE CASCADE,
    preferred_supplier_id BIGINT,
    safety_stock_days INTEGER NOT NULL DEFAULT 7 CHECK (safety_stock_days >= 0),
    review_period_days INTEGER NOT NULL DEFAULT 14 CHECK (review_period_days > 0),
    forecast_min_shelf_days INTEGER NOT NULL DEFAULT 30 CHECK (forecast_min_shelf_days >= 0),
    PRIMARY KEY (branch_id, drug_id),
    CONSTRAINT fk_policy_supplier_drug
        FOREIGN KEY (preferred_supplier_id, drug_id)
        REFERENCES supplier_drugs (supplier_id, drug_id)
        ON DELETE RESTRICT
);

CREATE TABLE purchase_orders (
    po_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_number VARCHAR(30) NOT NULL UNIQUE,
    branch_id BIGINT NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    supplier_id BIGINT NOT NULL REFERENCES suppliers(supplier_id) ON DELETE RESTRICT,
    status po_status NOT NULL DEFAULT 'DRAFT',
    total_amount NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    created_by VARCHAR(100) NOT NULL,
    approved_by VARCHAR(100),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    approved_at TIMESTAMPTZ,
    ordered_at TIMESTAMPTZ,
    expected_delivery DATE,
    received_at TIMESTAMPTZ,
    CONSTRAINT chk_po_segregation
        CHECK (approved_by IS NULL OR approved_by <> created_by)
);

CREATE UNIQUE INDEX uq_open_draft_po_per_supplier
    ON purchase_orders (branch_id, supplier_id)
    WHERE status = 'DRAFT';

CREATE TABLE purchase_order_items (
    po_item_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_id BIGINT NOT NULL REFERENCES purchase_orders(po_id) ON DELETE CASCADE,
    drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    quantity_ordered INTEGER NOT NULL CHECK (quantity_ordered > 0),
    quantity_received INTEGER NOT NULL DEFAULT 0,
    unit_cost NUMERIC(12, 2) NOT NULL CHECK (unit_cost > 0),
    line_total NUMERIC(14, 2)
        GENERATED ALWAYS AS (quantity_ordered * unit_cost) STORED,
    CONSTRAINT uq_po_drug UNIQUE (po_id, drug_id),
    CONSTRAINT chk_po_item_received
        CHECK (quantity_received BETWEEN 0 AND quantity_ordered)
);

CREATE INDEX idx_purchase_order_items_po ON purchase_order_items (po_id);

CREATE TABLE po_status_history (
    history_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_id BIGINT NOT NULL REFERENCES purchase_orders(po_id) ON DELETE RESTRICT,
    old_status po_status,
    new_status po_status NOT NULL,
    changed_by VARCHAR(100) NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE batches (
    batch_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id BIGINT NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    supplier_id BIGINT NOT NULL REFERENCES suppliers(supplier_id) ON DELETE RESTRICT,
    po_item_id BIGINT REFERENCES purchase_order_items(po_item_id) ON DELETE RESTRICT,
    batch_number VARCHAR(50) NOT NULL,
    quantity_on_hand INTEGER NOT NULL DEFAULT 0 CHECK (quantity_on_hand >= 0),
    quantity_reserved INTEGER NOT NULL DEFAULT 0 CHECK (quantity_reserved >= 0),
    unit_cost NUMERIC(12, 2) NOT NULL CHECK (unit_cost >= 0),
    manufactured_on DATE NOT NULL,
    expires_on DATE NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    is_recalled BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_batch_dates CHECK (expires_on > manufactured_on),
    CONSTRAINT chk_batch_reservation CHECK (quantity_reserved <= quantity_on_hand),
    CONSTRAINT uq_branch_batch
        UNIQUE (branch_id, drug_id, supplier_id, batch_number)
);

CREATE INDEX idx_batch_available
    ON batches (branch_id, drug_id, expires_on, batch_id)
    INCLUDE (quantity_on_hand, quantity_reserved)
    WHERE quantity_on_hand > 0 AND NOT is_recalled;

CREATE INDEX idx_batch_expiry
    ON batches (branch_id, expires_on)
    WHERE quantity_on_hand > 0;

CREATE TABLE inventory_movements (
    movement_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_uuid UUID NOT NULL,
    batch_id BIGINT NOT NULL REFERENCES batches(batch_id) ON DELETE RESTRICT,
    movement_type inventory_movement_type NOT NULL,
    quantity_delta INTEGER NOT NULL CHECK (quantity_delta <> 0),
    reference_type VARCHAR(40) NOT NULL,
    reference_id BIGINT,
    actor_id VARCHAR(100) NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_movement_direction CHECK (
        (movement_type IN ('OPENING_BALANCE', 'RECEIPT', 'TRANSFER_IN', 'CUSTOMER_RETURN')
            AND quantity_delta > 0)
        OR (movement_type IN ('DISPENSE', 'TRANSFER_OUT', 'WRITE_OFF')
            AND quantity_delta < 0)
        OR movement_type = 'ADJUSTMENT'
    )
);

CREATE INDEX idx_inventory_movements_batch_time
    ON inventory_movements (batch_id, occurred_at, movement_id);

CREATE TABLE stock_adjustments (
    adjustment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id BIGINT NOT NULL REFERENCES batches(batch_id) ON DELETE RESTRICT,
    movement_id BIGINT NOT NULL UNIQUE REFERENCES inventory_movements(movement_id) ON DELETE RESTRICT,
    quantity_delta INTEGER NOT NULL CHECK (quantity_delta <> 0),
    reason stock_adjustment_reason NOT NULL,
    stock_before INTEGER NOT NULL CHECK (stock_before >= 0),
    stock_after INTEGER NOT NULL CHECK (stock_after >= 0),
    adjusted_by VARCHAR(100) NOT NULL,
    adjusted_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE prescriptions (
    prescription_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id BIGINT NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    external_reference VARCHAR(100),
    patient_reference VARCHAR(100) NOT NULL,
    prescriber_reference VARCHAR(100),
    status prescription_status NOT NULL DEFAULT 'DRAFT',
    created_by VARCHAR(100) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_prescription_external_reference
        UNIQUE NULLS NOT DISTINCT (branch_id, external_reference)
);

CREATE TABLE prescription_items (
    prescription_item_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    prescription_id BIGINT NOT NULL REFERENCES prescriptions(prescription_id) ON DELETE CASCADE,
    drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    quantity_requested INTEGER NOT NULL CHECK (quantity_requested > 0),
    status prescription_item_status NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_prescription_drug UNIQUE (prescription_id, drug_id)
);

CREATE TABLE dispense_allocations (
    allocation_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_uuid UUID NOT NULL,
    prescription_item_id BIGINT NOT NULL
        REFERENCES prescription_items(prescription_item_id) ON DELETE RESTRICT,
    batch_id BIGINT NOT NULL REFERENCES batches(batch_id) ON DELETE RESTRICT,
    quantity_dispensed INTEGER NOT NULL CHECK (quantity_dispensed > 0),
    dispensed_by VARCHAR(100) NOT NULL,
    dispensed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT uq_dispense_allocation
        UNIQUE (transaction_uuid, prescription_item_id, batch_id)
);

CREATE INDEX idx_dispense_item ON dispense_allocations (prescription_item_id);
CREATE INDEX idx_dispense_batch_time ON dispense_allocations (batch_id, dispensed_at);

CREATE TABLE daily_dispense_log (
    branch_id BIGINT NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    sale_date DATE NOT NULL,
    quantity_dispensed BIGINT NOT NULL CHECK (quantity_dispensed >= 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (branch_id, drug_id, sale_date)
);

CREATE TABLE transfers (
    transfer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transfer_uuid UUID NOT NULL UNIQUE,
    source_branch_id BIGINT NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    destination_branch_id BIGINT NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    transferred_by VARCHAR(100) NOT NULL,
    transferred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT chk_distinct_transfer_branches
        CHECK (source_branch_id <> destination_branch_id)
);

CREATE TABLE transfer_items (
    transfer_item_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transfer_id BIGINT NOT NULL REFERENCES transfers(transfer_id) ON DELETE RESTRICT,
    source_batch_id BIGINT NOT NULL REFERENCES batches(batch_id) ON DELETE RESTRICT,
    destination_batch_id BIGINT NOT NULL REFERENCES batches(batch_id) ON DELETE RESTRICT,
    drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    quantity_transferred INTEGER NOT NULL CHECK (quantity_transferred > 0),
    CONSTRAINT chk_distinct_transfer_batches
        CHECK (source_batch_id <> destination_batch_id)
);

CREATE TABLE substitutes (
    substitute_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE CASCADE,
    target_drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE CASCADE,
    preference_priority INTEGER NOT NULL CHECK (preference_priority BETWEEN 1 AND 10),
    clinical_rationale TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT chk_no_self_substitute CHECK (source_drug_id <> target_drug_id),
    CONSTRAINT uq_substitute_pair UNIQUE (source_drug_id, target_drug_id)
);

CREATE INDEX idx_substitute_lookup
    ON substitutes (source_drug_id, preference_priority)
    WHERE is_active;

CREATE TABLE substitution_audit_logs (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_uuid UUID NOT NULL,
    prescription_item_id BIGINT NOT NULL
        REFERENCES prescription_items(prescription_item_id) ON DELETE RESTRICT,
    original_drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    substituted_drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    quantity_dispensed INTEGER NOT NULL CHECK (quantity_dispensed > 0),
    pharmacist_id VARCHAR(100) NOT NULL,
    substitution_tier VARCHAR(25) NOT NULL
        CHECK (substitution_tier IN ('TIER_1_EXPLICIT', 'TIER_2_INGREDIENT')),
    clinical_reason_code VARCHAR(50) NOT NULL,
    logged_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    record_hash CHAR(64)
);

CREATE TABLE reorder_alerts (
    alert_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    branch_id BIGINT NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    drug_id BIGINT NOT NULL REFERENCES drugs(drug_id) ON DELETE RESTRICT,
    forecast_date DATE NOT NULL,
    average_14_day_demand NUMERIC(14, 4) NOT NULL CHECK (average_14_day_demand >= 0),
    usable_stock BIGINT NOT NULL CHECK (usable_stock >= 0),
    stock_on_order BIGINT NOT NULL CHECK (stock_on_order >= 0),
    reorder_point INTEGER NOT NULL CHECK (reorder_point >= 0),
    suggested_quantity INTEGER NOT NULL CHECK (suggested_quantity > 0),
    status reorder_alert_status NOT NULL DEFAULT 'OPEN',
    linked_po_id BIGINT REFERENCES purchase_orders(po_id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE UNIQUE INDEX uq_open_reorder_alert
    ON reorder_alerts (branch_id, drug_id)
    WHERE status = 'OPEN';

CREATE INDEX idx_reorder_alert_status
    ON reorder_alerts (branch_id, status, created_at);

COMMIT;
