# Private document storage: Novel Minds deployment handoff

Branch: `test-codex`. Prepared: 2026-11-05. **For review; deployment is not cleared.**
This document proposes readiness gates and responsibilities. It authorizes no
deployment, database migration, document migration, cleanup, or live data access.
Live architecture, datasets, schema, backup coverage and runtime correctness
remain unconfirmed. Checked-in Kubernetes, Compose and Nginx examples are source
evidence only; they do not establish the live deployment.

## Evidence and implementation status

Read together with the [deployment plan](./private-document-deployment-plan.md),
[final verification](./private-document-final-verification.md),
[migration plan](./legacy-document-migration-plan.md), and
[operator reconciliation contract](./legacy-document-migration-reconciliation.md).
The migration plan records an earlier design stage. Later
[journal](./legacy-document-migration-journal.md),
[copy](./legacy-document-migration-copy.md),
[cutover](./legacy-document-migration-cutover.md), and reconciliation documents
describe implemented single-document APIs; final verification reconciles the
stages. Earlier statements that integration is future work are historical.

Implemented in source:

- Private filesystem publication and authorized Rails delivery; uploads and
  generated HTML/PDF use the document creation service.
- Locked revision, review and signing workflows publish new private versions;
  old bytes remain. Deletion removes access/attachments and defers physical cleanup.
- Inventory includes unscoped references; reports do not authorize deletion.
- Durable migration runs/attempts, database-time claims and fencing, explicit
  single-document verified copy, locator-only transactional cutover, and inspection
  plus separately approved recovery. No automatic runner or production operator
  execution facility is supplied.
- Final verification records a fix retaining published bytes after uncertain
  database commit outcomes, with regression tests added.

**Local testing completed.** The full Rails test suite was executed against the
local Docker SQL Server test environment: **869 tests, 5609 assertions, 0 failures,
0 errors, and 91.57% line coverage**. Focused document creation, revision,
migration cutover and reconciliation tests also passed. These are completed local
runtime results, in addition to the Ruby syntax and whitespace checks reported by
the cited implementation stages.

These results do not establish staging acceptance. Staging-specific concurrency
and independent-connection lock behavior, actual connection-loss and ambiguous
commit behavior, cross-replica visibility/durability, deployed HTTP delivery and
containment, and operational recovery/restore verification remain outstanding
gates. Local test coverage does not confirm the live topology, schema, mounts or
backup coverage, or clear any deployment or migration approval.
This documentation-only update records completed testing; it runs
`git diff --check` and does not rerun Rails/Docker tests or execute migrations.

## Storage and delivery contract

`DocumentStorage` is a custom filesystem service, independent of Active Storage
cloud configuration. `FileDrafts.FileURLPath` stores a locator, not a public URL.
`privateDocuments/<uuid>.<extension>` maps directly into the configured private
root; `privateDocuments` is not an extra directory beneath it. New publication
uses private staging, mode `0600`, file `fsync`, exclusive atomic hard linking and
staging-link removal. It does not overwrite an existing destination. Filesystem
publication and database commit cannot be atomic; retained staging, historical
versions and uncertain publications require reconciliation rather than cleanup.

Rails authenticates and authorizes the record before resolving either private or
legacy locators. Viewing includes specified historical/side-conversation access;
there is no general administrator bypass. Soft-deleted drafts are excluded.
Delivery uses private/no-store and nosniff headers; non-PDF stored content has a
script-free CSP sandbox. Signature events also recheck authorization. These
application controls require staging verification through the actual serving stack.

### Production root and persistence

Novel Minds must explicitly set `DOCUMENT_STORAGE_ROOT` in production. It must
be an absolute, existing private directory outside the public tree. For example,
`/rails/storage/documents` is a candidate, **not a confirmed production value**.
Mount the actual directory: symlinks in the root, ancestors or document paths
are rejected. Boot and asset compilation can succeed without usable storage;
the service does not create the root or verify the runtime mount at boot.

