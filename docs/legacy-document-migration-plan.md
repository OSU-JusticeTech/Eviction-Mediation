# Stage 5A: legacy document migration — audit and design

Status: proposed design for review; no migration implementation or execution.
Branch: `test-codex`. Baseline: `257f9486`. Date: 2026-11-05.

## Scope and evidence boundary

This is a source audit and a design for a later, explicitly approved stage.
No database queries, document directory scans, document content reads, copying,
renaming, deletion, Rails/Docker tests, or deployment changes were performed.
Credentials and `web.vars` were not read or modified. Its pre-existing working
tree modification remains untouched. Actual file counts, missing files, deployed
schema, mount topology, and authoritative legacy sources remain unknown.

Source references:
[storage](../app/services/document_storage.rb),
[configuration](../lib/document_storage_configuration.rb),
[initializer](../config/initializers/document_storage.rb),
[inventory](../app/services/document_file_inventory.rb),
[creation](../app/services/document_creation.rb),
[revision](../app/services/document_revision.rb),
[deletion](../app/services/document_deletion.rb),
[FileDraft](../app/models/file_draft.rb), [schema](../db/schema.rb),
[controller](../app/controllers/documents_controller.rb),
[signature channel](../app/channels/document_signature_channel.rb), and their
service, model, controller, channel, and middleware tests. Related plans are
[storage foundation](./private-document-storage-foundation.md),
[private cleanup](./private-file-cleanup.md),
[legacy HTTP protection](./legacy-document-http-access.md), and
[deployment prerequisites](./private-document-deployment-plan.md).
Earlier foundation/initializer comments describe the pre-integration phase;
current controller calls establish that private storage is now integrated.

## Current-state findings

- `FileDrafts.FileURLPath` is the persistent document locator field found in
  the schema and application storage paths. It is non-null, allows 500 characters,
  and has no uniqueness constraint. Storage permits only 255 bytes. `FileID` is
  the primary key. `UserDeletedAt` marks soft deletion; it does not erase a
  reference. Creator deletion can cascade to drafts.
- Attachments contain FileID/MessageID, not independent locators. Agreements,
  links, mail, and channels resolve by FileID. Agreement terms/proposals are
  domain data. No persistent historical document-version registry exists.
  Arbitrary message text, HTML, PDFs, and backups are not authoritative current
  locator fields and must not be parsed by this inventory.
- All unscoped draft rows count: unattached, signed, unsigned, active, and
  soft-deleted. Filtering by visible documents, attachments, current users, or
  active conversations would miss references. Historical hard-deleted references
  cannot be reconstructed from current rows; their bytes may remain unreferenced.
- `DocumentFileInventory` already queries unscoped FileID/locator pairs, groups
  shared references, enumerates immediate private entries, and fails rather than
  returning a successful partial report. Valid legacy locators are only listed:
  their existence, safety, soft-deletion status, and unreferenced legacy files
  are not determined. Its report is observational, not a deletion authorization.
- Storage accepts exact `userFiles/` and `privateDocuments/` prefixes followed
  by one ASCII filename component beginning with an alphanumeric character;
  allowed remaining characters are alphanumerics, underscore, dot, space, and
  hyphen. Any `..`, separators, encoding tricks, unknown prefixes, or excess
  length are rejected. Never normalize a rejected locator into an accepted one.
- Legacy resolution uses `Rails.root/public/userFiles`, with reads enabled by
  default. Disabled legacy reads raise MissingFile even if bytes exist; that is
  a configuration state, not evidence of physical absence. Production private
  storage requires an explicit absolute root outside public. Roots/ancestors and
  final symlinks are rejected. Trusted, operator-owned directories are required
  because pathname checks alone cannot prevent hostile replacement races.
- `resolve` accepts readable regular files but does not reject multiple hard
  links. Private inventory is stricter (`lstat`, regular file, one link). A
  migration needs equivalent strict source inspection and safe descriptor opening;
  calling `resolve` alone does not supply the complete migration safety policy.
