# Stage 5C-1: durable legacy document migration journal

This stage adds persistence only. It does not copy, hash, inspect, update or
remove documents. There is no execution command, startup hook, worker or change
to document lifecycle services. FileDraft and FileURLPath are unchanged.

## Schema and access

`legacy_document_migration_runs` uses a bigint database ID plus a required unique
operator-supplied UUID `run_identifier`. Required `source_environment` identifies
an approved restricted environment/source manifest; do not put credentials or
connection strings here. `status` starts as `running`, with required `started_at`.
`completed`, `interrupted`, and `failed` require `completed_at >= started_at`.
These are terminal run states: a restart creates another run. Nonnegative bigint
`candidate_count`, `verified_count`, and `blocked_count` are sanitized snapshots,
not automatically maintained totals. `finish!` is the only validated completion API.
`completed` requires every attempt to be closed (`verified`, `superseded`, `gone`,
or `rolled_back`); planned, copying, published_verified, committed, and blocked
attempts prevent completion. Empty runs may complete. `interrupted` and `failed`
may retain unresolved attempts and their reservations for later reconciliation.
Counts remain historical snapshots: a nonzero blocked count does not mean an
unresolved blocked attempt remains. Completion alone does not establish migration
acceptance, since closed attempts may have been superseded, gone, or rolled back.

Attempt creation locks the parent run row and requires it to remain running.
`finish!` holds that same row lock while checking attempts and updating the run,
preventing admission from racing completion. Existing attempts can still advance
or close after interruption/failure; terminal run status does not release claims.
There is no API to reopen a closed attempt or restart a terminal run.

`legacy_document_migration_attempts` has a bigint ID and required run FK, integer
`file_id` matching FileDraft's FileID type, exact `expected_legacy_locator`
(up to 500 characters), restricted `source_identity` (up to 200), `state`, and
`started_at`. Optional evidence is `target_locator`, nonnegative bigint
`expected_size`, lowercase 64-character hexadecimal `expected_sha256`, and an
allowlisted `error_code`. No document contents or exception messages belong in
this journal. Source identity should reference an approved immutable snapshot or
restricted source manifest; the schema does not discover or attest one.

Verified publication states require target, size and hash evidence. These are
caller assertions in this stage: no hashing or verification is performed.
`completed_at` denotes attempt closure, not the time copying started or ended.
Both tables have `lock_version` for optimistic locking. Transition APIs also lock
and reload the row inside a transaction. Unsaved receiver changes should be saved
or discarded before invoking them, as required by Active Record `with_lock`.

There is deliberately **no foreign key or association to FileDraft or Users**.
Hard deletion and creator cascades cannot delete journal records. The attempt/run
FK uses default NO ACTION; deleting a run with attempts is rejected. There are no
dependent deletion callbacks. Journal access and database/backups must be
restricted: locators, IDs, source identities and hashes may identify people.
This stage does not provision database roles, retention or infrastructure.

## Allowed transitions

Attempts must be created in `planned`. `transition_to!` validates the following
edges under a row lock, updating state, closure time and reservation together.
Ordinary validated updates reject state changes, even along allowed edges;
only `transition_to!` enables the state change for the duration of its locked
update. Run status changes similarly require `finish!`. Guards reset even if
validation or persistence fails. Both APIs retain optimistic locking. Immutable
identity validation applies inside the APIs as well as ordinary updates.

| From | Allowed next states |
| --- | --- |
| planned | copying, blocked, superseded, gone |
| copying | published_verified, blocked, superseded, gone |
| published_verified | committed, blocked, superseded, gone |
| committed | verified, blocked, rolled_back |
| blocked | superseded, gone, rolled_back |
| verified | rolled_back |
| superseded, gone, rolled_back | none |

Unknown states, skipped forward stages, self transitions through the API, and
backward transitions are rejected. Closing a blocked attempt is an explicit
operator reconciliation decision, never an automatic retry. Superseding a blocked
attempt records that its work is being replaced; it does not authorize removal of
its target. `rolled_back` records a separately verified recovery outcome and does
not restore a locator or delete a file. A verified attempt can later record that
outcome. This table stores the latest state per attempt and preserved retry rows,
not an append-only event stream of every intermediate state.

The evidence parameter accepts only target, size, SHA-256 and error code. Run,
FileID, exact old locator, source identity and start time are immutable through
validated updates. Once a target locator, expected size, or expected SHA-256 has been recorded
(non-null), validated updates cannot change or clear it, including through later
valid transitions. Repeating identical values is allowed. This intentionally also
protects evidence recorded before publication. Publication requires all three
fields, so reaching `published_verified` freezes the complete publication record
through committed, verified, blocked, and all subsequent closure states. The exact
old locator and source identity are immutable from creation. Error codes may
still record later failures. There is no evidence replacement or recovery API. Direct SQL,
`update_columns`, and bulk writes bypass transition validation and must remain
restricted to reviewed maintenance. Database checks enforce valid current states
and row invariants, not historical transition edges, evidence immutability, or
cross-row run completion rules; no SQL triggers are added. Run admission and
completion consistency rely on the model APIs and their shared parent row lock.
No schema changes are required for this hardening pass.

