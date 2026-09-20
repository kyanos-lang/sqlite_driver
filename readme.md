# Kyanos SQLite Query Driver

Optional SQLite ergonomics for Kyanos applications. The package is a
database module, not part of `kyanos_app`: applications choose when and where
to open a database, while this package provides a small parameterised query
builder over `std::db::sqlite`.

## API

```kya
mod std;
mod sqlite;

import sqlite::open_context;
import sqlite::select;
import std::error::SimpleError;
import std::result::Result;

fn load(db: &std::db::sqlite::Db) -> Result<(), SimpleError> {
    let mut query = select("people");
    query.column("id");
    query.column("name");
    query.where_i32("id", "=", 7);
    let prepared = query.build()?.prepare(db)?;
    if prepared.step()? == 1 {
        println(prepared.column_text(1));
    }
    return Ok(());
}
```

`open_context` returns the caller-owned typed `std::db::sqlite::Db`
context. `open` remains available as a short alias. The context owns its
native handle and closes it through `Drop`; do not pass a context to
`db_take_handle` unless ownership is being deliberately transferred to
`app::db`.

`select`, `insert`, `update`, and `delete` validate table/column/operator
identifiers and render values as `?` parameters. `UPDATE` and `DELETE`
require a predicate to avoid accidental whole-table mutations. Supported
values are `i32`, text, and blobs, matching the current SQLite standard
library binding surface. Row decoding remains explicit through
`BoundQuery.column_*`.

## Typed model metadata

The SQLite package supports opt-in model declarations:

```kya
#[orm(table = "people")]
struct Person {
    #[orm(primary_key)]
    id: i32,
    #[weave(rename = "full_name")]
    name: string,
}
```

The compiler validates the table and column identifiers, requires exactly one
`i32` primary key, rejects duplicate columns, and limits mapped fields to
`i32`, `string`, and `Vec<u8>`. The generated SQL templates are available
through `model_table<T>()`, `model_primary_key<T>()`, and
`model_{insert,upsert,find,update,delete}_sql<T>()`. Persist verbs
`model_insert` / `model_find` / `model_update` / `model_delete` / `model_upsert`
take a typed model SQL template plus `BindValues` / `RowValues`. Values remain
parameters. Models are native-only and do not create global database state.
`seed_models<T>` applies a `Vec<T>` in bounded transactions using the selected
`SeedOptions` conflict policy and invokes progress only after each committed
batch.

## Build and smoke test

```bash
export KYANOS_LIB=/path/to/kyanos/lib
kyanos check --manifest-path kyanos.toml
./scripts/build_smoke.sh
./target/sqlite_smoke
```

SQLite is native-only and must be enabled in the Kyanos runtime build. The
package does not select a database at application boot and does not alter
`kyanos_app`.

## Transaction scope

Use `with_transaction` when a group of operations should commit or roll back
as one `Result`-scoped unit:

```kya
import std::db::sqlite::Db;
import std::error::SimpleError;
import sqlite::open_context;
import sqlite::with_transaction;

fn create_person(db: &mut Db) -> Result<(), SimpleError> {
    return db.exec("INSERT INTO people (id, name) VALUES (7, 'Ada')");
}

let mut db = open_context(":memory:")?;
let outcome = with_transaction(&mut db, create_person);
```

The callback receives the caller-owned typed `Db`. A successful callback is
committed; callback or commit failures trigger rollback, and the original
typed callback error is returned. Nested transactions and use-after-close are
rejected by the context. This helper does not attach database state to an HTTP
request, and callbacks must keep prepared statements/results within their
scope before returning.

## Fixtures and seeds

Use `fixture_open` for an isolated test database. It applies schema statements
in order, then seed statements, and returns the caller-owned `Db`:

```kya
let db = fixture_open_memory(schema, seeds)?;
```

Pair with `with_transaction` for test-scoped rollback. This is the canonical
temp-DB path for SQLite integration tests (`app::db_fake_*` covers lifecycle
contract tests without a real store).

`fixture_apply` applies an ordered `Vec<string>` of explicit setup statements
to an existing database. Fixture SQL is intended for trusted test setup;
application values should use the query builder's bound parameters.

## Connection pooling

`open_pool(path, max)` creates a bounded `SqlitePool`. `acquire` reuses an idle
handle or opens a new one up to the configured limit; `release` returns the
caller-owned handle. `close` drops idle handles and rejects later acquires.
`max <= 0` uses the default limit of 4 and explicit limits are clamped to
1..32.

The pool is an ownership helper, not a thread-safety or task-scheduling
primitive. Do not share a checked-out `Db` across tasks. Each `:memory:`
connection has its own database, so use a file path when pooled connections
must see the same state.

### Lease lifecycle

`acquire_with_timeout(ms)` returns a health-checked `DbLease`; release it with
`release_lease`. `lease.ping()` refreshes its health state and
`lease.is_healthy()` reports it. A zero timeout is a non-blocking attempt.
`metrics()` reports
total, idle, leased, acquisitions, timeouts, and failures. `drain(ms)` stops
new leases and waits for active leases before closing idle connections;
`shutdown(ms)` is its explicit lifecycle alias.

```kya
let mut lease = pool.acquire_with_timeout(250)?;
lease.ping()?;
pool.release_lease(lease)?;
let metrics = pool.metrics();
app::db_ops_set_pool_metrics(metrics); // optional: push snapshot for /metrics
pool.shutdown(1000)?;
```

SQLite `exec` records query timing into process counters. Opt in to a redacted
SQL log with `app::use_sql_log()` / `app::use_sql_log_slow_ms(ms)` (placeholders
only; never bound values). Prepared ORM paths also call `kyanos_db_ops_observe`.

## Embedded migrations

Define migrations in application code and pass them to the runner:

```kya
let mut migrations = with_capacity<app::db::migrations::Migration>(2usize);
migrations.push(app::db_migration(
    1, "create_people", "sha256:...",
    "CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT);",
    "DROP TABLE people;"
));
sqlite::migration_up(&mut db, &migrations)?;
```

`migration_status`, `migration_pending`, and `migration_dry_run` are
read-only. `migration_up` applies pending versions in ascending order;
`migration_down` rolls back one latest version; and `migration_reset` rolls
back all versions in descending order. The runner stores version, name,
checksum, and application order in `kyanos_schema_migrations`, uses an
immediate transaction as its lock, and rolls back both schema and history on
failure. A changed checksum is rejected before any migration runs.

## `app::db` lifecycle adapter

The package exposes `app_db_driver_name`, `app_db_driver_version`, `app_db_handle`,
`app_db_take_handle`, and `app_db_ping` / `app_db_begin` / `app_db_commit` / `app_db_rollback` /
`app_db_close` callbacks. Prefer `app_db_take_handle(&mut db)` when transferring
ownership to `app::db`; the original `Db` must not be used afterward. Wire
these explicitly into `app::db_backend`, then pass the resulting
`app::db_context` to handlers or jobs. `app_db_exec` is provided for migration and
seed callbacks. The adapter owns no global app state and does not replace the
SQLite query, row, fixture, pool, or ORM APIs.

See [db-drivers.md](../../policies/db-drivers.md).