- `write`/`store` publish fresh private files with UUID names, private staging,
  mode 0600, file fsync, and an exclusive atomic hard link, without overwriting.
  `CleanupFailure` carries the completed destination when staging unlink fails.
  Directory fsync and durable progress tracking are not supplied by this API.
- Creation coordinates publication and transactional DB work, including enclosing
  rollback cleanup. Revision reloads and locks the draft, publishes a replacement,
  and saves locator and metadata together. Signing and agreement changes also
  use row locks. Deletion locks the draft, removes attachments transactionally,
  soft-deletes where supported, and defers physical cleanup. Legacy bytes and
  superseded private versions are retained.
- Delivery authorizes the record before resolving either locator format and
  uses noncacheable responses. Soft-deleted documents are excluded by the shared
  viewing lookup. Rails denies direct legacy HTTP requests; upstream denial and
  deployment persistence are still awaiting infrastructure review. Migration
  does not remove that exposure because originals remain.

## Read-only inventory design

Implement a separate explicit audit operation, or extend the current inventory
without changing its read-only contract. Default operation must inspect metadata
only: no byte reads, hashes, writes, callbacks, mkdir, file traversal through
symlinks, or cleanup. A later migration verification operation will read bytes
to compute hashes; it is distinct from this inventory and was not run here.

1. Validate configured roots and actual runtime schema before collecting results.
   Capture environment/source identifier, application revision, schema version,
   start/end times, scan ID, legacy-read configuration, and coverage/completeness.
   Missing/unreadable roots are scan failures, never empty directories. Support
   deployed schemas without UserDeletedAt by explicitly reporting its absence.
2. Read every `FileDraft.unscoped` row with FileID, exact FileURLPath, and
   UserDeletedAt where available. Do not join attachments or filter statuses.
   Use a consistent DB snapshot approved for the SQL Server adapter, or label
   live batched results as potentially changing and repeat under quiescence for
   final acceptance. Do not enable database isolation settings implicitly.
   For large datasets use keyset batches and a restricted on-disk report/index,
   rather than holding every row in memory. Fail the run on an incomplete query.
3. Classify exact locator values into valid legacy, valid private, and invalid/
   unknown, including nil/empty defensive cases and 256–500-byte values. Preserve
   exact values in a restricted manifest; do not URL-decode, strip, case-fold,
   truncate, or infer paths from FileName/FileTypes. Detect case/space aliases
   under actual DB collation and filesystem semantics; quarantine ambiguous
   mappings rather than merging them. SQL equality may differ from Ruby equality.
4. Enumerate immediate entries of each operator-identified legacy root and the
   private root with lstat, without recursion or following links. Record regular
   file metadata (size, device/inode where meaningful, link count, mtime), absence,
   unreadability, and unsafe entry types. Symlinks, dangling links, directories,
   special files, multiple hard links, and invalid filenames are blocked findings.
   Permission/I/O errors must not masquerade as missing files. Distinguish an
   incomplete scan from a complete scan containing explicitly classified errors.
5. Join exact reference groups with observed entries. Include per-source results
   when replicas/hosts have separate legacy directories. A file missing on one
   host and present on another is a topology conflict, not global absence.
   Never select an authoritative copy by timestamp or filename alone.

The restricted manifest should include these overlapping report sections and
counts (reference counts and unique-locator counts must be separate):

| Section | Required information |
| --- | --- |
| Legacy DB references | Every FileID, exact locator, active/deleted classification |
| Unique legacy locators | Exact locator, all referring IDs, source coverage/status |
| Missing files | Valid referenced locator absent at a successfully inspected source |
| Invalid/unsafe locators and entries | Reason code; no unsafe path resolution; unknown namespaces included |
| Shared locators | All referring IDs, active/deleted counts; aliases flagged separately |
| Unreferenced legacy files | Immediate regular entries with no observed DB reference; retain |
| Soft-deleted references | Deleted IDs and locators, including groups shared with active rows |
| Existing private references | All IDs and shared groups, present/missing/unsafe status; excluded from migration |

