October 14, 2026 · @Ankush Garg

## Why this exists

In Lakebase, only a table's owner (or a member of the owning role) can change its schema. Lakebase runs on Postgres, and Postgres treats `SELECT`, `INSERT`, `UPDATE` and `DELETE` as grantable privileges, but `ALTER`, `DROP`, and adding indexes or constraints are reserved for the owner. Unity Catalog grants do not change this; the check happens inside Postgres.

We hit this when Flyway, running as a service principal, failed with a permission error on `ALTER TABLE`. The tables were owned by the individual who first created them, so no grant to the service principal could fix it. The fix is to have a role own the tables instead of a person.

## The model

A non-login role, `app_owner`, owns every table, view and sequence in the schema. Identities that need to change schema are members of it; Flyway switches into it on connect, so anything a migration creates is also owned by `app_owner`.

| Identity | Logs in? | Member of `app_owner`? | Can do |
| --- | --- | --- | --- |
| `app_owner` | No | — | Owns all objects; nobody connects as it directly |
| Flyway service principal (application ID) | Yes | Yes | Runs migrations as `app_owner` via `SET ROLE` |
| Data engineers on their own dev branches | Yes | Yes, on those branches | Run DDL by hand while developing |
| `app_rw` (if used) | Via app identities | No | `SELECT`, `INSERT`, `UPDATE`, `DELETE` only |

The rule: in shared environments, only the Flyway service principal changes schema. Who can change schema is then a question of role membership, which can be audited, not of who happened to create a table first.

## Setup, per branch

Run these on each branch's own endpoint. Roles are copied when a branch is created and do not sync afterward. Replace `<sp-application-id>` and `<your.email>`; the schema is `public`.

1. **Check the roles exist on this branch.** If the service principal is missing, add it the same way it was added on production before continuing.

```sql
SELECT rolname FROM pg_roles
WHERE rolname IN ('app_owner', '<sp-application-id>', '<your.email>');
```

1. **Create the owner role** (safe to re-run).

```sql
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_owner') THEN
    CREATE ROLE app_owner NOLOGIN;
  END IF;
END $$;
```

1. **Give it schema rights.** Run as the database owner. In Postgres 15 and later, `public` no longer grants `CREATE` to everyone, and without this the ownership transfer fails with `permission denied for schema public`.

```sql
GRANT USAGE, CREATE ON SCHEMA public TO app_owner;
```

1. **Grant membership** to whoever is transferring objects and to the service principal.

```sql
GRANT app_owner TO "<your.email>";
GRANT app_owner TO "<sp-application-id>";
```

1. **Transfer existing objects.** Run as their current owner. Indexes and serial/identity sequences follow their table; only standalone sequences are moved separately.

```sql
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT n.nspname, c.relname, c.relkind
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
      AND c.relkind IN ('r', 'p', 'v', 'm')
  LOOP
    EXECUTE format(CASE r.relkind
      WHEN 'v' THEN 'ALTER VIEW %I.%I OWNER TO app_owner'
      WHEN 'm' THEN 'ALTER MATERIALIZED VIEW %I.%I OWNER TO app_owner'
      ELSE 'ALTER TABLE %I.%I OWNER TO app_owner' END, r.nspname, r.relname);
  END LOOP;
  FOR r IN
    SELECT n.nspname, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'S'
      AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
        WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
          AND d.refclassid = 'pg_class'::regclass AND d.deptype IN ('a', 'i'))
  LOOP
    EXECUTE format('ALTER SEQUENCE %I.%I OWNER TO app_owner', r.nspname, r.relname);
  END LOOP;
END $$;
```

1. **Runtime access for `app_rw`** (only if that role is in use). The first three lines cover existing objects; default privileges cover objects created later.

```sql
GRANT USAGE ON SCHEMA public TO app_rw;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_rw;
ALTER DEFAULT PRIVILEGES FOR ROLE app_owner IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO app_rw;
```

## Flyway configuration

`initSql = "SET ROLE app_owner"` goes inside every environment block in `flyway.toml`, next to the connection settings. Without it, migrations run as the service principal itself and new tables end up owned by the service principal.

```toml
[environments.dev]
url = "jdbc:postgresql://<dev-branch-host>:5432/<database>?sslmode=require"
user = "<sp-application-id>"
password = "${env.LAKEBASE_TOKEN}"
schemas = ["public"]
initSql = "SET ROLE app_owner"

[environments.prod]
url = "jdbc:postgresql://<prod-branch-host>:5432/<database>?sslmode=require"
user = "<sp-application-id>"
password = "${env.LAKEBASE_TOKEN}"
schemas = ["public"]
initSql = "SET ROLE app_owner"

[flyway]
environment = "dev"
locations = ["filesystem:sql"]
```

- The older `flyway.initSql=` syntax is for `flyway.conf`, not `flyway.toml`.
- Target an environment per run with `flyway migrate -environment=prod` rather than editing the default.
- The token is read from an environment variable; never commit it to the file.

## Verify

After setup, every object in the schema should be owned by `app_owner` and the service principal should be able to act as it.

**Ownership check**

```sql
SELECT n.nspname AS schema_name, c.relname AS object_name,
       CASE c.relkind WHEN 'r' THEN 'table' WHEN 'p' THEN 'partitioned table'
         WHEN 'v' THEN 'view' WHEN 'm' THEN 'materialized view' WHEN 'S' THEN 'sequence' END AS object_type,
       pg_get_userbyid(c.relowner) AS owner
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY schema_name, object_type, object_name;
```

**Membership check** (both should be `true`)

```sql
SELECT pg_has_role('<sp-application-id>', 'app_owner', 'MEMBER') AS is_member,
       pg_has_role('<sp-application-id>', 'app_owner', 'SET') AS can_set_role;
```

**End-to-end test** (on a dev branch; `ALTER TABLE` briefly locks the table)

1. Connected as the service principal, run `BEGIN; SET ROLE app_owner; ALTER TABLE public.<some_table> ADD COLUMN _perm_test int; ROLLBACK;`
2. Run `flyway info`, then `flyway migrate` with a small migration such as adding a nullable column.
3. Re-run the ownership check. Anything the migration created should show `app_owner`. If it shows the service principal's ID, `initSql` is not being read.

## Gotchas

- **Branches don't sync roles or ownership.** A branch taken before these changes keeps the old setup. Re-branch from the corrected parent, or repeat the setup on that branch.
- **Granting privileges is not ownership.** `GRANT ALL PRIVILEGES` on a table still does not allow `ALTER`. Only ownership or membership in the owning role does.
- **`flyway_schema_history` needs transferring too.** If someone created it by hand, it is owned by them, not `app_owner`.
- **Linked sequences can't be transferred directly.** Sequences behind `SERIAL` or identity columns follow their table; `ALTER SEQUENCE ... OWNER` on them errors.
- **Only the current owner can hand an object over.** Objects owned by someone else must be transferred by that person or an admin-level identity.
- **Functions, procedures and custom types** are not covered by the queries above. If migrations create them, transfer them separately.