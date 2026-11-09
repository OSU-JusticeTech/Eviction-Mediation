# Private document final verification

Branch: `test-codex`. Source review only; deployment is **not cleared**.
No real documents, credentials, or `web.vars` contents were accessed. No migrations,
Rails/Docker tests, production commands, commits, pushes, merges, or deployments
were performed. The pre-existing `web.vars` modification remains untouched.

## Findings by severity

| Severity / category | Finding and disposition |
| --- | --- |
| Critical code defect — fixed | `DocumentCreation` treated a transaction exception without commit/rollback callbacks as permission to delete the published file. A lost commit acknowledgement can leave a committed locator pointing at deleted bytes, including during revision/signing. Removed that fallback after transaction invocation begins; uncertain publications are retained and their locator logged for restricted reconciliation. Explicit rollback callback cleanup remains. |
| High deployment blocker | Durable, shared private storage and preservation of authoritative legacy bytes are unverified. The checked-in Kubernetes Rails deployment has two replicas without document mounts; staging shares a host storage bind but declares no legacy bind. A database PVC does not preserve document bytes. |
| High deployment blocker | Edge/static/CDN denial, cache invalidation, build-image legacy exclusion, source immutability, database access controls, and coordinated restore capability require Novel Minds confirmation. Rails alone cannot establish these protections. |
| High verification gap | Current Rails/SQL Server integration and concurrency tests were not executed. Static checks cannot establish adapter transaction semantics, actual schema constraints, lock behavior, or uncertain-commit recovery. |
| Medium integration/documentation | Earlier stage documents and the initializer comment describe integration/copy/cutover as future work, although later services implement them. Read later copy, cutover and reconciliation documents as implementation contracts; earlier stage statements are historical, not execution authorization. |
| Medium operational limitation | Reconciliation has a trusted approval-callable boundary, not a deployed authenticated operator interface or append-only approval audit. Production policy, operator identity, approval persistence and restricted evidence access are prerequisites. |

No additional confirmed critical code defect was established in the reviewed paths.
This is conditional source-level assurance, not a claim that runtime workflows pass.

## Document lifecycle traced

1. **Creation:** upload, generated HTML, and generated PDF controller paths use
   `DocumentCreation`. `DocumentStorage` validates an absolute private root outside
   public storage, restricts filenames to one component, rejects symlink roots,
   writes temporary bytes, applies mode 0600, fsyncs the file, and publishes with
   exclusive hard linking. A collision cannot overwrite the destination.
   Database callbacks coordinate rollback cleanup; interruption can retain orphans.
   The fix preserves bytes when a transaction exception has no outcome callback.
2. **Viewing:** login and `FileDraft.find_viewable_by` precede storage resolution
   for show/download/inline preview. Authorization includes creator, attached
   message sender/recipient and historical primary/side conversation membership;
   soft-deleted drafts are excluded. There is no general admin bypass. Historical
   access is intentional, not limited to active conversation assignment.
   Delivery sets private/no-store and nosniff; stored non-PDF content receives
   CSP sandbox without scripts. PDF retains native viewer behavior. Editable
   preview separately checks conversation/edit eligibility and renders templates.
   Signature Cable subscriptions recheck authorization for each transmitted event.
3. **Revision:** `DocumentRevision` locks/reloads the persisted draft, reads its
   current locator, publishes a fresh private version, and saves metadata and
   locator transactionally. Old bytes remain. Review acceptance and signing use
   this service; dirty/stale records cannot silently replace the locked version.
4. **Signing:** controller rechecks authorization and eligibility under the draft
   lock, checks agreement version, pending suggestions and duplicate signature.
   `AgreementSignature` accepts recognized HTML and exactly one unsigned slot,
   escapes names, and preserves other bytes. Signature metadata and new locator
   save together. Notifications happen after persistence; later notification
   failures can still make a completed operation appear unsuccessful to a user.
5. **Deletion:** `DocumentDeletion` locks the draft and authorizes creator or
   primary conversation party, destroys attachments transactionally and soft
   deletes where supported (otherwise destroys the draft). Physical cleanup is
   deliberately deferred, including hard-delete orphans; legacy bytes are retained.
   View permission is broader than deletion permission by existing policy.