## Global uniqueness and leases

A required bigint `reservation_key` is zero for `planned`, `copying`,
`published_verified`, `committed`, and `blocked`. Closed states (`verified`,
`superseded`, `gone`, `rolled_back`) must set it to their own positive attempt ID.
A database CHECK binds that key and the completion timestamp to the state.
The ordinary unique index `(file_id, reservation_key)` therefore permits only
one active attempt for each FileID across **all runs**, plus any number of closed
attempts. No nullable-key semantics, filtered unique index, pre-insert uniqueness
query, or draft row existence is needed. A duplicate insert raises
`ActiveRecord::RecordNotUnique`; the losing caller must reload the authoritative
attempt, not blindly retry. Constraint checks prevent releasing a reservation
while leaving the attempt active. Run interruption/completion never releases it.

Reserved fields `lease_token`, `lease_expires_at`, and nonnegative
`lease_generation` support a future fenced lease. Token and expiry must be both
null or both present; only active attempts can hold a lease. Transition APIs clear
token/expiry while preserving generation. No acquisition, renewal, takeover or
worker is implemented. Do not use a lease expiry as permission to start work.

Future workers must acquire/renew under database row locks using database UTC time,
bounded durations and lock waits; increment the generation on every acquisition
or takeover; and require matching token, generation, unexpired lease and expected
state in every guarded mutation. Recovery of an expired lease requires explicit
operator reconciliation of journal, current draft and filesystem evidence before
fenced takeover. Expiry alone cannot stop an old process doing filesystem I/O:
source immutability, worker fencing/quiescence and non-overwriting publication
remain prerequisites. A run/operator-wide execution lease is still future work.
Independent connections, deadlock behavior, SQL Server locks and commit-ambiguity
recovery must be tested before any worker is enabled.

## Recovery and compatibility

Interrupted runs retain attempts in their last durable state, including active
reservations and publication evidence. Resume/reconcile the existing attempt;
never reset all rows or release claims based on age. Before a new retry, explicitly
close the previous attempt and retain its target/evidence. Lost connections during
commit require rereading authoritative database state. Published files without a
durable journal entry remain retained orphans; this journal does not establish
exactly-once publication or authorize cleanup. See the Stage 5A recovery windows.

The migration follows Rails 8 migration conventions, using `add_foreign_key`,
`check_constraint`, and an ordinary unique index. CHECK expressions use SQL Server
`LEN`, `LTRIM`, `RTRIM`, and `Latin1_General_100_BIN2` for strict hexadecimal checks.
These expressions are intentionally SQL Server specific. Confirm collation
availability and adapter-generated bigint identity, datetime precision, constraint
and index DDL on the isolated SQL Server test database. Status/error membership
uses the database's normal collation; application validation is case sensitive.
Exact locator comparison for a future migration must use Ruby byte/string equality
after locking, not SQL equality under case/space-insensitive collations.

The checked-in `db/schema.rb` is not hand-edited by this pass. No database
commands were run during hardening.
After applying this migration in an isolated database, review the generated schema
dump, constraint preservation and rollback before accepting it. Schema loading
from the old dump alone will not install this journal; run migrations first.

## Validation and remaining work

Before this hardening pass, the SQL Server migration succeeded and the reported
results were: journal 11 runs/65 assertions, existing document tests 63 runs/334
assertions, full suite 755 runs/4458 assertions, and 90.75% full-suite line coverage.
For this hardening pass only Ruby syntax and `git diff --check` were run; the
expanded Rails and SQL Server tests below must be rerun. Tests use synthetic journal data and
synthetic draft metadata without accessing document files. They cover creation,
state transitions, retry/interruption, global reservation uniqueness, constraint
bypasses, optimistic locking, deletion persistence, unchanged draft metadata and
absence of enqueued notifications. Added regressions cover direct state/status
changes, immutable publication evidence (including valid transition attempts),
failed guard cleanup, premature completion, interrupted/failed run retention,
closed-run admission, and reservation uniqueness after every closed state. They
do not prove multi-connection concurrency.

Run against an isolated disposable test database using the development Compose
configuration, never staging/production:

```sh
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails db:prepare
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails test test/models/legacy_document_migration_journal_test.rb
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails test test/models/file_draft_test.rb test/services/document_creation_test.rb test/services/document_revision_test.rb test/services/document_deletion_test.rb test/services/legacy_document_inventory_test.rb
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails test
```

Remaining implementation includes execution authorization/preflight, source
attestation, run-wide execution leases, fenced attempt lease APIs and concurrency tests,
copy/hash/publication durability, guarded locator-only commit, post-commit
verification, rollback reconciliation, schema-dump review, and restricted operator
reporting. No command in this stage executes a migration of document bytes.
Stop for review before progressing beyond the journal.
