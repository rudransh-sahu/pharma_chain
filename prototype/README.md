# PharmaChain browser prototype

This local prototype provides a browser dashboard for the PostgreSQL database. It uses Node.js built-ins and the PostgreSQL `psql` command-line client. No npm packages or external services are needed.

## Requirements

- Node.js 20 or newer
- PostgreSQL 17 running locally
- PostgreSQL command-line tools (`psql`, `createdb`)

## Create demo database

Start PostgreSQL, then run from the repository root:

```bash
brew services start postgresql@17
npm run db:setup
```

Setup creates a new `pharma_chain` database, applies both migrations, loads demo rows, and refreshes the demand view. It refuses to reuse or overwrite an existing database. To create a separate database instead, run:

```bash
PGDATABASE=pharmachain_demo npm run db:setup
```

For a PostgreSQL server using a non-default host, port, or username, set the standard `PGHOST`, `PGPORT`, and `PGUSER` variables before running setup and the prototype.

## Start the app

From the repository root:

```bash
npm start
```

Open [http://localhost:4173](http://localhost:4173). Stop the server with `Ctrl+C`.

The dashboard supports branch inventory, 14-day reorder forecasts, FEFO dispensing, interaction checks, substitute lookup, cross-branch stock transfer, and draft purchase order generation. Successful operations write to the selected local database. PostgreSQL owns the validation and transaction rules.

## Check the database

In another Terminal window:

```bash
psql -X -d pharma_chain
```

Useful queries:

```sql
SET search_path = pharmachain, public;
SELECT * FROM v_available_stock ORDER BY branch_id, drug_id;
SELECT * FROM v_reorder_recommendations ORDER BY branch_id, drug_id;
SELECT * FROM inventory_movements ORDER BY movement_id DESC LIMIT 20;
SELECT * FROM substitution_audit_logs ORDER BY audit_id DESC;
SELECT * FROM transfers ORDER BY transfer_id DESC;
SELECT * FROM purchase_orders ORDER BY po_id DESC;
```

## Prototype boundary

This is a local academic prototype. It does not provide sign-in, role separation, production deployment, or a patient record system. Use the seeded demo records only.