All Rails replicas, document-using workers, background jobs, one-off maintenance
tasks and any later authorized migration process must see the same durable
dataset at the agreed root within that environment. New bytes written by one
client must be immediately readable by the others. Use separate staging and
production datasets. Container writable layers, `emptyDir`, per-replica disks,
sticky sessions and a database-only PVC do not meet this requirement. A multi-host
deployment needs a shared filesystem with demonstrated multi-client semantics;
an RWX label alone is insufficient evidence. A single-host alternative requires
explicit approval of its availability and recovery limitations.

Novel Minds must provision and verify:

- Actual mount identity and failure detection, so an absent volume cannot silently
  accept writes into a local fallback directory; persistence across replacement,
  rolling rollout, node rescheduling and host loss as appropriate.
- Compatible numeric file-owner identity across readers/writers. Image UID/GID
  `1000:1000` is repository evidence only; confirm runtime identity. With `0600`
  files, group membership or `fsGroup` alone is insufficient. Restrict directory
  owners and ancestors; exclude hostile filesystem writers.
- Hard links, permission operations, sync, exclusive publication and cross-client
  visibility. File `fsync` alone does not prove directory-entry or power-loss
  durability. Approve any additional durability work before execution.
- Capacity for per-record copies of shared legacy sources, historical versions,
  staging, retained duplicates and backups; capacity/I/O/permission/missing-file
  alerts and named responders. Object storage requires a separate application
  design unless all required filesystem semantics are demonstrated.

## Preserve legacy bytes and block public delivery

Legacy `userFiles/<filename>` locators still resolve at
`Rails.root/public/userFiles`. There is no separate configurable legacy root.
`DOCUMENT_LEGACY_READS_ENABLED` accepts exactly `true` or `false` and defaults to
`true`; keep authorized legacy reads available through migration and the approved
rollback window. Disabling reads can break downloads and reconciliation and does
not prove that source files are absent.

Before replacing containers/images or introducing mounts, Novel Minds must locate
and durably preserve authoritative legacy and existing private bytes across all
hosts, replicas, volumes and possible image-local copies. A new mount can hide
existing files. Reconcile conflicting copies through an approved restricted
manifest/checksum process; do not assume one pod or checkout is authoritative.
Make preserved legacy bytes available internally at the existing lookup path on
every required client, preferably through a read-only mount. Freeze all legacy
writers or establish an approved immutable source snapshot before copying.
Missing, unsafe, zero-byte, unsupported-extension and nonconforming locator cases
must remain explicit exceptions. Preserve originals and historical private bytes;
no move, rename, overwrite or deletion is authorized here.

The Rails blocker runs before Rails static serving, but cannot protect requests
served upstream. Novel Minds must deny direct legacy namespace access at every
applicable Nginx location/alias, reverse proxy, ingress, static server, CDN, cache,
alternate hostname and origin. Denial must cover authenticated and anonymous
GET/HEAD/Range requests and encoded, decoded, normalized and traversal variants.
Keep private storage outside static aliases and public mounts. Purge previously
cached legacy responses and prevent direct-origin bypass; disabling directory
listing alone is insufficient. Verify ordinary public assets still work.

Review build contexts, old images and public origins for embedded legacy data;
durably preserve the authoritative source before excluding/replacing it. Image
exclusion and cache purge require approved infrastructure work, not an assumption
that Rails denial removes copies. See the
[HTTP access review](./legacy-document-http-access.md).

## Database migrations and SQL Server gates

Schema installation and document locator migration are separate operations.
Novel Minds must compare deployed migration history/schema with the selected
release and review all pending migrations before any approved schema operation.
The document journal uses these two ordered migrations:

1. `20261105010000_create_legacy_document_migration_journal.rb`: run/attempt tables,
   unique run identifier and active per-FileID reservation, run FK, optimistic
   locking, evidence/state/lease constraints. There is intentionally no FileDraft
   FK: evidence must survive document deletion.
2. `20261105020000_add_source_evidence_to_legacy_document_migration_attempts.rb`:
   complete structured source identity evidence and range/state checks. It refuses
   installation when published_verified, committed or verified attempts already
   exist; those require explicit source-evidence reconciliation. Never fabricate
   evidence or bypass the refusal to complete a rollout.