Include private unreferenced entries for reconciliation with existing inventory.
Unreferenced legacy/private files may be historical or in flight: no section is
a deletion list. Reports must state their non-atomic filesystem/DB observation
window. Reconcile row totals across classifications and locator-group totals;
publish a success summary only after all required sources and queries complete.
Console output should contain aggregate counts, run IDs, and reason codes only.
Locators may contain personal information; keep raw names, IDs, hashes, and
manifests access-controlled, encrypted/backed up, and outside web/static trees.
Escape untrusted names in machine-readable output and spreadsheet exports.

## Migration algorithm (proposed)

Use a resumable operator job, not a schema migration or application startup hook.
Process one FileID per short database transaction. Recommended first execution
uses a write-quiesced maintenance window; online operation requires the concurrency
tests and writer audit below. Include soft-deleted rows. Skip existing private
references. Do not copy unreferenced files automatically.

The simplest proposed shared-locator policy is **one fresh private copy per
FileID**. This preserves every record's bytes without introducing a shared target,
group-wide locks, or cleanup coupling. Inventory still groups and reports source
sharing. Extra capacity is an explicit tradeoff requiring approval. Deduplicating
destinations would require a separate shared registry/locking design.

1. Create a durable migration run and per-record attempt in a restricted DB
   journal, independent of draft deletion cascades. Store run/attempt IDs, FileID,
   exact expected old locator, source identity, target locator when known, size,
   SHA-256, state, timestamps, and sanitized error code. Never store contents,
   extracted terms, signature names, or exception messages containing paths.
   Enforce one active attempt per FileID with database uniqueness/claiming, and
   use an operator lock/lease to prevent competing runners. Schema and access
   policy for this journal require separate implementation approval.
2. Validate the expected source locator and extension before publication. Preserve
   the original extension, including case where supported by the storage API;
   `write` lowercases it, so explicitly approve that metadata effect or block
   case-sensitive exceptions. Extension must satisfy storage's 1–10 lowercase
   alphanumeric rule after normalization. Missing/unsupported extensions require
   review; do not guess from document bytes or FileTypes. Zero-byte files should
   be reported and blocked pending policy, not silently repaired or dropped.
3. Resolve the validated source beneath the approved legacy root; reject symlink
   ancestors and final links, nonregular files and link count other than one.
   Open read-only with no-follow semantics where supported and verify fstat
   against lstat identity. Require an immutable/read-only source snapshot or an
   enforced freeze on all legacy writers. Stat comparisons alone cannot prove
   that bytes were not changed concurrently. Do not chmod or modify sources.
4. Stream the open source into `DocumentStorage.write` staging in binary mode,
   calculating source SHA-256 and byte count. Independently read/hash staging and
   compare both before the block returns. Validate source identity/stability
   again; any change blocks the attempt. Do not render, parse, sanitize, re-sign,
   transcode, or regenerate the document. Publish with existing exclusive-link
   semantics. Catch CleanupFailure and use its published locator; record the
   residual staging condition, without publishing a second copy blindly.
5. Resolve and hash the completed destination, checking size/hash against source
   evidence and requiring a safe private entry. Journal it as `published_verified`
   in a committed transaction before any draft update. Preserve the copy across
   DB failures for reconciliation; no migration cleanup automatically unlinks it.
6. In a top-level transaction, lock/reload `FileDraft.unscoped` by FileID, then lock
   the attempt in a consistent order. Require exact byte/string equality with
   the expected legacy locator in application code after locking, not just a SQL
   predicate subject to collation. Recheck destination availability and verified
   identity. If the row disappeared or locator changed, mark `gone`/`superseded`
   and leave the row alone. A changed soft-delete timestamp alone does not exclude
   it: migrate the still-referenced source without restoring visibility.
