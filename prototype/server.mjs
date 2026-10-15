import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
const dbName = process.env.PGDATABASE || 'pharma_chain';
const psql = process.env.PSQL || 'psql';
const port = Number(process.env.PORT || 4173);
const indexHtml = await readFile(path.join(here, 'index.html'));

const literal = (value) => `'${String(value).replaceAll("'", "''")}'`;
const number = (value, label, min = 1) => {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < min) throw new Error(`${label} must be an integer of at least ${min}.`);
  return parsed;
};
const uuid = () => randomUUID();

function query(sql) {
  return new Promise((resolve, reject) => {
    const child = spawn(psql, ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', dbName, '-c', sql], { cwd: root });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk; });
    child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
    child.on('error', (error) => reject(new Error(`Could not start psql: ${error.message}`)));
    child.on('close', (code) => {
      if (code !== 0) return reject(new Error(stderr.trim() || `psql exited with code ${code}`));
      resolve(stdout.trim());
    });
  });
}

async function rows(sql) {
  const result = await query(`SELECT COALESCE(json_agg(row_to_json(q)), '[]'::json)::text FROM (${sql}) AS q`);
  return JSON.parse(result || '[]');
}

async function body(req) {
  let data = '';
  for await (const part of req) {
    data += part;
    if (data.length > 32_000) throw new Error('Request is too large.');
  }
  return data ? JSON.parse(data) : {};
}

function send(res, status, value) {
  const payload = JSON.stringify(value);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(payload),
    'cache-control': 'no-store',
  });
  res.end(payload);
}

