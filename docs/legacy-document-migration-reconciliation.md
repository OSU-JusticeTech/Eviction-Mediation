# Single-attempt operator reconciliation

This service inspects one durable attempt, never a batch. It creates no files,
retries no work, removes nothing, and leaves all recorded source/publication
identity, size and hash evidence unchanged. No CLI, job or environment execution
is enabled. The existing journal transitions and database constraints are retained.

`LegacyDocumentMigrationReconciliation.new(storage: ...).inspect_attempt(attempt_id:)`
is read-only, including when evidence is unsafe. It takes database locks and
reads/hashes only the journal's exact legacy and private paths through storage's
safe descriptor APIs. It does not enumerate or adopt orphans. The returned frozen
report contains outcome, source/target observations, lease classification, an
optional recovery action and an inspection fingerprint. Restrict report access:
hashes and filesystem identities remain sensitive. Repeated inspections against
unchanged evidence return identical reports; expiry can change the report.

| Outcome | Required evidence / operator response |
| --- | --- |
| `copy_never_started` | Planned state, no source bundle or publication evidence, exact legacy draft reference and readable safe source. Inspect only; this service never starts a copy. |
| `copy_interrupted_before_publication` | Copying state, exact legacy reference, safe unchanged source where recorded, private target absent or unallocated. This describes observed absence, not proof that staging never existed. Retain staging/attempt; no recopy or closure here. |
| `published_unfinalized` | Copying state; complete original source stat bundle; journaled target, positive size and SHA-256; safe source and private bytes both match the journal. Approved `finalize_publication` records `published_verified` without recopy or draft changes. |
| `private_verified_database_pending` | Same complete matching file evidence, published_verified journal, exact legacy draft locator. Approved `cutover` performs one guarded locator-only update and records committed atomically. |
| `database_cutover_completed` | Exact private draft locator, committed or verified journal mapping, complete matching source and target evidence. Approved `verify_cutover` advances committed to verified without repeating the draft update. Already verified is inspection-only. |
| `source_changed_or_disappeared` | Missing draft/source, changed exact draft reference, or changed source identity. Stop; investigate authoritative source and later document activity. No automatic locator restoration or closure. |
| `ambiguous` | Hash mismatch, unsafe files, incomplete evidence for publication, conflicting target references (including SQL collation aliases), or journal/private mapping inconsistency. Stop; retain all bytes and journal rows for restricted manual investigation. |

Recovery is separate: `recover(attempt_id:, inspection_id:, action:,
worker_token:, generation:, approval:, workers_stopped:, source_frozen:,
authoritative_database:)`. First obtain a report, review it, then invoke recovery
with its exact fingerprint and action. `approval` must be a trusted caller-supplied
policy callable accepting the frozen decision context and returning exactly true.
The integration must authenticate an operator independently of worker credentials,
bind approval to that attempt/fingerprint/action, and keep the policy outside
untrusted request parameters. A worker token alone never authorizes recovery.
There is no default approval policy. The policy must perform no database writes,
external side effects or long interactive waits while locks are held.

The caller must explicitly attest that old workers are stopped, legacy writers
are frozen (or the immutable source snapshot is authoritative), and database reads
are authoritative after any uncertain commit. These are operational prerequisites,
not facts discoverable from a lease or a local file stat. Inspection itself does
not require these attestations or authorize execution.

Both entry points reject enclosing transactions, lock run then attempt then draft
with the existing SQL Server update/hold lock hints, and reload durable evidence.
The service owns an explicit top-level transaction and returns only after that
transaction completes. A rollback escaping the operation is converted to a
failure inside the locks, before a joined lock transaction can swallow it and
allow earlier writes to commit. Incomplete lock results are rejected before
commit; journal reloads inside the transaction check consistency, not durability.
Recovery repeats inspection under those locks and rejects stale fingerprints. The
existing `recover` entry point requires a live matching worker claim and running
run. For an expired claim, use the separate operator-only entry point:

```ruby
service.recover_expired_claim(attempt_id: id, inspection_id: report[:inspection_id],
  action: report[:action], approval: trusted_operator_policy,
  workers_stopped: true, source_frozen: true, authoritative_database: true)
```

This requires the same independent operator authentication and explicit stopped
or externally fenced worker attestation. Expiry is never proof of worker death.
No worker token is required for this operator path; a trusted approval policy is
mandatory. The frozen policy context identifies `recovery_path` as `expired_claim`
(or `live_claim` for the original API). Inspection offers the same evidence-based
actions for expired and live claims, but an action is never authorization.

After approval, both paths reload and reinspect journal, run, draft and filesystem
evidence under the locks and reject any change. For expired claims, the service
checks database UTC expiry, advances and verifies the persisted fencing generation
before any draft update or recovered journal transition, all in the same
transaction. Its private model scope permits only publication finalization,
cutover or verification without a live lease, and is cleared on every exit.
It issues no worker credentials, renews no lease and leaves expiry unchanged.
Every subsequent operator step requires a fresh inspection and approval. Live
recovery retains its guarded transitions and generation advancement. Verification
clears the claim and closes the reservation using existing transition rules.

Released, unclaimed and interrupted-run attempts remain inspection-only. Worker
`claim!` still cannot acquire an expired or previously claimed attempt. Neither
path starts or retries copying, reopens blocked attempts, or fabricates evidence.
Do not invoke the older low-level `reconcile_claim!` merely because this report
exists; it remains a trusted maintenance primitive, not operator authorization.

Any database exception means the transaction outcome is uncertain to the caller;
there is no compensating journal write or automatic retry. Reconnect to the
authoritative database and inspect again under a fresh explicit operator decision.
An atomic committed mapping is recognized; a private locator with an uncommitted
journal state is ambiguous. Never infer rollback from an exception. Missing or
corrupt private files require storage investigation, never overwrite or deletion.
Disabled legacy reads can appear as missing source and intentionally prevent
recovery. Later revisions and historical verified mappings are never reverted.

Synthetic tests cover planned inspection, interruption before source open, after
allocation, after digest recording and after publication, approved target reuse,
cutover and completed mapping verification, credentials/approval/attestation
rejection, stale inspections and expiry, mismatched/missing files and references,
rollback after database writes, approved and denied expired-claim recovery, stale
worker rejection, changed evidence, and independent competing live/expired recoveries. They use
only temporary files and synthetic committed rows in a disposable SQL Server test
database. They were added but **not run**, per task instructions. Only Ruby syntax
and whitespace checks were run; these do not establish runtime correctness.

Remaining limitations: real SQL Server locking/rollback/commit uncertainty tests
are unexecuted; no bounded database lock waits are configured here; hashing holds
locks; the live recovery path needs sufficient lease duration. Filesystem and database changes cannot
be atomic. Trusted directories, writer exclusion, shared mount visibility and
publication durability remain deployment prerequisites. The journal is a current
state record, not a new append-only approval audit; production operator identity,
approval persistence and policy integration remain future reviewed work. No
production/staging operations or deployment authorization is provided.
