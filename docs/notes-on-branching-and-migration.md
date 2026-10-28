# Databricks - Notes on branching/migration

### Purpose:

The app team requests schema changes to Lakebase, and Data engineering team owns the change. No data is copied from development branch as a part of this process. This is an interim process, and will eventually move to CI/CD.

### Branches:

1. Production - live application data. This is the only branch registered in unity catalog.
2. Development - where schema changes are created, and where the app team builds and tests. Not registered in unity catalog since the dev team does not need governance and tracking. Long-lived, and is not reset from production.

### When requesting a change:

1. Email Ajay and Tamil, with Data Engineering CC’d. Attach DDL as .sql files (like before) and mention which app depends on it and when you need it completed
2. Apply to dev - DE reviews the change, turns it into migration, applies it do dev, and let’s the requesting team know when it’s live
3. Once ready for production, app team requests for a prod migration, DE notifies downstream consumers and coordinates timing, migrates to production. UC picks up the new changes automatically
4. No one should run DDL by hand on either branch. Every change is a Flyway (open source tool) migration
5. A migration that has already run is never edited. A fix is a new migration

### Reference:

We’ll use Flyway to track migrations in a separate DevOps repo for the Lakebase project. App team will have access to see what made it in. We’ll run migrations manually for now, but know that we’ll move to CI/CD once we’re comfortable