const server = createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    if (req.method === 'GET' && url.pathname === '/') {
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
      res.end(indexHtml);
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/overview') {
      const branchId = number(url.searchParams.get('branch_id') || 1, 'Branch');
      const [branches, inventory, recommendations, suppliers] = await Promise.all([
        rows(`SELECT branch_id, branch_code, branch_name FROM pharmachain.branches WHERE is_active ORDER BY branch_name`),
        rows(`SELECT d.drug_id, d.brand_name, d.dosage_form, d.strength_mg, COALESCE(s.available_units, 0) AS available_units, s.next_expiry FROM pharmachain.drugs d LEFT JOIN pharmachain.v_available_stock s ON s.drug_id=d.drug_id AND s.branch_id=${branchId} WHERE d.is_active ORDER BY d.brand_name`),
        rows(`SELECT drug_id, brand_name, average_14_day_demand, usable_stock, stock_on_order, reorder_point, suggested_reorder_quantity, alert_status FROM pharmachain.v_reorder_recommendations WHERE branch_id=${branchId} ORDER BY CASE alert_status WHEN 'CRITICAL' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END, brand_name`),
        rows(`SELECT supplier_id, supplier_name FROM pharmachain.suppliers WHERE is_active ORDER BY supplier_name`),
      ]);
      send(res, 200, { branches, inventory, recommendations, suppliers, branchId });
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/batches') {
      const branchId = number(url.searchParams.get('branch_id') || 1, 'Branch');
      const drugId = number(url.searchParams.get('drug_id'), 'Drug');
      send(res, 200, await rows(`SELECT batch_id, batch_number, quantity_on_hand, quantity_reserved, expires_on, is_recalled FROM pharmachain.batches WHERE branch_id=${branchId} AND drug_id=${drugId} ORDER BY expires_on, batch_id`));
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/dispense') {
      const input = await body(req);
      const branchId = number(input.branchId, 'Branch');
      const drugId = number(input.drugId, 'Drug');
      const qty = number(input.quantity, 'Quantity');
      const days = number(input.minShelfDays ?? 0, 'Minimum shelf life', 0);
      const actor = literal((input.pharmacist || 'demo-pharmacist').slice(0, 100));
      const reference = literal(`PROTO-${uuid().slice(0, 12)}`);
      const transaction = literal(uuid());
      await query(`DO $do$ DECLARE v_rx BIGINT; v_item BIGINT; BEGIN
        INSERT INTO pharmachain.prescriptions(branch_id, external_reference, patient_reference, created_by)
        VALUES (${branchId}, ${reference}, 'DEMO-PATIENT', ${actor}) RETURNING prescription_id INTO v_rx;
        INSERT INTO pharmachain.prescription_items(prescription_id, drug_id, quantity_requested)
        VALUES (v_rx, ${drugId}, ${qty}) RETURNING prescription_item_id INTO v_item;
        CALL pharmachain.dispense_prescription_item(v_item, ${actor}, ${transaction}::UUID, ${days});
      END $do$;`);
      send(res, 200, { message: `Dispensed ${qty} unit${qty === 1 ? '' : 's'} using FEFO allocation.`, reference: reference.slice(1, -1) });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/prescriptions') {
      const input = await body(req);
      const branchId = number(input.branchId, 'Branch');
      if (!Array.isArray(input.drugIds) || input.drugIds.length < 2) throw new Error('Choose at least two drugs to check an interaction.');
      const ids = [...new Set(input.drugIds.map((x) => number(x, 'Drug')))];
      if (ids.length < 2) throw new Error('Choose two different drugs to check an interaction.');
      const actor = literal('prototype-check');
      const reference = literal(`INTERACTION-${uuid().slice(0, 10)}`);
      const inserts = ids.map((id) => `INSERT INTO pharmachain.prescription_items(prescription_id, drug_id, quantity_requested) VALUES (v_rx, ${id}, 1);`).join('\n');
      await query(`DO $do$ DECLARE v_rx BIGINT; BEGIN
        INSERT INTO pharmachain.prescriptions(branch_id, external_reference, patient_reference, created_by)
        VALUES (${branchId}, ${reference}, 'DEMO-PATIENT', ${actor}) RETURNING prescription_id INTO v_rx;
        ${inserts}
      END $do$;`);
      const result = await rows(`SELECT drug_a.brand_name AS drug_a, drug_b.brand_name AS drug_b, interaction.severity, interaction.description
        FROM pharmachain.drug_interactions interaction
        JOIN pharmachain.drugs drug_a ON drug_a.drug_id=interaction.drug_a_id
        JOIN pharmachain.drugs drug_b ON drug_b.drug_id=interaction.drug_b_id
        WHERE interaction.is_active AND interaction.severity IN ('MAJOR', 'CONTRAINDICATED')
          AND interaction.drug_a_id = ANY(ARRAY[${ids.join(',')}])
          AND interaction.drug_b_id = ANY(ARRAY[${ids.join(',')}])`);
      if (result.length) {
        send(res, 409, { error: 'Dispensing blocked: a major drug interaction was detected.', interactions: result });
        return;
      }
      send(res, 200, { message: 'Prescription items saved. No blocking interaction was found.' });
      return;
    }
    if (req.method === 'GET' && url.pathname === '/api/substitutes') {
      const branchId = number(url.searchParams.get('branch_id'), 'Branch');
      const drugId = number(url.searchParams.get('drug_id'), 'Drug');
      const qty = number(url.searchParams.get('quantity') || 1, 'Quantity');
      send(res, 200, await rows(`SELECT * FROM pharmachain.find_substitutes(${branchId}, ${drugId}, ${qty}, 0)`));
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/transfer') {
      const input = await body(req);
      const sourceBatch = number(input.sourceBatchId, 'Source batch');
      const destBranch = number(input.destinationBranchId, 'Destination branch');
      const qty = number(input.quantity, 'Quantity');
      const actor = literal((input.actor || 'demo-manager').slice(0, 100));
      const result = await query(`SELECT pharmachain.transfer_stock(${sourceBatch}, ${destBranch}, ${qty}, ${actor}, '${uuid()}'::UUID)`);
      send(res, 200, { message: `Transfer ${result} completed atomically.` });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/reorder') {
      const input = await body(req);
      const branchId = number(input.branchId, 'Branch');
      await query(`CALL pharmachain.refresh_reorder_alerts(${branchId})`);
      const data = await rows(`SELECT * FROM pharmachain.generate_draft_purchase_orders(${branchId}, ${literal('demo-procurement')})`);
      send(res, 200, { message: `${data.length} draft purchase order${data.length === 1 ? '' : 's'} generated.`, orders: data });
      return;
    }
    if (req.method === 'POST' && url.pathname === '/api/refresh-forecast') {
      await query('REFRESH MATERIALIZED VIEW pharmachain.mv_daily_demand');
      send(res, 200, { message: 'Demand history refreshed.' });
      return;
    }
    send(res, 404, { error: 'Route not found.' });
  } catch (error) {
    const message = String(error.message || error).replace(/^ERROR:\s*/, '').split('\n')[0];
    send(res, 400, { error: message });
  }
});

server.listen(port, '127.0.0.1', () => {
  console.log(`PharmaChain prototype: http://localhost:${port}`);
  console.log(`PostgreSQL database: ${dbName}`);
  console.log('Press Ctrl+C to stop.');
});
