import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dbName = process.env.PGDATABASE || 'pharma_chain';
const psql = process.env.PSQL || 'psql';

function run(command, args, label) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: 'utf8',
    stdio: 'inherit',
  });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${label} failed (exit ${result.status ?? 'unknown'}).`);
  }
}

const exists = spawnSync(psql, ['-X', '-d', 'postgres', '-qAt', '-c',
  `SELECT 1 FROM pg_database WHERE datname = '${dbName.replaceAll("'", "''")}'`],
{ encoding: 'utf8' });
if (exists.error || exists.status !== 0) {
  console.error('Could not connect to PostgreSQL. Start PostgreSQL 17 and check your local connection.');
  process.exit(1);
}

if (exists.stdout.trim() === '1') {
  console.error(`Database "${dbName}" already exists. Setup only creates a fresh database; it will not overwrite existing data.`);
  console.error(`Choose another name with PGDATABASE=pharmachain_demo npm run db:setup`);
  process.exit(1);
}

run('createdb', [dbName], 'Database creation');
run(psql, ['-X', '-v', 'ON_ERROR_STOP=1', '-d', dbName,
  '-f', 'db/migrations/001_schema.sql'], 'Schema migration');
run(psql, ['-X', '-v', 'ON_ERROR_STOP=1', '-d', dbName,
  '-f', 'db/migrations/002_database_logic.sql'], 'Database logic migration');
run(psql, ['-X', '-v', 'ON_ERROR_STOP=1', '-d', dbName,
  '-f', 'db/seeds/review2_demo.sql'], 'Demo seed');

console.log(`\nDatabase "${dbName}" is ready. Start the prototype with npm start.`);