7. Update only FileURLPath with a guarded affected-row check; atomically mark the
   journal `committed` with old/new mapping and verification evidence. Proposed
   implementation uses a deliberate locator-only update without model callbacks
   or timestamp changes, after explicit validation. Require review of this choice
   and exact-update semantics on SQL Server. Preserve every signature flag/name/
   time, AgreementVersion, terms/proposal, CreatorID, CreatedAt, UserDeletedAt,
   attachment, and conversation. No emails or broadcasts should result.
8. After commit, verify the row and private target again, and record verification
   separately. Stop on unexpected missing/corrupt targets or systemic failures.
   Keep originals and all newly published copies. Repeat inventory and reconcile
   every candidate into committed, already-private, superseded/gone, or explicitly
   blocked outcomes; exceptions are not successful migration.

## Transactions, concurrency, and reuse

Reuse `DocumentStorage.write`/`store` for binary copying, root/path validation,
permissions, and exclusive publication, with the stricter source checks above.
Reuse the row-lock/reload and enclosing-transaction lessons in DocumentRevision
and DocumentCreation. Do not call DocumentRevision directly: it reads the complete
source into memory and performs a revision save without a migration journal.
Do not use DocumentCreation unchanged for persistent resumable copies: its
rollback cleanup could remove a target that recovery expects to retain.

Filesystem publication and DB commit are not one transaction. The journal state
change and locator update must commit together; an after_commit callback alone
cannot be the only durable progress record. Disallow invocation within arbitrary
outer transactions so a savepoint cannot be mistaken for final success.

Copy before taking the draft lock to avoid holding it for large file I/O. Final
comparison under the lock prevents overwriting a newer revision/signature:

- If revision/signing commits first, migration observes a new locator and skips.
- If migration commits first, the existing revision service reloads the row
  under lock and reads the private bytes before producing its new version.
- If deletion commits first, migrate the soft-deleted reference without changing
  deletion state; if hard-deleted/cascaded, skip the vanished row. If deletion
  follows migration, its current deferral policy retains the private bytes.
- Attachments continue to refer to the same FileID. No permission changes follow
  from a migration. Existing downloads can finish against preserved originals.

Audit every deployed writer, raw SQL task, and historical application version.
All locator mutations must acquire compatible row locks or use a proven guarded
update; no writer may restore stale legacy locators. Row locks alone cannot stop
new rows reusing legacy locators or protect absent references. Require legacy
locator creation to cease, or quiesce these writers and perform a final full
inventory before claiming completion. Source immutability is a separate gate.
Use bounded lock waits and transactions, consistent lock order, and bounded
deadlock retries; never acquire conversation locks after holding migration locks.
Validate Rails/SQL Server locking behavior with real independent connections.

## Failure, retry, and interruption recovery

Proposed states: `planned`, `copying`, `published_verified`, `committed`,
`verified`, `blocked`, `superseded`, `gone`, and `rolled_back`; attempts retain
their history and sanitized failure codes. Claims need bounded leases and
operator-controlled stale-claim recovery.

| Failure window | Recovery |
| --- | --- |
| Before publication | DB remains legacy; retry after source/root checks; report abandoned staging metadata |
| Published before journal target is durable | Treat unknown copy as retained orphan; do not infer ownership from filename/age; a retry may create another verified copy |
| Published target journaled, DB unchanged | Rehash target/source evidence, lock/recheck row, reuse the journaled target |
| Connection lost during commit | Read journal and row from authoritative DB before retrying; never assume rollback |
| DB committed, post-check interrupted | Atomic journal mapping proves transition; verify target and current row; do not revert later revisions |
| Missing/unsafe/changed source | Block without DB update; operator reconciliation required |
| Target absent/corrupt or journal/row inconsistent | Stop affected work; investigate storage/restore, do not replace evidence silently |

The current API generates the target name internally, so a crash immediately
after publication can leave an unjournaled orphan. This design tolerates retained
duplicates for safety, but does not claim exactly-once publication. A requirement
for complete attribution of every copy would require a separately reviewed API
that durably reserves the target before publication. No guessed orphan cleanup
is permitted. Interrupted runs must not reset journal rows wholesale.

