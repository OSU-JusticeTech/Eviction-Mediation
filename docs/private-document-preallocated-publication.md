# Stage 5C-2A: preallocated private publication

This storage-only extension enables future migration ownership evidence before
publication. No migration copy service, runner, journal mutation, database
cutover, lifecycle change, or infrastructure configuration is included.

## API

- `allocate_private_locator(extension:)` returns a UUID-based
  `privateDocuments/<uuid>.<extension>` string. It normalizes extensions exactly
  as `write` does (leading dot removed, lowercase, 1–10 ASCII alphanumerics).
  Allocation creates no directory or file, performs no document scan, and makes
  no availability or uniqueness reservation. Storage may still be unavailable.
- `publish_private(locator:) { |staged_path| ... }` uses the existing trusted
  writer block contract. The block writes complete bytes into private staging;
  publication returns the exact supplied locator. Only validated private
  locators are accepted, never absolute filesystem paths or legacy locators.
  Persisted locators can be reused across process restarts: this API does not
  attest that a locator was allocated by this process or belongs to an attempt.
- `open_private(locator) { |file| ... }` yields a binary, read-only descriptor
  and closes it on return or exception. It rejects symlinks, nonregular entries,
  multiple hard links, and permissions other than 0600 (including special mode
  bits). Existing files published through `write` already satisfy this contract.
  It uses `NOFOLLOW`, fails closed when unsupported, and compares device/inode
  from lstat, fstat, and a second lstat before yielding. After normal block
  completion it revalidates the root and destination permissions/type/link count
  and confirms the destination still references the opened device/inode. The
  block result is preserved. If the block raises, post-block checks are skipped
  and its original exception propagates, including caller I/O exceptions.
  `NONBLOCK` avoids blocking if an entry becomes a FIFO during opening.
  A missing initial entry raises `MissingFile`; I/O failures raise `Unavailable`.
  The caller can stream size and SHA-256 calculations through this descriptor;
  this API itself does not hash bytes or promise source immutability.

`write(extension:)` delegates to allocation and publication. `store`, existing
callers, extension normalization, staging paths, permissions, exclusive linking,
and `CleanupFailure.locator` retain their established contracts.

## Publication and safety

Publication validates the configured root, its ancestors, the private locator,
and any destination entry. Ancestors are checked from the filesystem root down.
Symlinks (including dangling links), directories, special entries, and multiply
linked destination files are rejected. Regular-file collisions fail at exclusive
`File.link`; existing destination bytes are never overwritten or removed.

Staging is created in the private root. After the writer returns, root and
destination checks repeat; staging must be a regular single-link file. It is
chmodded to 0600 and fsynced before an atomic hard link publishes complete bytes
at the exact destination. Staging is unlinked in ensure on ordinary success and
failure. If unlink itself fails, cleanup cannot be guaranteed: after publication,
`CleanupFailure` identifies the completed target; an existing writer/publication
exception remains primary. Published destinations are never automatically
deleted by this API, including when later caller database operations fail.

As with existing storage operations, directories must be trusted and
operator-owned, and writer blocks must be trusted application code. Path checks
do not eliminate hostile concurrent ancestor replacement races. Inspection pins
an opened inode and checks pathname identity again after normal block completion;
it does not freeze bytes or prevent changes between checks or after return. Future integrity verification must check stability and
hashes itself. A residual staging hard link after cleanup failure causes strict
inspection to reject the target until an operator reconciles staging.

## Intended migration lifecycle and crash recovery

The future service must allocate once and durably commit the exact target locator
in the journal before invoking publication, outside an uncommitted enclosing
transaction. Allocation alone is not a durable reservation. The journal's active
FileID reservation and worker exclusion remain required; this API provides no
lease, takeover, ownership registry, or database locking.

Before publication, a crash may leave staging or only an allocated journal
locator. After publication but before a verified journal transition, the recorded
locator identifies the target for operator inspection and integrity verification.
After publication, a journal failure retains that target. Retrying publication
against an existing target fails rather than overwriting or accepting its bytes.
Operators must reconcile ownership, source evidence, target hashes, journal
state, and worker quiescence before recovery; no automatic takeover or cleanup
is provided. Filename, age, or mere existence never proves ownership or integrity.

Atomic visibility follows existing hard-link semantics. File fsync does not
establish directory-entry durability after host/power failure. Directory fsync,
backend durability, persistent mounts, and cross-replica visibility remain
deployment review requirements. No persistent storage is assumed deployed.

Stage 5C-2 still needs authorized source verification, copying, independent
source/staging/target hashes and sizes, journal transitions, concurrency control,
and interrupted-copy tests. Stage 5C-3 still needs guarded locator cutover and
post-commit verification. Neither is implemented here.

## Validation

The standalone filesystem suite (`ruby test/services/document_storage_test.rb`)
passes with 47 tests and 205 assertions. Ruby syntax checks and `git diff --check`
also pass. Added tests use synthetic temporary roots, including destination and
root replacement during inspection, restrictive permissions, caller exception
preservation, and existing `write` file compatibility. No actual project
documents were inspected. Rails and Docker tests were not run. Future integration
validation can run lifecycle regressions in an isolated disposable test database:

```sh
docker compose -f docker-compose.yml run --rm web bundle exec ruby test/services/document_storage_test.rb
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails db:prepare
docker compose -f docker-compose.yml run --rm -e RAILS_ENV=test web bin/rails test test/services/document_creation_test.rb test/services/document_revision_test.rb test/services/document_deletion_test.rb test/models/legacy_document_migration_journal_test.rb
```

Stop for review before implementing migration copying.
