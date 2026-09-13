import assert from "node:assert/strict";
import test from "node:test";

import {
  buildMigrationQuery,
  parseMigrationFilename,
  planMigrations,
} from "../scripts/supabase-management-migrations.mjs";

test("parses canonical Supabase migration filenames", () => {
  assert.deepEqual(
    parseMigrationFilename("20260912163000_add_admin_control_center.sql"),
    {
      fileName: "20260912163000_add_admin_control_center.sql",
      version: "20260912163000",
      name: "add_admin_control_center",
    },
  );
});

test("rejects non-canonical migration filenames", () => {
  assert.throws(
    () => parseMigrationFilename("12_bad-name.sql"),
    /Invalid migration filename/,
  );
});

test("plans only migrations missing from remote history", () => {
  const local = [
    { version: "20260101000000", name: "first", fileName: "first.sql" },
    { version: "20260102000000", name: "second", fileName: "second.sql" },
  ];
  assert.deepEqual(
    planMigrations(local, [{ version: "20260101000000" }]),
    [local[1]],
  );
});

test("fails closed when remote history is not represented in Git", () => {
  assert.throws(
    () =>
      planMigrations(
        [{ version: "20260101000000", name: "first" }],
        [{ version: "20251231000000" }],
      ),
    /20251231000000:<unnamed>/,
  );
});

test("accepts only audited legacy history and maps explicit local aliases", () => {
  const local = [
    { version: "20260101000000", name: "core", fileName: "core.sql" },
    { version: "20260102000000", name: "new_feature", fileName: "new.sql" },
  ];
  const remote = [
    { version: "20251231000000", name: "create_core" },
    { version: "20260101595959", name: "untracked_but_audited" },
  ];
  const legacyHistory = {
    entries: remote,
    aliases: { core: "create_core" },
  };

  assert.deepEqual(planMigrations(local, remote, legacyHistory), [local[1]]);
});

test("rejects a legacy version when its recorded name changes", () => {
  assert.throws(
    () =>
      planMigrations(
        [{ version: "20260101000000", name: "local" }],
        [{ version: "20251231000000", name: "tampered" }],
        {
          entries: [{ version: "20251231000000", name: "expected" }],
          aliases: {},
        },
      ),
    /20251231000000:tampered/,
  );
});

test("builds an atomic migration query and exact history row", () => {
  const query = buildMigrationQuery({
    version: "20260101000000",
    name: "create_wallets",
    sql: "create table public.wallets (id bigint primary key);\n",
  });

  assert.match(query, /^begin;/);
  assert.match(query, /pg_advisory_xact_lock/);
  assert.match(query, /create table public\.wallets/);
  assert.match(query, /insert into supabase_migrations\.schema_migrations/);
  assert.match(query, /'20260101000000'/);
  assert.match(query, /commit;$/);
});

test("rejects migrations with top-level transaction control", () => {
  assert.throws(
    () =>
      buildMigrationQuery({
        version: "20260101000000",
        name: "unsafe",
        sql: "BEGIN;\nselect 1;\nCOMMIT;",
      }),
    /transaction control/,
  );
});