## Verification checklist

These checks are future execution requirements, not results of this audit.

- [ ] Preflight inventory complete across every authoritative legacy source and
  private mount; DB/schema and root identity recorded; exceptions reviewed.
- [ ] Approved backup/restore point covers DB, journal, legacy, and all private
  bytes, including historical versions. Restore demonstrated in isolation.
- [ ] Source, staging, and published target sizes and SHA-256 match for every
  migrated record. Hash bytes without logging them; retain restricted evidence.
- [ ] Original legacy bytes remain at the same paths with matching hashes;
  migration has not changed their contents, permissions, or names. Source reads
  may affect atime unless infrastructure prevents it; do not promise otherwise.
- [ ] Reconcile journal committed counts with DB mappings, accounting separately
  for later revisions/deletions. No metadata/attachment changes or notifications.
- [ ] Repeat full unscoped inventory; zero unexplained legacy references is the
  completion criterion. Missing/invalid/blocked cases remain explicit exceptions.
- [ ] Verify all migrated current targets, not only a sample, from every serving
  replica/worker that may access them. Compare root/mount identity, size/hash,
  ownership and 0600 readability across clients; verify after restart/reschedule.
- [ ] With synthetic documents, authorized creator/participant download and inline
  preview work; anonymous and unrelated users are denied; soft-deleted access
  stays denied; signing/review still use the same record and version rules.
- [ ] Authorized HTTP delivery returns the expected synthetic bytes and no-store
  headers. Direct private and legacy namespaces remain denied through every
  origin, CDN, hostname, method, and encoded-path variant identified in Stage 3.
- [ ] Verify durable visibility before DB references are exposed. Validate hard
  links, fsync and directory-entry durability on the selected filesystem; define
  any required additional durability barrier before production migration.

## Rollback strategy

Prefer pause and repair forward for storage availability problems. Pausing stops
new claims and lets active transactions finish; it never deletes published copies.
Keep dual-format authorized reads and legacy bytes available throughout review.

For an explicitly approved per-record rollback, use the journal mapping, verify
the original source still has its recorded size/hash, then lock/reload the draft.
Only if its exact current locator is the migration target may a transaction
restore the old legacy locator and mark the journal rolled_back. Preserve all
other fields and retain the private copy. A row now pointing to a revised/signed
version must be skipped: restoring its old locator would lose newer bytes even
if metadata were preserved. Do not recreate hard-deleted rows or undo soft deletion.
Use the same guarded update, concurrency, audit, and post-verification procedure.

Rollback requires legacy reads and cross-replica source availability, plus all
HTTP denials. It does not justify making the directory public. Application rollback
must retain compatibility with private locators and the approved mount; an older
release that only understands legacy paths is unsafe. Full DB/filesystem restore
is disaster recovery, requiring a coordinated point and approval for loss of
subsequent writes; it is not routine migration rollback. No automatic original
or target deletion is part of rollback or completion.

## Test plan for later implementation

Use only synthetic fixtures in isolated roots. No tests were run in Stage 5A.
Existing tests cover storage validation/publication/cleanup failures, nested
transaction rollback, stale revision reloads, deletion retention, unscoped/shared
inventory, route authorization, signing, and HTTP blocking; their presence does
not establish that this migration or real multithreaded locking is tested.

Add coverage for:

- Complete inventory of active, signed, unattached, soft-deleted and shared rows;
  existing private references; unknown/oversized/empty locators; schema variants;
  absent roots, query failures, unreadability, incomplete multi-source coverage,
  case/collation aliases, and large batched scans. Assert no writes or content reads.
- Safe-path handling for traversal, nested/encoded paths, symlink ancestors and
  final/dangling links, hard links, special files, source replacement, invalid
  extensions and zero bytes. Never follow unsafe paths, block rather than repair.