Development must prepare the schema compatibility review; Novel Minds must
approve and operate the separate backed-up migration process. Do not rely on the
old schema dump as proof of deployed constraints. Verify integer FileID matching,
bigint IDs/ranges, decimal(20,0) device/inode evidence, nanosecond ranges, indexes,
FKs, CHECK constraints and binary hash validation on actual SQL Server.

Confirm Rails/SQL Server adapter versions, collation and exact locator comparison,
`SYSUTCDATETIME()` deserialization/precision, top-level transactions, rollback and
commit callbacks, and `WITH (UPDLOCK, ROWLOCK, HOLDLOCK)` behavior on independent
connections. Validate revision/deletion versus cutover races and ambiguous commit
handling. Hashing holds run/attempt/draft locks; approve bounded database waits,
file-size/lease limits and stop thresholds. No automatic lease renewal, deadlock
retry or bounded waits are supplied by these services. Restrict/audit direct SQL,
bulk writes and validation bypass: journal constraints are not an append-only,
tamper-proof approval history. Do not drop evidence tables as routine rollback.

## Backup, restore and rollback requirements

Novel Minds owns an approved, demonstrated recovery procedure before cutover:

- Back up SQL Server including journal state, the entire private root including
  historical/orphan bytes, and every authoritative legacy source. Git and image
  rebuilds are not document backups; database export alone omits document bytes.
- Establish a coordinated recovery point, preferably by quiescing every writer
  and deleter and allowing transactions to finish before DB/filesystem snapshots,
  or use an explicitly reviewed equivalent consistency protocol. Independent
  live snapshots are not automatically consistent.
- Set encrypted independent/off-host backup storage, access/key custody,
  retention, immutable/version protection where approved, monitoring and failure
  ownership. FCMC/sponsor approves retention, RPO/RTO and acceptable data-loss risk.
- Restore into isolation with matching code/configuration, restore DB/journal and
  private/legacy bytes from the agreed point, preserve ownership/modes, verify
  restricted checksums and reconcile references before enabling writes. Prove
  synthetic authorized delivery, denial and lifecycle behavior; record measured
  recovery time and recovery point against RTO/RPO.

Before release retain the prior image digest/configuration, coordinated recovery
point and verified source copies. Prefer pausing and repairing forward for storage
problems. A compatible prior application must understand private locators and use
the approved storage; reverting to legacy-only code is unsafe. After new writes,
reverting the root/mount can strand bytes: stop writers, preserve both datasets,
reconcile references and approve the authoritative dataset before rollback.

Per-record locator rollback requires separate approval and journal evidence: verify
the original source hash/size, lock/reload the draft and restore its old locator
only if the exact current locator is still that attempt's private target. Preserve
other fields and both copies; never undo later signing/revision or recreate deleted
rows. The reconciliation service does not provide automatic locator rollback.
Full coordinated restore is disaster recovery and needs explicit sponsor approval
for losing subsequent writes. No volume deletion or cleanup target belongs in a
rollback procedure.

## Required staging acceptance with synthetic documents

Development prepares cases and records results; Novel Minds supplies an isolated
SQL Server database and representative storage/serving topology and operates
infrastructure checks. No production documents or credentials belong in fixtures
or reports. The staging checks below remain future approved work. The completed
local Rails/SQL Server suite and focused tests recorded above provide local
evidence; they do not satisfy this representative staging acceptance matrix.

| Test group | Required evidence before acceptance |
| --- | --- |
| Schema and service integration | Apply/review migrations in isolation; validate constraints, claim fencing, database UTC, independent-connection locks, rollback and uncertain commit/callback behavior; run relevant Rails suites serially where required. |
| User workflows | Synthetic upload, HTML/PDF generation, download/inline preview, review, both-party signing, revision and deletion. Creator/eligible participant access works; unrelated/anonymous and soft-deleted access fails; verify documented historical access and no-store/sandbox behavior. |
| Shared storage | Write on replica A, read/preview on B, revise/sign on B, read on A; workers/jobs verify identical bytes and permissions. Repeat after replacement, rollout and cross-node rescheduling. Test absent/wrong mount, permissions, disk-full/I/O failure and durability expectations. |
| HTTP containment | Known synthetic legacy and private bytes cannot be fetched directly through any edge/origin/cache/hostname or encoded-path variant; authorized Rails legacy delivery still works on every replica; ordinary assets work. |
| Migration and interruption | Explicit single-record copy, cutover and verification preserve exact bytes, originals, metadata/attachments and deletion/signing state; exercise publication/DB failure boundaries, changed sources, later revisions, expired claims, stale workers and approved/denied recovery. Include revision/deletion versus cutover races and real connection uncertainty. |
| Recovery | Coordinated backup and isolated restore of DB/journal/private/legacy/historical bytes; verify references, checksums, authorization and RPO/RTO. Rehearse compatible application rollback and guarded per-record rollback without deleting copies. |

