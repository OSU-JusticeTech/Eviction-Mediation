# Stage 5C-3: single-document database locator cutover

Implemented for review on `test-codex`. No migration was executed. Rails and
Docker tests were not run. No runner, batch migration, retry, deletion, signing
or revision change is included.

`LegacyDocumentMigrationCutover#call(file_id:, attempt_id:, worker_token:,
generation:, expected_state:)` requires one explicit draft and attempt, a durable
worker claim and exactly `published_verified`. It rejects enclosing transactions.
The caller remains responsible for environment authorization, trusted immutable
private storage and the source freeze established for copying. The journal is
the authority for the expected legacy locator and previously verified private
locator, SHA-256, size and source evidence; callers cannot supply replacement
evidence or infer a destination from a filename.

## Transaction and locking

The existing `with_worker_claim!` opens a top-level transaction, locks/reloads the
run then the attempt with SQL Server `WITH (UPDLOCK, ROWLOCK, HOLDLOCK)`, and checks
running status, nonzero ownership generation, token, expected state and database
UTC lease expiry. The service locks the explicitly identified unscoped FileDraft
third, matching the copy service's lock order. It compares locator bytes in Ruby,
avoiding SQL Server collation's case/trailing-space equivalence. Signed and
soft-deleted drafts remain eligible without changing their other attributes.

Before cutover, the service requires a valid legacy locator, private namespace,
complete source evidence with supported numeric ranges, a single source link,
nonempty source identity, positive equal source/publication sizes and a lowercase
64-character SHA-256. `open_private` validates the full target locator and safe
root, rejects symlinks/nonregular/multiply linked files, and pins a read-only
no-follow descriptor. The service independently streams SHA-256 and size and
compares descriptor identity, size, link count and exact mtime/ctime before and
after reading. Storage's final pathname/root checks must finish before writes.
No source file is opened or modified during cutover; source observations from
the copy remain immutable evidence rather than a new source attestation.

Under those same locks, a guarded locator-only `update_all` must affect exactly
one row. This deliberately bypasses FileDraft callbacks and timestamp updates,
preserving signing, revision, attachment and notification behavior. The fenced
`transition_to!("committed")` then rechecks database UTC expiry after hashing and
saves the journal in the same transaction. Its nested locks reacquire rows already
held by this transaction. Reservation and evidence remain retained; committed
is not the terminal verified state.

Any validation, storage or database failure escapes the transaction, rolling back
both database writes. Failures never record a second journal transition or retry.
Claim failures retain ClaimRejected; other failures expose only a sanitized code.
Neither legacy nor private files are deleted or changed by the service. A lost
connection during commit remains ambiguous: inspect authoritative journal and
draft state before any further action. Do not assume the exception proves rollback.

## Synthetic tests and validation

`test/services/legacy_document_migration_cutover_test.rb` creates only temporary
files and its own committed journal/draft rows. Coverage includes successful
cutover without jobs or metadata changes, evidence retention, repeat rejection,
wrong/missing tokens, stale generations/states, wrong document ID, expired claims,
interrupted runs, enclosing transactions, missing draft/private files, unsafe
private symlinks, hash/size mismatch, mutation during hashing, inconsistent source
size evidence, byte-exact changed draft references, failure after both real writes,
expiry during verification and two competing independent connections with one
winner. Test-only teardown and failure injections remove synthetic temporary files;
the production service contains no deletion API. Run serially in a disposable
SQL Server test database when separately authorized.

Only Ruby syntax checks and `git diff --check` were run. These do not establish
SQL Server adapter locking/rollback semantics or passing runtime tests.

## Remaining risks

Hashing while holding run/attempt/draft locks increases lock duration and serializes
other work in the run. Configure bounded database waits and size/lease policy in
an eventual authorized execution workflow; no session settings, lease renewal,
deadlock retry or background execution are added here. A lease can expire after
the final database-time check but before commit.

Filesystem contents and database commits cannot be atomic. Trusted private roots
and enforced writer exclusion are prerequisites: a writer can change a pathname
or bytes after the final observation. Hash/stat checks cannot prove immutability
against hostile writers. Persistent mounts, replica visibility, directory fsync
and power-loss durability still need deployment review. Audit every deployed
locator writer for compatible draft locks. Real SQL Server independent-connection
concurrency, failure injection and schema/constraint validation remain unexecuted.
Post-commit verification, operator reconciliation, execution authorization and
run-wide leases remain separate work. No staging/production documents were accessed.

Stop for review.