- Byte-exact copying of binary/PDF/HTML fixtures, independent digest comparison,
  source preservation, private permissions, per-record copies of shared sources,
  and preservation of all metadata, deletion state, and attachments.
- Failures at each journal/publication/transaction boundary, CleanupFailure,
  hash mismatch, disk-full/I/O failure, DB rollback, deadlock, ambiguous commit,
  process termination, stale claims, duplicate runners, restart and target reuse.
  Prove no DB reference to unverified bytes and no deletion of originals/targets.
- Real SQL Server independent-connection races with revision, signature, soft/
  hard deletion and creator cascade; conditional rollback after later revisions;
  exact locator comparison despite DB collation; no callbacks/notifications.
- Synthetic multi-client filesystem tests for publication visibility, ownership,
  restart durability and missing mount failure; controller/channel authorization
  regression and external HTTP tests. Rails/Docker suites belong to the later
  authorized validation workflow, not this documentation stage.

## Deployment prerequisites

Novel Minds must first review and approve Stage 4 infrastructure. Identify the
live deployment and every source of legacy bytes (including possible image-local
and host-local copies). Reconcile conflicting copies using approved restricted
checksums; do not assume the checkout or one replica is authoritative. No rollout
may discard a source before it is durably preserved.

Provision a persistent private root shared by all required replicas/workers and
the migration job, outside public, with compatible numeric ownership for mode
0600. Verify mount presence rather than accepting a writable container fallback.
Legacy sources must be safely readable and frozen against writes. Confirm storage
capacity for per-record copies, staging, retained duplicates, and backups. Approve
durability guarantees, monitoring, bounded rate/batch settings and stop thresholds.

Require coordinated backups, journal backup/access controls, demonstrated restore,
edge/origin legacy denial and cache handling, a compatible dual-format release
on all replicas, and a named operator with maintenance-window and recovery access.
Do not disable legacy reads merely because a migration run ended: complete
reconciliation and rollback-window approval come first. Original-file retention
and eventual cleanup remain a separate stage with separate approval.

## Open questions and approval gates

Before implementation:

1. Approve the per-FileID copy policy, soft-deleted inclusion, and capacity cost,
   or commission a shared-target registry design.
2. Approve the journal schema, access/retention policy, states, claim mechanism,
   and retained-orphan tradeoff; decide whether pre-reserved publication targets
   and storage durability API changes are required.
3. Approve locator-only callback-free updates and the missing/unsafe/zero-byte/
   extension exception policy. Nonconforming historical paths require a separate
   reconciliation design, never relaxed traversal checks.
4. Choose maintenance-window execution (recommended initially) or approve online
   operation after deployed-writer audit and actual concurrency validation.

Before production execution:

5. Novel Minds confirms authoritative sources, schema/collation, persistent shared
   mounts, source immutability, cross-replica visibility/durability and HTTP denial.
6. Approve backup/restore evidence, operator/run scope, restricted checksum access,
   batch limits, stop criteria, exception resolution and rollback window.
7. Decide when a complete reconciled inventory permits legacy-read disablement.
   Approve any later original/historical-file deletion separately; this plan never
   authorizes it.

Stage 5A stops here for review. Implementation, live inventory, checksum reads,
copying and DB locator updates all require a subsequent authorized stage.

## Stage 5C-2A-3 implementation checkpoint

Attempt claiming/fencing APIs and synthetic independent-connection race coverage
are implemented for review; see the [claim lifecycle and recovery contract](./legacy-document-migration-journal.md#stage-5c-2a-3-durable-attempt-claims-and-fencing).
SQL Server update locks serialize claim acquisition and guarded mutations, with
database UTC expiry checks. Expired/interrupted/released claims require explicit
operator reconciliation; no takeover or retry is automatic. Historical unclaimed
journal APIs remain compatible, while claimed rows require fenced mutations.
Only Ruby syntax and diff whitespace checks were run; SQL Server tests remain a
review gate. This does not authorize copying, cutover, background execution,
DocumentStorage changes or deployment.