Record release/image, schema, topology, synthetic fixture identifiers, results,
exceptions and named sign-offs in restricted evidence. A failing or missing gate
blocks the corresponding deployment/execution approval.

## Safe handling of migration interruptions

An expired lease is not proof a worker stopped. Database fencing does not stop
in-flight filesystem I/O. Stop admission, stop or externally fence old workers,
freeze legacy writers and retain all source, staging, target and journal evidence.
After any database exception/connection loss, inspect the authoritative database;
never infer rollback, retry copying, reset attempts or clear reservations blindly.

Use explicit single-attempt inspection to classify durable state and exact
source/target evidence. Missing/corrupt bytes, changed references, incomplete
evidence and conflicting mappings require investigation, not overwrite or adoption
of files inferred from names/age. Reconciliation never starts/retries copying,
enumerates/adopts orphans, or deletes files.

Only a separately authenticated operator with trusted policy approval bound to
the fresh attempt/fingerprint/action may request recovery, with explicit stopped
workers, frozen source and authoritative DB attestations. Depending on verified
evidence, recovery can finalize publication, perform guarded cutover or verify an
already committed mapping. Live-claim recovery needs valid credentials; expired
recovery uses its distinct operator path and advances the fence. Each subsequent
step needs fresh inspection and approval. Released/unclaimed/interrupted-run
attempts remain inspection-only through this service. Do not use low-level
maintenance APIs as a substitute for authorization.

Independent operator authentication, persisted approval audit, restricted reports
and evidence access are still integration prerequisites. A worker token alone
never authorizes recovery. Terminal run completion alone is not migration
acceptance: repeat a complete unscoped inventory, account for later activity and
resolve every unexplained legacy reference/exception. Verify current targets on
every required client. Legacy-read disablement and any later cleanup require
separate approvals after reconciliation and the rollback window.

## Responsibilities and required confirmations

| Owner | Deliverable / confirmation |
| --- | --- |
| Development team | Explain source contracts and remaining gaps; prepare reviewed configuration proposals for the confirmed platform, schema compatibility review, synthetic acceptance cases and operator/rollback runbooks. Implement any separately approved operator policy/audit integration. Record actual test results and resolve failures; do not equate static checks with runtime acceptance. |
| Novel Minds | Confirm live topology/deployment mechanism and every reader/writer; identify/preserve datasets; select/provision durable storage, explicit root, identities and mounts; implement edge/static/CDN denial/cache purge and build hygiene; operate approved schema changes, backups/restores, monitoring and worker fencing; name deployment/recovery operators and provide redacted acceptance evidence. |
| FCMC/sponsor | Confirm intended historical document access, retention and legacy exception policy; approve maintenance/user impact, RPO/RTO and data-loss tradeoffs, costs/availability limitations where applicable, production release and separate data-migration scope. Approve legacy-read retirement and any later deletion independently. |

Novel Minds must confirm each infrastructure/database/recovery item above with
named ownership and evidence before deployment. Development signs off technical
validation; Novel Minds signs off operational controls; FCMC/sponsor approves
business impact and the release. Silence or elapsed time is not approval.

### Questions for Jackson and Oscar

Please identify who owns each answer and provide redacted evidence, without
sharing credentials, environments dumps or document contents.

- [ ] What platform actually runs staging/production, and which replicas, workers,
  jobs, origins and deployment pipeline access or modify documents/locators?