6. **Inventory:** `DocumentFileInventory` includes unscoped references and reports
   referenced, unreferenced, missing, unsafe and legacy locators. Legacy inventory
   observes both configured roots and shared/soft-deleted references without reading
   contents. Reports fail rather than return partial success and never authorize
   cleanup. Enumeration is observational, not an atomic database/filesystem snapshot.

## Legacy migration lifecycle traced

1. **Inventory → journal:** restricted inventory is an input to a trusted caller;
   there is no automatic admission bridge. Explicitly create a running run and
   planned per-FileID attempt with exact locator and approved source identity.
   Unique `(file_id, reservation_key)` prevents concurrent active attempts;
   run FK, state/evidence/lease/range checks and optimistic locking protect row shape.
   Source-evidence migration refuses successful old attempts requiring reconciliation.
2. **Claim:** `claim!` requires a top-level transaction, locks run then attempt,
   uses database UTC and issues token/generation only after transaction return.
   Guarded APIs require matching state/token/generation and live lease/running run.
   Expiry and release never permit automatic reacquisition. Generation-zero
   journal compatibility APIs are trusted maintenance primitives, not worker access.
3. **Copy:** explicit `LegacyDocumentMigrationCopy#call` requires a fresh planned
   claim and matching FileID. Checkpoints lock run → attempt → draft and compare
   exact locator bytes. Safe no-follow source opening pins an inode, rejects unsafe
   links/types, and records complete write-once source evidence before target allocation.
   Target ownership is journaled before publication; source, staging and published
   target size/SHA-256 are checked, including source rereads and stat stability.
   Zero-byte or unsupported-extension sources stop. Failures retain evidence and
   published bytes; they never recopy, delete, or guess a failed journal transition.
4. **Cutover:** explicit `LegacyDocumentMigrationCutover#call` requires
   published_verified, validates evidence, locks in the same order, checks the
   current exact legacy locator and independently hashes the safe private target.
   Locator-only update and committed journal transition share one transaction;
   affected row count must be one, and expiry is rechecked after hashing.
   Callbacks, signing flags, attachment metadata and timestamps are bypassed/preserved.
5. **Reconciliation:** inspection hashes exact journal source/target and detects
   conflicting references, with no writes or adoption of orphans. Recovery requires
   a fresh fingerprint/action, independent trusted approval policy, stopped workers,
   frozen source and authoritative DB attestations. Live recovery requires the
   matching claim; expired recovery advances the fence before writes. It can
   finalize publication, cut over, or verify committed mapping, but never copy,
   retry, delete, or restore a later revision. Released/unclaimed/interrupted-run
   attempts are inspection-only through this service. Terminal verification closes
   the reservation; finishing a run alone does not prove all documents migrated.

Existing code supports reviewed single-document invocation through these APIs.
It is not a production execution facility: caller authorization, admission,
source freeze, lease sizing and recovery policy must be supplied. No batch runner
or production execution command was added.

## Security boundaries and accepted limitations

- No direct legacy access through the configured Rails middleware stack was found:
  the blocker precedes `ActionDispatch::Static` and rejects decoded/normalized
  legacy paths, including traversal and encoded separators. Prove equivalent
  denial on every deployed proxy, origin, alternate hostname and cache separately.
- Locators cannot express absolute paths, nesting, traversal or non-ASCII aliases.
  Roots and ancestors reject symlinks. Descriptor migration inspection is stricter
  than ordinary pathname-based download/revision; `resolve`/`send_file` do not pin
  an inode or enforce single-link/0600 checks. Trusted directory ownership and
  exclusion of hostile filesystem writers are required for both paths.
- Exclusive publication prevents overwrite. Normal deletion does not unlink bytes.
  Creation rollback removes only its fresh publication. Uncertain transactions
  retain bytes; they require authoritative inspection, not automatic retry/cleanup.
  Actual driver behavior, including callbacks on lost commits, needs failure testing.
- Fences prevent stale database mutations through guarded APIs, not filesystem I/O
  by an already running process. Recovery must stop or externally fence workers.
  Lease expiry after the last check but before commit remains possible.
