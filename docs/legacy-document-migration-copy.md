# Stage 5C-2B: explicit single-document legacy copy

Implemented for review on `test-codex`. No migration was executed. Rails and
Docker tests were not run. This adds no runner, job, batch operation, cutover,
legacy deletion, automatic recovery, or configuration change.

`LegacyDocumentMigrationCopy#call(file_id:, attempt_id:, worker_token:,
generation:, expected_state:)` accepts exactly one FileDraft ID and attempt ID.
The caller must already hold a durable claim and authorize the source environment,
immutable source snapshot or enforced legacy writer freeze. `expected_state`
must be `planned`; neither copying nor published attempts may be resumed by this
service. The service rejects enclosing transactions, including test fixture
transactions, because evidence must commit before filesystem publication.

The journal's expected legacy locator is authoritative. Every checkpoint locks
run, attempt, then the explicitly identified unscoped draft, compares FileID and
exact locator bytes in Ruby, and validates token, integer generation, expected
state, running run and unexpired lease using database time. It never saves a
draft or invokes lifecycle callbacks. Soft-deleted and signed drafts are included.
The initial checkpoint transitions planned to copying; a duplicate invocation
cannot enter once that transition commits.

The service opens the source through `DocumentStorage.open_legacy`, captures all
eight device/inode/size/link-count/mtime/ctime fields with integer nanoseconds,
and commits that complete immutable evidence before copying. Zero-byte files
are rejected pending policy. Extension validation and lowercase normalization
use the existing storage allocator; absent/unsupported extensions fail closed.
A fresh UUID private locator is committed through `record_copy_target!` before
calling `publish_private`. Allocation never retries a collision.

Binary bytes stream in 1 MiB chunks into private staging, accumulating byte
count and SHA-256. Claims and draft references are checked before every source
and completed-target read. The pinned source is independently reread and hashed,
and its complete stat evidence compared before/after. Staging is independently
hashed and compared. The copied size must equal the recorded source size.
`record_copy_digest!` commits the size/hash before the writer block returns and
storage's exclusive publication occurs. These fields and the target are
write-once; partial progress does not assert verified publication.

The completed private file is opened with `open_private`, independently hashed,
and checked for stable stat evidence. Source bytes/stat are checked again and
`open_legacy` must complete its final pathname/root checks. A final locked
claim/draft checkpoint transitions to `published_verified` using the recorded
size/hash. This is the final state of this service; no locator cutover occurs.

## Failures and interruption

Claim failures raise `LegacyDocumentMigrationAttempt::ClaimRejected`. Other
ordinary failures raise `LegacyDocumentMigrationCopy::Failure` with an allowlisted
code and no sensitive exception message/cause. Nothing is logged. Interrupt and
process termination are not caught. No failure handler attempts another DB write:
a lost connection or ambiguous commit must not cause guessed state transitions.
The last durable state/evidence and claim remain for explicit reconciliation.
A pre-entry rejection can leave planned; failures after entry leave copying,
unless the final commit outcome itself is unknown. Read the authoritative DB
before deciding that an ambiguous final commit failed.

| Interruption window | Durable evidence / required review |
| --- | --- |
| Before source evidence | Copying state and original attempt identity; source must be reinspected |
| After source inspection | Complete source identity, potentially no target yet |
| After target allocation | Exact target ownership recorded before publication; target may be absent |
| During staging | Target/source evidence retained; a process crash may retain private staging |
| After digest commit | Exact target, source identity, expected size/hash; publication may or may not have occurred |
| After publication or cleanup failure | Target retained; verify ownership, links, bytes and worker quiescence explicitly |
| After verified commit | Verified evidence retained, draft still legacy; cutover remains separate |

Storage handles ordinary staging cleanup. This service never unlinks a target.
`CleanupFailure` stops verification, including when residual staging makes the
published target multiply linked. It never treats that exception as permission
to republish or bypass strict private opening. Reconciliation and a new attempt,
if authorized, remain explicit operator decisions. No interrupted attempt is
automatically retried or reset, and no orphan is inferred from its name or age.

## Remaining limits

Filesystem I/O and database commits are separate. A claim can expire, a run can
stop, or a locator can change between the last checkpoint and atomic publication;
the next checkpoint stops attestation and retains the attributable target.
Database fencing cannot stop in-flight filesystem work. Recovery requires the
old worker to be quiesced. Checkpoint validity is not a commit-time lease promise.

Stat/hash comparisons do not prove immutability against hostile writers or
changes restored between observations. Enforce the source freeze independently;
trust private directories and restrict journal writers. Storage still uses
pathname-based root checks and file fsync without directory fsync. Power-loss
durability, persistent mount topology and replica visibility require deployment
review. Large files incur multiple reads and per-chunk database checkpoints;
lease duration and bounded database lock waits need operational review. There
is no automatic lease renewal. Real SQL Server lock/precision/transaction behavior
and connection-failure recovery remain unvalidated by syntax checks.

## Validation for review

The two original SQL Server expiry failures were caused by test setup using
`update_columns` on the setup attempt after the service's separately loaded
attempt had advanced `lock_version`. Optimistic locking made that stale update
affect zero rows (returning false), so the lease never expired. Expiry injection
now updates only the synthetic attempt by ID using
`DATEADD(second, -60, SYSUTCDATETIME())`, asserts one affected row, and reads back
the durable expiry and unchanged credentials. The staging hook verifies staging
exists before publication; the post-publication hook verifies published bytes
before expiry. Both retain the original rejection assertions and now verify
source/journal evidence retention as well.

Additional regression coverage expires the lease after all source/path checks,
immediately before the final claim checkpoint, with application time set to
2000. A live-claim test sets application time to 2040. These distinguish database
UTC checks from application time in both directions. The final transition is
also tested directly with expired credentials. Production claim checks continue
to use `SYSUTCDATETIME()` and strict `lease_expires_at > now`; no fencing or
storage cleanup behavior was changed. The filesystem race described above
still applies; these checks do not promise atomic database/filesystem fencing.

Synthetic tests use only temporary directories and their own committed draft/run/
attempt rows. They cover binary copying, signed/soft-deleted metadata preservation,
full evidence, exact locator mismatches, wrong credentials/state/IDs, generation-zero
compatibility rejection, expiry, interrupted runs, enclosing transactions, missing/
unsafe/empty sources, unsupported extensions, source mutation/replacement, locator
changes, failed publication, target corruption, post-publication interruption,
cleanup failure, failed final journal writes, and refusal to retry.

Only Ruby syntax checks and `git diff --check` were executed. Run these commands
serially against an isolated disposable SQL Server test environment when approved:

```sh
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails db:prepare
docker compose -f docker-compose.yml run --rm web bundle exec ruby test/services/document_storage_test.rb
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails test test/services/legacy_document_migration_copy_test.rb test/models/legacy_document_migration_journal_test.rb test/models/legacy_document_migration_claim_test.rb
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails test test/models/file_draft_test.rb test/services/document_creation_test.rb test/services/document_revision_test.rb test/services/document_deletion_test.rb test/services/legacy_document_inventory_test.rb
```

Stop for review before execution or Stage 5C-3 locator cutover.
