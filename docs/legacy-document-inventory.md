# Stage 5B: read-only legacy inventory

`LegacyDocumentInventory` is a separate explicit service. The existing
`DocumentFileInventory` API and tests are unchanged. No controller, scheduled
job, startup hook, deployment configuration, or migration invokes this service.
Implementation has only received Ruby syntax checks and whitespace validation;
Rails/Docker tests and live inventory have not been run.

The service uses the configured legacy and private roots, independently of
whether legacy delivery is enabled. Every `FileDraft.unscoped` row is queried,
without attachment, signature, or soft-deletion filters. If `UserDeletedAt` is
absent from the runtime schema, deletion status is explicitly unknown.

The returned in-memory manifest contains `references` (one per row), `locators`
(exact value groups), filesystem `entries`, overlapping `classifications`, and
aggregate `counts`. Reference totals reconcile as legacy + private + invalid.
Classification counts count section items, not necessarily references; locator
groups carry all referring IDs and active/soft-deleted counts. Validity describes
locator syntax, independently of the observed file status.

| Classification | Meaning |
| --- | --- |
| valid_legacy_locators | Exact accepted userFiles locators, with present/missing/unsafe status |
| valid_private_locators | Exact accepted privateDocuments locators with the same status |
| invalid_or_unknown_locators | Rejected values; never used as filesystem paths |
| missing_referenced_legacy_files | Valid referenced legacy locator absent from a successful immediate directory listing |
| missing_referenced_private_files | Equivalent private finding |
| unsafe_legacy_entries / unsafe_private_entries | Invalid filename, symlink (including dangling), nonregular entry, multiple hard links, or no file read permission bits |
| shared_legacy_locators | Valid legacy locator referenced by more than one row |
| unreferenced_legacy_files / unreferenced_private_files | Safe regular immediate entries without an exact observed DB reference; retain them |
| soft_deleted_legacy_references | Individual soft-deleted rows with valid legacy locators, including shared groups |

Each filesystem entry includes lstat size, device, inode, link count, mode and
mtime. No document is opened, read, hashed, copied, updated or deleted. Names
are not normalized. Nested directories are unsafe findings and never enumerated.
All ancestor components are checked from the filesystem root down using lstat;
symlink ancestors and missing/unreadable roots fail. Roots must be absolute,
clean paths, nonoverlapping, and private storage must be outside public storage.
No directories or report files are created.

`complete: true` means the unscoped query and both configured immediate-root
scans finished. Unsafe findings do not make coverage incomplete. Any query,
enumeration, lstat or permission failure raises a generic `Failure` with no
partial report and no underlying exception cause containing sensitive paths.
There is no application logging in this service. The full return value contains
sensitive IDs and names: keep it in a restricted operator context, never log or
publish it, and escape untrusted names if exporting it. Only aggregate counts
are suitable for ordinary logs.

## Limits requiring operator review

- Permission-bit inspection does not prove effective readability for the running
  process. Ownership, group membership, ACLs and other access controls can affect
  access; the inventory does not open documents to verify readability.
- `atomic_snapshot: false`: the DB query and filesystem listing are live,
  separate observations. Files that disappear during lstat fail the run. Changes
  after observation can make results stale. No item authorizes deletion.
- `completeness_scope: :configured_roots_only`: this does not discover other
  hosts, replicas, mounts or historical sources, or prove root authority.
- Pathname lstat checks cannot eliminate hostile concurrent directory replacement
  races. Run only on trusted operator-owned directories, preferably quiescent
  or immutable mounts. Descriptor-relative traversal would require a separate
  platform-specific implementation for adversarial writable directories.
- Exact Ruby string grouping does not reconcile DB collation, case/space aliases,
  filesystem aliases or source conflicts. Those remain migration blockers for
  operator reconciliation. The manifest exposes device/inode metadata for review.
- Rows and entries are held in memory. Large-volume streaming, schema/revision
  attestations, multi-source reconciliation and persistent restricted manifests
  remain future work; this service does not claim the entire Stage 5A migration
  preflight design is implemented.

## Synthetic validation for review

Run in the isolated test environment with its test database prepared:

```sh
docker compose run --rm -e RAILS_ENV=test web bin/rails test test/services/legacy_document_inventory_test.rb test/services/document_file_inventory_test.rb test/services/document_storage_test.rb
docker compose run --rm -e RAILS_ENV=test web bin/rails test test/models/file_draft_test.rb
```

Tests construct temporary synthetic roots; they do not enumerate configured live
document directories. No migration/copying/hashing/deletion/locator update
operation is implemented by the inventory.
