# Reference-aware private-file inventory (Stage 2B-5)

This stage provides reporting only. No physical cleanup option, scheduled task,
metadata update, or legacy migration is implemented. Existing creation rollback,
revision, signing, and document deletion behavior is unchanged.

## Reference audit

The application's only persistent document locator field is
`FileDrafts.FileURLPath` (non-null string, schema limit 500; storage accepts up to
255 bytes). It has no uniqueness constraint, locator registry, or locator lock.
All rows count, including `UserDeletedAt` rows, signed agreements, and drafts
without attachments. Shared locators are allowed and every referring FileID is
reported. Creator deletion can cascade to drafts in the database.

`FileAttachments` stores only FileID and MessageID, with a composite primary key
and foreign keys to FileDrafts and Messages. Attachments and messages therefore
resolve through the same draft row; they do not carry independent paths.
Document links, broadcasts, and mailers use FileID. AgreementTerms and
AgreementProposal hold terms/review data, not storage locators. No persistent
document-to-document locator or historical version table was found in the
schema or application paths. Arbitrary text or uploaded file contents are not
parsed as references; they cannot establish an authoritative cleanup policy.

Creation paths in DocumentsController (templates, uploads, PDFs) use
DocumentCreation. Agreement review/revision and signing use DocumentRevision,
which assigns fresh bytes and replaces FileURLPath on the same locked draft.
The old bytes remain without a version-history database reference. Message and
mediator message creation attach by FileID. DocumentDeletion retains soft-deleted
rows and defers physical cleanup even on historical hard-delete schemas.

## Usage and report

In an authorized Rails console or runner environment:

```ruby
report = DocumentFileInventory.new.call
# Or inject DocumentStorage.new(configuration: ...) with a private test root.
```

The report has `dry_run: true`, `physical_deletion_enabled: false`, and arrays:

- `referenced_private_files`: present regular files with surviving draft rows.
- `unreferenced_private_files`: present regular files with no observed draft row.
- `missing_referenced_files`: valid private locators whose files are absent.
- `invalid_or_unsafe_locators`: malformed/unknown locators, symlinks (including
  dangling links), directories, hard links, and non-document/staging names.
- `legacy_references`: valid `userFiles/...` references, retained without probing
  the public filesystem, even when legacy reads are disabled.

Each item includes `locator` and all observed referring `file_ids`. The query is
`FileDraft.unscoped.pluck(:FileID, :FileURLPath)` without joins or status filters.
Filesystem inspection uses only immediate private-root entries and lstat;
it never reads document contents or descends into entries. Roots and ancestors
are checked for symlinks. Query or filesystem failures raise
DocumentFileInventory::Failure without returning a partial report. Missing roots
are failures, not empty inventories. Reports contain sensitive identifiers and
should stay in an operator-controlled location.

## Retention and concurrency

Retain every referenced file, including soft-deleted and shared references.
Retain all legacy files. Retain all historical versions indefinitely in this
stage, including versions superseded by revisions or signing. Unreferenced files
are investigation candidates only: they may be historical versions, in-flight
publications, failed rollback cleanup, or crash leftovers. There is no reliable
way to distinguish these cases with the current schema. No file is established
as safe to delete by this inventory, regardless of age.

The query and filesystem scan are not an atomic snapshot. A transaction can
publish bytes before committing a reference, or create/reassign a reference
after the query. Row locks on existing drafts do not protect absent/shared
locators. The report deliberately makes no concurrency safety claim and never
unlinks anything. Operator-owned storage directories are required; pathname
checks cannot prevent concurrent hostile replacement of ancestor directories.
Large inventories currently load references and immediate entries into memory.

## Recommended future cleanup procedure

First approve a historical/signed-version retention policy and introduce a
persistent version/locator registry, including retained historical versions.
Reconcile existing files into that registry without assuming absence of a
current draft reference means abandonment. Require every creator, revision,
reference reassignment, and cleanup worker to participate in the same locator
locking/tombstone protocol, including raw SQL and maintenance tools. A collector
must lock and recheck all references, prevent locator reuse, and defer filesystem
work until database commit so rollback preserves bytes. Design retryable cleanup
states for filesystem failures; enforce root containment and no symlink following
at deletion time. Only then add explicit opt-in physical cleanup with concurrency
and rollback tests. Repeated inventories or age thresholds alone are insufficient.

Regression tests: `test/services/document_file_inventory_test.rb`. The simulated
reference interleaving test demonstrates a stale report while preserving bytes;
it is not a database multithreaded locking test. Run Rails tests via the project's
Docker Compose test workflow. This stage was checked with Ruby syntax checks and
`git diff --check`; Rails/Docker tests were intentionally not run.
