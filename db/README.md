# PharmaChain database

This directory contains the PostgreSQL 17 schema, demo data, and tests for PharmaChain.

The browser prototype that uses this database is documented in [../prototype/README.md](../prototype/README.md).

## Requirements

- PostgreSQL 17
- `psql`
- A new or otherwise disposable database for the demo seed and tests

No PostgreSQL extensions or third-party test frameworks are required.

## Files

- `migrations/001_schema.sql`: canonical tables, types, constraints, and indexes
- `migrations/002_database_logic.sql`: triggers, procedures, functions, views, and the demand materialized view
- `seeds/review2_demo.sql`: deterministic demonstration data using dates relative to the execution date
- `tests/review2_tests.sql`: self-contained assertions that run in a transaction and roll back

## Apply to an empty database

```bash
psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f db/migrations/001_schema.sql

psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f db/migrations/002_database_logic.sql

psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f db/seeds/review2_demo.sql
```

Run the verification suite:

```bash
psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f db/tests/review2_tests.sql
```

The test script verifies:

1. Multi-batch FEFO dispensing and expired-batch rejection, including a raw-SQL bypass attempt.
2. Warfarin and Aspirin interaction blocking.
3. Atomic cross-branch transfer, total-stock preservation, and rollback on insufficient stock.
4. A zero-filled rolling 14-day forecast and reorder alert.
5. In-stock substitution, NTI blocking, shared inventory deduction, and substitution audit logging.
6. Supplier minimum-order handling and idempotent draft purchase-order generation.

## Operational model

- `batches.quantity_on_hand` is the current cached balance.
- Every stock change is represented by an append-only `inventory_movements` row.
- `dispense_prescription_item()` locks eligible batch rows in expiry order and may allocate one item across several batches.
- `dispense_allocations` is the detailed consumption ledger. A trigger maintains the mandatory `daily_dispense_log` aggregate in the same transaction.
- `transfer_stock()` posts paired transfer movements and the transfer log atomically.
- `record_substitution_and_dispense()` records the pharmacist's decision and calls the same FEFO routine used for normal dispensing.
- `mv_daily_demand` must be refreshed before reading `v_reorder_recommendations` after new historical data is loaded.

## Production permissions

The migration owner can necessarily alter tables and disable triggers. A production deployment should use a separate runtime role that has:

- `USAGE` on the `pharmachain` schema;
- `SELECT` on approved tables and views;
- `EXECUTE` on the public procedures and functions it needs;
- no direct `UPDATE` privilege on `batches`;
- no direct write privilege on append-only ledgers.

Authentication roles and deployment-specific grants are intentionally outside the database-only Review 2 milestone.
