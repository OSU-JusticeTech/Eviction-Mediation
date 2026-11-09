# Private document storage foundation

This foundation is not connected to controllers. It does not close the existing
public-file exposure, change routes or authorization, or migrate historical files.

## Configuration

The initializer configures `Rails.application.config.x.document_storage`:

| Setting | Behavior |
| --- | --- |
| `DOCUMENT_STORAGE_ROOT` | Absolute private filesystem directory. Development defaults to `storage/documents` beneath Rails.root; tests default to `tmp/document-storage`. Production requires an explicit value when the service is used. |
| `DOCUMENT_LEGACY_READS_ENABLED` | Exactly `true` or `false`; defaults to `true`. |

The private directory must already exist and be writable by the application user.
The service does not provision it. Configuration and application boot do not
create directories, read documents, or probe write permissions. Configuration
validation occurs on service construction; filesystem availability is checked
on each operation. This allows asset compilation without a runtime storage mount.

Private storage must be outside the public tree: it cannot equal `public` or be
a descendant of it. An ancestor of `public` is allowed. Symlink roots, ancestors,
and document files are rejected during operations. Storage directories must be
controlled by the application/operator, not writable by untrusted users; pathname
checks do not protect against an attacker concurrently replacing directories.

## API and integration contract

`DocumentStorage.configured` constructs a service from Rails configuration.
Tests and other isolated callers can pass `configuration:` directly.

- `store(io:, extension:)` streams bytes into private storage and returns a locator.
- `write(extension:) { |path| ... }` gives a generator a private staging path and
  publishes a unique final file only when the block succeeds. Publication never
  overwrites an existing destination. Staging must be a regular file with one
  hard link; symlinks and shared hard links are rejected before permissions change.
- `resolve(locator)` returns a validated readable path. It does not read the bytes.
- `delete_private(locator)` removes only private files; it returns false for an
  already missing file. It never deletes legacy files.

New locators are `privateDocuments/<uuid>.<extension>`. The prefix is logical:
it maps directly into the configured private directory, never beneath `public`.
Legacy `userFiles/<filename>` locators resolve under `public/userFiles` when legacy
reads are enabled. Filenames must be a single ASCII component containing letters,
digits, spaces, dots, underscores, or hyphens, beginning with a letter or digit,
with no `..`; total locator length is at most 255 bytes. Nonconforming historical
locators require separate inventory and reconciliation. Private locators never
fall back to legacy files.

The service has no record or user knowledge. A caller must authorize the record
before resolving a locator, and must never publish a storage locator as a URL.
It must coordinate database state with storage: publish complete new bytes, save
the new locator with the agreement state, and clean up the unreferenced private
file if the database transaction fails. Never delete the old version before the
transaction commits. Process crashes can leave private orphans for reconciliation.
Historical originals remain untouched when a caller writes a revised version.
The API does not perform automatic replacement, migration, or old-version cleanup.

If staging cleanup fails after publication, `DocumentStorage::CleanupFailure`
reports the completed file's `locator`. The published file is preserved; callers
can use that locator for database coordination or reconciliation without retrying
publication. Generation and publication errors remain primary if cleanup also
fails, and cleanup never removes a completed destination.

Other errors are `DocumentStorage::InvalidLocator`, `MissingFile`, and `Unavailable`;
configuration errors use `DocumentStorageConfiguration::InvalidConfiguration`.
Filesystem error responses omit actual paths. Controller response mapping,
noncacheable downloads, legacy HTTP blocking, and physical legacy cleanup belong
to the next integration review.

## Focused verification

Run `ruby test/services/document_storage_test.rb`. This test file deliberately
does not require Rails test_helper: it does not boot Rails, load dotenv or
credentials, connect to a database, or use real documents. Each test owns and
cleans up a temporary filesystem sandbox.

The suite covers writes, generator failures, permissions, legacy preservation,
missing-file behavior, disabled legacy reads, path and symlink rejection,
configuration, typed I/O failures, and retryable private deletion.