- [ ] Where are all authoritative private/legacy copies today, including any
  host/image-local copies, and how will they be preserved before replacement?
- [ ] What absolute root, durable shared backend/mounts, runtime UID/GID, capacity
  and mount-loss checks will every client use? What proves durability and sharing?
- [ ] How will legacy bytes remain internally available at `public/userFiles`,
  and who can enforce the source freeze or immutable snapshot?
- [ ] Which Nginx/proxy/ingress/static/CDN/origin paths need denial and cache purge,
  and who will verify all hostnames and build-image exposure?
- [ ] What SQL Server/adapter versions, collation, migration history and schema
  are deployed? Who approves schema changes and lock-wait/lease policies?
- [ ] Who owns coordinated DB/private/legacy backups, restore drills, recovery
  keys, retention and agreed RPO/RTO? When can synthetic restore be demonstrated?
- [ ] Who authenticates/approves recovery, persists decisions and stops/fences
  workers? Who owns exceptions, rollback decisions and out-of-hours response?
- [ ] What staging window, acceptance evidence and maintenance window can be
  agreed, and who provides Novel Minds and FCMC/sponsor approval at each gate?

## Proposed deployment sequence and explicit checkpoints

Each gate requires recorded affirmative approval; this sequence is a proposal.
Application rollout and existing-document migration have separate approvals.

1. **Review gate:** Development and Novel Minds review this handoff and answer
   the open questions. FCMC/sponsor confirms access/retention policy, recovery
   objectives, impact and approval owners. Do not schedule live changes until
   architecture, authoritative sources and preservation plan are agreed.
2. **Staging authorization gate:** Novel Minds approves isolated provisioning and
   schema/test work. Development prepares reviewed changes for the confirmed
   platform. Provision synthetic private/legacy datasets, mounts, HTTP denials,
   monitoring, operator controls and coordinated recovery. No live dataset use.
3. **Staging acceptance gate:** Execute the synthetic matrix, SQL Server failure/
   concurrency tests and restore/rollback rehearsal. Development and Novel Minds
   review results and close blockers; FCMC/sponsor approves unresolved business
   exceptions explicitly. Failed or absent evidence stops progression.
4. **Production change approval gate:** Review exact release, pending migrations,
   preservation manifest, backups, restore evidence, write fence, stop thresholds,
   rollback compatibility and window. Novel Minds approves the infrastructure/DB
   runbook; FCMC/sponsor approves release impact. No automatic document migration
   may be attached to startup, deployment or background jobs.
5. **Controlled infrastructure/schema and application rollout:** Authorized Novel
   Minds operators preserve every current source before mount/image changes,
   establish the coordinated recovery point under the approved write fence,
   provision/verify mounts and HTTP denial, and apply separately approved schema
   changes. Deploy compatible dual-locator code to every reader/writer. Use agreed
   synthetic canaries to verify mount identity, authorized legacy/private delivery,
   sharing and denial. Stop on mismatch; do not discard old sources.
6. **Traffic approval checkpoint:** Development reviews canary evidence; Novel
   Minds confirms all replicas/jobs and recovery controls; FCMC/sponsor approves
   resuming service under the agreed impact plan. Monitor errors, capacity and
   visibility with a named rollback decision-maker. This approval does not
   authorize document migration.
7. **Separate document-migration approval gate:** Only after runtime acceptance,
   approve a restricted inventory/source manifest, exception policy, source freeze,
   capacity, lease/size/lock limits, authenticated operator workflow and recovery
   evidence. Begin with explicitly approved single-document scope and inspect
   copy/cutover/verification results before approving expansion. Any batch tooling
   requires separate design, review and authorization; none is created here.
8. **Reconciliation and retention gate:** Reconcile the complete inventory and
   journal, verify targets across clients and resolve exceptions. Development and
   Novel Minds submit evidence for FCMC/sponsor acceptance. Keep originals and
   legacy reads through the approved rollback period. Disabling legacy reads or
   deleting any originals/historical/staging/orphan bytes is separate future work
   requiring explicit review and approval.

Stop for review. This document provides no deployment or migration authorization.
