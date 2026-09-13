#!/usr/bin/env node

import { appendFile, readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";

const DEFAULT_API_URL = "https://api.supabase.com";
const MIGRATION_FILE_PATTERN = /^(\d{14})_([a-z0-9_]+)\.sql$/;
const TRANSACTION_CONTROL_PATTERN = /^\s*(begin|commit|rollback)\s*;/im;

export function parseMigrationFilename(fileName) {
  const match = MIGRATION_FILE_PATTERN.exec(fileName);
  if (!match) {
    throw new Error(
      `Invalid migration filename ${fileName}. Expected <14-digit timestamp>_<name>.sql.`,
    );
  }

  return {
    fileName,
    version: match[1],
    name: match[2],
  };
}

export function planMigrations(
  localMigrations,
  remoteMigrations,
  legacyHistory = { entries: [], aliases: {} },
) {
  const localVersions = new Set();
  const localNames = new Set();
  for (const migration of localMigrations) {
    if (localVersions.has(migration.version)) {
      throw new Error(`Duplicate local migration version: ${migration.version}`);
    }
    if (localNames.has(migration.name)) {
      throw new Error(`Duplicate local migration name: ${migration.name}`);
    }
    localVersions.add(migration.version);
    localNames.add(migration.name);
  }

  const remoteVersions = new Set();
  const remoteNames = new Set();
  for (const migration of remoteMigrations) {
    const version = String(migration.version ?? "");
    const name = String(migration.name ?? "");
    if (!version) {
      throw new Error("Supabase returned a migration without a version.");
    }
    remoteVersions.add(version);
    if (name) remoteNames.add(name);
  }

  const acceptedLegacyEntries = new Set(
    (legacyHistory.entries ?? []).map(
      ({ version, name }) => `${String(version)}:${String(name)}`,
    ),
  );
  const remoteOnly = remoteMigrations.filter(
    (migration) =>
      !localVersions.has(String(migration.version ?? "")) &&
      !acceptedLegacyEntries.has(
        `${String(migration.version ?? "")}:${String(migration.name ?? "")}`,
      ),
  );
  if (remoteOnly.length > 0) {
    throw new Error(
      `Remote migration history contains entries missing from Git: ${remoteOnly
        .map(({ version, name }) => `${String(version)}:${String(name ?? "<unnamed>")}`)
        .join(", ")}`,
    );
  }

  const aliases = legacyHistory.aliases ?? {};
  return localMigrations.filter((migration) => {
    const alias = aliases[migration.name];
    return (
      !remoteVersions.has(migration.version) &&
      !remoteNames.has(migration.name) &&
      !(alias && remoteNames.has(alias))
    );
  });
}

function sqlLiteral(value) {
  return `'${String(value).replaceAll("'", "''")}'`;
}

export function buildMigrationQuery({ version, name, sql }) {
  if (TRANSACTION_CONTROL_PATTERN.test(sql)) {
    throw new Error(
      `Migration ${version} contains top-level transaction control. Refusing to wrap it automatically.`,
    );
  }

  const statementTag = `$gibb_migration_${version}$`;
  if (sql.includes(statementTag)) {
    throw new Error(`Migration ${version} contains the reserved SQL delimiter.`);
  }

  return [
    "begin;",
    "set local lock_timeout = '10s';",
    "select pg_advisory_xact_lock(18082026);",
    "create schema if not exists supabase_migrations;",
    "create table if not exists supabase_migrations.schema_migrations (version text not null primary key);",
    "alter table supabase_migrations.schema_migrations add column if not exists statements text[];",
    "alter table supabase_migrations.schema_migrations add column if not exists name text;",
    sql.trim(),
    `insert into supabase_migrations.schema_migrations(version, name, statements) values (${sqlLiteral(version)}, ${sqlLiteral(name)}, array[${statementTag}${sql}${statementTag}]::text[]);`,
    "commit;",
  ].join("\n\n");
}

async function loadLocalMigrations(migrationsDirectory) {
  const files = (await readdir(migrationsDirectory))
    .filter((fileName) => fileName.endsWith(".sql"))
    .sort();

  return Promise.all(
    files.map(async (fileName) => ({
      ...parseMigrationFilename(fileName),
      sql: await readFile(path.join(migrationsDirectory, fileName), "utf8"),
    })),
  );
}

function createApiClient({ apiUrl, projectRef, token }) {
  const projectPath = `/v1/projects/${encodeURIComponent(projectRef)}`;

  return async function request(apiPath, options = {}) {
    const response = await fetch(`${apiUrl}${projectPath}${apiPath}`, {
      ...options,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/json",
        ...(options.body ? { "Content-Type": "application/json" } : {}),
        ...options.headers,
      },
      signal: AbortSignal.timeout(180_000),
    });

    const responseText = await response.text();
    if (!response.ok) {
      throw new Error(
        `Supabase Management API ${response.status} ${response.statusText}: ${responseText.slice(0, 2_000)}`,
      );
    }

    return responseText ? JSON.parse(responseText) : null;
  };
}