- Revision and cutover serialize on the same draft row: revision first changes the
  locator and cutover rejects it; cutover first makes revision reload private bytes.
  Copy checkpoints also detect locator changes. All deployed writers must obey
  this protocol; no hostile/direct SQL writer protection is claimed.
- Evidence is immutable through validated APIs. CHECK constraints enforce current
  shape, not historical immutability or transition history. Direct SQL, bulk writes,
  validation bypass and privileged DB access can change it; journal tables are
  not tamper-proof or append-only. Restrict and audit those capabilities.
- File fsync does not prove directory-entry/power-loss durability. Filesystem and
  database commits cannot be atomic. Historical versions/staging/orphans remain;
  inventories do not prove safe deletion. Hashing holds locks, lock waits are not
  bounded here, and run locking serializes work. Capacity and lease policy matter.
- Existing `maximum + 1` ID allocation can reject concurrent creations through a
  key collision. It is not redesigned here. Document index visibility is narrower
  than direct authorized historical/side-conversation delivery; existing policy
  should be confirmed rather than changed during this security review.

## Tests, changes and validation

Changed: `app/services/document_creation.rb`,
`test/services/document_creation_test.rb`, and this report.
Added regressions simulate lost commit acknowledgement without outcome callbacks
and a transaction failure before yielding; both require publication retention.
Existing tests cover explicit/nested rollback cleanup, immutable publication,
authorization, HTML sandboxing, signing/review, deletion, inventory, journal
constraints, claims, copy interruptions, competing cutovers and reconciliation.

Missing targeted coverage: actual independent-connection revision-versus-cutover
and deletion-versus-cutover races; real connection loss during commit and callback
delivery; deployed sendfile/static/proxy behavior; cross-replica filesystem crash
durability and restore. Competing-cutover tests alone do not establish these.
New and existing Rails tests remain **unexecuted**, as requested.
Ruby syntax checks for both modified Ruby files and `git diff --check` passed.

## Novel Minds prerequisites before staging or production

- Confirm actual topology, all deployed document/locator writers, adapter/Rails
  versions, schema types (including integer FileID), SQL Server collation, database
  UTC deserialization, transaction callbacks, lock hints and bounded wait policy.
  Authorize isolated synthetic integration/concurrency/failure tests and review
  their results. Confirm both journal migrations and generated constraints/schema
  through a separate approved migration process; the old schema dump is insufficient.
- Identify and preserve authoritative private and legacy datasets from every host
  and replica before replacement/mount changes; approve source snapshot/freeze and
  exception handling for missing, unsafe, zero-byte, shared or nonconforming paths.
- Provision an explicit absolute private root outside public, durable and shared
  by every reader/writer, with real nonsymlink mounts, trusted ancestors, compatible
  numeric owner IDs (0600 files), capacity and verified hard-link/fsync/visibility
  semantics. Confirm mount-loss detection and crash durability. Boot alone is no check.
- Preserve durable legacy access at `public/userFiles` for required replicas, with
  writers frozen during migration. Confirm legacy-read configuration; disable it
  only after complete reconciliation and rollback-window approval.
- Deny public access at every serving layer, verify encoded/traversal variants using
  synthetic files, purge exposed caches and review legacy data in build contexts,
  old images and alternate origins. Keep private storage outside static aliases.
- Approve coordinated DB/private/legacy backups including retained versions, access
  controls, encryption, retention, RPO/RTO and demonstrated isolated restore.
- Name authorized operators; supply independent authentication/approval policy,
  durable decision audit, restricted journal/report/log access, worker stop/fencing
  procedure, authoritative DB inspection after uncertainty, lease/size limits,
  stop thresholds and rollback criteria. Restrict direct evidence mutation.
- Deploy dual-locator-compatible code everywhere and demonstrate synthetic upload,
  generation, preview/download, review, both-party signing, deletion, inventory,
  copy/cutover and approved/denied reconciliation. Approve historical access and
  retained-file policy. Any later execution or cleanup needs separate authorization.

Stopped for review. No automatic migration or cleanup is enabled by this report.