async function writePendingCount(count) {
  if (process.env.GITHUB_OUTPUT) {
    await appendFile(process.env.GITHUB_OUTPUT, `pending_count=${count}\n`);
  }
}

async function main() {
  const mode = process.argv.find((argument) => argument.startsWith("--mode="))
    ?.split("=")[1]
    ?.toLowerCase();
  const expectedPendingArgument = process.argv.find((argument) =>
    argument.startsWith("--expected-pending="),
  );
  const expectedPending = expectedPendingArgument
    ? Number(expectedPendingArgument.split("=")[1])
    : null;

  if (!new Set(["preview", "apply"]).has(mode)) {
    throw new Error("Pass either --mode=preview or --mode=apply.");
  }

  const token = process.env.SUPABASE_ACCESS_TOKEN;
  const projectRef = process.env.SUPABASE_PROJECT_ID;
  if (!token || !projectRef) {
    throw new Error(
      "SUPABASE_ACCESS_TOKEN and SUPABASE_PROJECT_ID are required.",
    );
  }

  const migrationsDirectory = path.resolve("supabase", "migrations");
  const legacyHistory = JSON.parse(
    await readFile(
      path.resolve("supabase", "legacy-migration-history.json"),
      "utf8",
    ),
  );
  const localMigrations = await loadLocalMigrations(migrationsDirectory);
  const request = createApiClient({
    apiUrl: process.env.SUPABASE_MANAGEMENT_API_URL ?? DEFAULT_API_URL,
    projectRef,
    token,
  });
  const remoteMigrations = await request("/database/migrations");
  if (!Array.isArray(remoteMigrations)) {
    throw new Error("Supabase returned an invalid migration history response.");
  }

  const pendingMigrations = planMigrations(
    localMigrations,
    remoteMigrations,
    legacyHistory,
  );
  console.log(`Local migrations: ${localMigrations.length}`);
  console.log(`Remote migrations: ${remoteMigrations.length}`);
  console.log(`Pending migrations: ${pendingMigrations.length}`);
  for (const migration of pendingMigrations) {
    console.log(`- ${migration.fileName}`);
  }
  await writePendingCount(pendingMigrations.length);

  if (mode === "preview") {
    console.log("Preview complete. Production was not changed.");
    return;
  }

  if (!Number.isSafeInteger(expectedPending) || expectedPending < 0) {
    throw new Error(
      "Apply mode requires --expected-pending=<non-negative integer>.",
    );
  }
  if (pendingMigrations.length !== expectedPending) {
    throw new Error(
      `Pending migration count changed: expected ${expectedPending}, found ${pendingMigrations.length}.`,
    );
  }

  for (const migration of pendingMigrations) {
    console.log(`Applying ${migration.fileName}...`);
    await request("/database/query", {
      method: "POST",
      body: JSON.stringify({
        query: buildMigrationQuery(migration),
        read_only: false,
      }),
    });

    const verified = await request(
      `/database/migrations/${encodeURIComponent(migration.version)}`,
    );
    if (String(verified?.version ?? "") !== migration.version) {
      throw new Error(
        `Migration ${migration.version} was applied but could not be verified in migration history.`,
      );
    }
    console.log(`Verified ${migration.fileName}.`);
  }

  const finalHistory = await request("/database/migrations");
  const stillPending = planMigrations(
    localMigrations,
    finalHistory,
    legacyHistory,
  );
  if (stillPending.length > 0) {
    throw new Error(
      `Verification failed; migrations remain pending: ${stillPending.map(({ fileName }) => fileName).join(", ")}`,
    );
  }
  console.log("All repository migrations are applied and verified.");
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exitCode = 1;
  });
}
