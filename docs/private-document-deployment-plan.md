# Stage 4: private document deployment plan

Status: infrastructure audit and proposal only; deployment architecture awaits approval.
Audited branch: `test-codex`, baseline `a82fd9c1`. Date: 2026-11-05.

## Scope and evidence boundary

Findings below describe checked-in source, not Novel Minds' live infrastructure.
No live hosts, clusters, mounts, backups, document contents, credentials, or
`web.vars` were inspected. No Docker or Rails commands/tests were run. No
deployment configuration, application logic, or documents were changed.
An existing local modification to `web.vars` was left untouched.

Sources: [Dockerfile](../Dockerfile), [Dockerfile.dev](../Dockerfile.dev),
[development Compose](../docker-compose.yml),
[staging Compose](../staging.docker-compose.yml),
[Rails Kubernetes manifest](../k8s/rails-deployment.yaml),
[database Kubernetes manifest](../k8s/database-deployment.yaml),
[Nginx example](../nginx-config.conf), [Kamal configuration](../config/deploy.yml),
[storage configuration](../lib/document_storage_configuration.rb),
[initializer](../config/initializers/document_storage.rb),
[DocumentStorage](../app/services/document_storage.rb),
[Active Storage configuration](../config/storage.yml),
[entrypoint](../bin/docker-entrypoint), [Makefile](../Makefile),
[README](../README.md), [Kubernetes README](../k8s/README.md),
[developer manual](./_posts/2025-03-04-developer-manual.markdown),
[image workflow](../.github/workflows/image.yml), `.dockerignore`, and `.gitignore`.

## Confirmed repository findings

### Document paths and configuration

- Private locators use `privateDocuments/<filename>` but map directly to files
  inside the configured root; that prefix is not an additional directory or URL.
- Development defaults to `storage/documents` beneath Rails.root. Production
  requires `DOCUMENT_STORAGE_ROOT` explicitly, even if the desired path matches
  that default. Tests use a separate temporary root.
- The root must be absolute and outside the public tree. Storage operations reject
  symlinks in the root, its ancestors, and document paths. A symlink to a mounted
  directory is therefore unsuitable; mount at the actual configured path.
- Validation is deferred until service use. Boot and asset compilation can
  succeed while document operations fail. The service and entrypoint do not
  provision the private directory or verify the runtime mount.
- None of the inspected Dockerfiles, Compose files, Rails Kubernetes manifest,
  or Kamal configuration explicitly supplies `DOCUMENT_STORAGE_ROOT`.
  Compose references `web.vars`; its contents are deliberately unknown. Live
  environment injection and deployment overrides may supply the setting.
- `DocumentStorage` is a custom filesystem service. Configuring an Active Storage
  cloud service alone would not move these documents to cloud object storage.
- Publication uses a temporary file in the root, mode `0600`, file `fsync`, an
  atomic hard link to the destination, and temporary-link removal. The backend
  must support these operations and suitable cross-client visibility. Filesystem
  and directory durability guarantees still require infrastructure validation;
  file `fsync` alone is not evidence of end-to-end crash durability.
- Legacy reads default to enabled via `DOCUMENT_LEGACY_READS_ENABLED`. Legacy
  locators resolve under Rails.root's `public/userFiles`, independently of the
  private root. There is no configurable legacy root in this implementation.

### Persistence, permissions, delivery, and backups

- Both Dockerfiles run Rails as UID/GID `1000:1000` and make the image's storage
  directory writable by that account. They do not create the document subdirectory.
  A runtime mount replaces image directory ownership; image `chown` does not
  establish host-bind or persistent-volume permissions.
- Staging mounts the same host `./storage` at `/rails/storage` in web and Sidekiq.
  This can persist private files across container recreation on that host if the
  configured root lies there. It is a bind mount, not a document PVC or a named
  document volume. Host replacement and release-directory changes are separate
  risks. No staging legacy-directory mount is declared.
- Kubernetes declares two Rails replicas and no Rails document volumes,
  volume mounts, PVC, or pod filesystem permission policy. The database PVC is
  mounted only by SQL Server and does not persist Rails document bytes.
- The Nginx example proxies requests to Rails, without static filesystem aliases
  or explicit legacy namespace denial. Kubernetes uses a separate ingress path;
  this Nginx example is not proof of cluster ingress behavior.
- The Rails legacy HTTP blocker protects requests reaching Rails. An upstream
  static server, CDN, alternate origin, or public bucket can bypass it. See
  [legacy HTTP access review](./legacy-document-http-access.md).
- `.gitignore` excludes private storage contents and `public/userFiles`; source
  control is not their backup. `.dockerignore` excludes storage contents, so a
  rebuilt image cannot recover private documents. It does not explicitly exclude
  `public/userFiles`: legacy files present in a build context could be copied into
  an image by `COPY . .`. Whether any images contain them is unknown.
- The Makefile's database export/import handles SQL Server backups only. No
  private/legacy document backup schedule, restore procedure, or successful
  restore evidence was found in the inspected deployment materials. The developer
  manual lists production backup/recovery procedures as remaining work. This
  does not establish whether Novel Minds has external backups.
- README deployment instructions use Makefile-selected Compose configuration;
  its checked-in default is development Compose. Staging and Kamal files do not
  establish which deployment path is live. The image workflow builds/publishes
  images; it does not establish deployed storage or document backups.

## Environment-by-environment assessment

| Environment | Repository-defined storage | Recreation and sharing assessment | Verification still required |
| --- | --- | --- | --- |
| Local, without Docker | Default private directory under checkout; legacy under public tree | Survives process restart while checkout and disk remain; no external persistence or sharing established | Directory provision, local user permissions, overrides, disk backup |
| Development Compose | Entire checkout bound to `/rails`; database has its own named volume | Default private and legacy files survive web recreation in the host checkout; image permissions are hidden by bind mount | Host UID/GID compatibility, document directory existence, overrides, host durability |
| Standalone production image | No document mount declared by Dockerfile | An explicitly configured root in the container writable layer is lost on replacement and isolated per container; absent explicit setting causes document operations to fail | Actual run arguments, root, mount, directory creation, backup |
| Staging Compose | Host storage bind shared by web and Sidekiq; no legacy bind | Private files persist conditionally within mounted tree on same host; no cross-host sharing established; legacy may be absent or image-local | Root injection, stable host path, host replacement policy, ownership, legacy source, backup |
| Kubernetes / possible production | Two Rails replicas, no Rails storage volume; database PVC only | With a configured container-local root, replicas have independent files and replacement loses writes; without configuration, document operations fail | Actual manifests/overlays, CSI/storage class, shared filesystem, workload identity, live replicas |
| Kamal alternative | Named volume mounted at `/rails/storage`; configuration contains template details | Can persist files in that volume on a host if root points there; no multi-host sharing established | Whether used, actual host/volume lifecycle, root, backup, legacy storage |

The actual private document location, file counts, persistence, and backup coverage
in every live environment remain unconfirmed. No actual missing files or data
loss were established by this audit.

## Data-loss and availability risks

1. **Potential immediate loss on replacement:** any live private or legacy bytes
   held only in a container/pod writable layer can disappear during recreation,
   rollout, rescheduling, scaling down, or host maintenance.
2. **Replica inconsistency:** shared database references do not share bytes. A
   document created on one pod can be missing on another; sticky sessions are not
   a persistence or recovery solution.
3. **Silent deployment misconfiguration:** missing root, absent subdirectory,
   wrong ownership, or an unmounted directory can escape ordinary boot/HTTP health
   checks. A writable fallback directory can accept writes while the durable
   volume is missing.
4. **Bind/volume lifecycle:** a different Compose checkout can select an empty
   storage directory; a host-local volume does not survive host loss automatically.
   The Makefile cleanup target removes named volumes, including database storage;
   it is unsuitable for preserving a live environment.
5. **Incomplete recovery:** database-only backups restore references without
   bytes. Private-only backups omit legacy files; current-reference-only backups
   omit retained historical versions. Revision/signing leaves old bytes whose
   historical references are not recorded in a version table.
6. **Mount masking and legacy loss:** a new mount can hide files already present
   underneath it. Rebuilt images exclude private bytes and may lack the legacy
   files previously available to authorized routes.
7. **Exposure:** image-embedded legacy files, public origins, and cached copies
   require separate containment even when Rails blocks direct legacy URLs.

## Recommended architecture — proposed, not approved

Retain the current filesystem service with a durable private filesystem. For a
single-host staging environment, use a dedicated stable host data directory or
managed volume independent of the release checkout, mounted by web and workers.
For multiple production replicas, use a Novel Minds-approved managed shared POSIX
filesystem, exposed through a Kubernetes RWX-capable persistent volume that all
document-using pods mount. A single host's bind mount, per-pod volumes, `emptyDir`,
or a database-only PVC does not satisfy this design. RWO by itself does not
establish multi-node sharing; confirm the storage driver's actual capabilities.

Use one agreed absolute mount path outside the public tree as
`DOCUMENT_STORAGE_ROOT` everywhere in each environment. `/rails/storage/documents`
is a candidate compatible with existing storage mounts, not a selected live
value. Isolate staging and production datasets. Keep private storage inaccessible
to public/static servers; use the authorized Rails delivery routes.

Require the chosen filesystem to support hard links, permission changes, file
sync, atomic publication, and immediate visibility across clients. Avoid an
object-store FUSE mount unless those semantics are demonstrated. Native object
storage would require a separately designed and approved application adaptation.
If shared storage is unavailable, a durable single-replica deployment is an
explicitly approved interim option with availability limitations, not a complete
multi-replica solution.

Preserve legacy bytes in durable storage mounted at the application's existing
`public/userFiles` lookup path, available to every required replica, preferably
read-only for Rails. Deny external access at every ingress/static/CDN layer.
Moving legacy reads outside public requires a separate application change and
approval; disabling legacy reads now can break existing authorized downloads.
Do not remove legacy files or historical private versions during this stage.

## Required configuration changes and ownership

These are preparation items only. None is implemented by this document.

| Proposed change | Team can prepare for review after architecture selection | Novel Minds approval / implementation |
| --- | --- | --- |
| Explicit private root | Draft environment wiring for web, workers, maintenance jobs, and all replicas | Confirm runtime configuration mechanism and approved mount path; apply live settings without exposing values |
| Durable storage mounts | Draft Compose/Kubernetes/Kamal changes for the selected deployment path, including safe lifecycle rules | Select/provision service, storage class, capacity, zones, access mode, reclaim policy, costs, availability, and access controls |
| Directory permissions | Draft provisioning and verification procedure for UID/GID `1000:1000`, restricted ancestors, dedicated writable document directory | Validate actual runtime identity, CSI/NFS ownership behavior, root squashing, and platform permission policy; provision ownership |
| Mount and failure checks | Draft preflight checks that reject absent/wrong mounts and verify real filesystem operations | Approve rollout gates and monitoring; implement in live pipeline/platform |
| Legacy preservation and denial | Draft durable legacy mount and deny rules, with synthetic verification cases | Identify authoritative legacy bytes and all public delivery paths; implement edge/origin denial and cache purge |
| Build hygiene | Draft explicit exclusion of legacy document directories from build context after durable legacy delivery is ready | Review deployed image contents/access and approve image replacement plan; preserve authoritative bytes first |
| Backup/recovery | Draft coordinated database/filesystem runbook and restore acceptance criteria | Set retention, RPO/RTO, encryption/key custody, backup accounts, off-host copies, restore owner, and schedule |

File mode `0600` means matching group access alone is insufficient: writers and
readers across replicas must have compatible numeric owner identities. A pod
`fsGroup` alone cannot make those files group-readable. Use an operator-provisioned
restricted directory (for example owner-only access for the shared application
UID), protected parent directories, and no world-writable workaround. Do not rely
on a privileged startup recursive ownership change across existing documents.
Validate mount permissions and filesystem behavior on a synthetic dataset first.

## Backup and recovery considerations

- Back up database state, the entire private root including historical files,
  and all legacy bytes. Include soft-deleted references and retained versions;
  inventory results do not authorize deletion. See
  [inventory/retention constraints](./private-file-cleanup.md).
- Coordinate recovery points. Prefer an approved write-quiesced backup window
  covering every writer and deleter, database commit completion, and filesystem
  snapshots, or a documented equivalent consistency protocol. Independent live
  snapshots are not automatically consistent: publication can precede DB commit,
  and deletion/revision can race backups.
- Keep encrypted, access-controlled backups independent of application hosts and
  storage failure domains. Approve retention, immutability/version protection,
  monitoring, capacity alerts, recovery keys, and restore access. A PVC or storage
  snapshot alone is not proof of a complete independent backup.
- Restore into an isolated environment with the matching application version and
  configuration. Restore document bytes and database from the agreed recovery
  point, preserve ownership/modes, verify checksums, and reconcile referenced
  private/legacy files before allowing writes. Keep inventory identifiers and
  verification logs restricted; do not log document contents or secrets.
- Demonstrate authorized download, preview, revision, signing, and deletion with
  synthetic data, plus denied direct legacy access. Record measured restore time
  and data recovery point against approved RTO/RPO. Missing files require
  investigation; unreferenced files must not be automatically removed.

## Deployment verification checklist — future approved work

- [ ] Novel Minds confirms the actual deployment topology, all writers/readers,
  current root/mount mapping, legacy locations, and backup coverage using redacted
  evidence. Do not dump process environments or render secret-bearing Compose data.
- [ ] Preserve verified copies of every current private/legacy location, including
  replica-local files, before replacement or mount changes. Reconcile conflicting
  copies and missing references through a separately approved procedure.
- [ ] Approve storage architecture, ownership, retention, recovery objectives,
  cutover window, responsible operators, and rollback criteria.
- [ ] Provision the durable root and parent directories; verify UID/GID, mode,
  no symlink components, capacity, actual mount identity, and no public exposure.
- [ ] Verify identical explicit root configuration and access for every relevant
  web pod, worker, one-off job, and maintenance environment; absent mounts fail
  preflight rather than accepting writes into container-local directories.
- [ ] Using synthetic files, exercise create, hard-link publication, sync,
  read, and removal on the proposed backend as the runtime identity.
- [ ] Create a synthetic document on replica A; download/preview on B; revise/sign
  on B; read on A. Confirm byte identity and correct authorization throughout.
- [ ] Prove persistence through container replacement and pod rescheduling to a
  different node, then verify a rolling deployment and worker access. This audit
  does not authorize those operations on live data.
- [ ] Verify known existing synthetic legacy files through authorized routes on
  every replica. Deny anonymous and authenticated direct legacy GET/HEAD/Range
  requests, encoded/normalized paths, alternate origins, and CDN cache hits as
  described in the legacy HTTP review; verify ordinary public assets still work.
- [ ] Verify backup inclusion and a coordinated restore drill, including legacy
  and historical private bytes; confirm alerts and ownership of failed backups.
- [ ] Monitor missing-file/storage errors, permissions failures, capacity, and
  cross-replica visibility after cutover. Release only on recorded acceptance.

## Rollback considerations

Before cutover, retain the old locations, database recovery point, verified byte
copies, ownership metadata, deployment configuration, and image digest. Changing
the root alone does not migrate files. Any later copy/cutover needs its own
approved reconciliation procedure and a write fence across all application
instances and workers; avoid concurrent old/new storage writers.

After new writes begin, reverting the mount/root can strand those new bytes.
Pause writers, preserve both datasets, reconcile every reference, and agree on
which dataset is authoritative before rollback. Do not delete volumes or run
cleanup targets. Reusing the same durable storage with a compatible application
version may avoid a data-path rollback, but must be verified first.

Do not roll back to application versions that cannot resolve private locators or
that restore direct legacy HTTP exposure. Keep edge denials and cache protections
in place. If recovery requires an older database point, quantify lost committed
changes and obtain owner approval; keep all filesystem versions for reconciliation.

## Questions for Novel Minds

1. Which systems actually host development, staging, and production: Compose,
   Kubernetes, Kamal, or another platform? Which deployed image/version and
   configuration overlays apply, and who operates them?
2. Where does each live process resolve its private root? Is it an actual durable
   mount? Is the directory already provisioned? Provide redacted path/mount
   evidence without credentials or environment dumps.
3. How many web replicas, nodes, workers, and document-using jobs exist? Do all
   clients currently see the same private and legacy bytes? Could any pod have
   unique documents that must be preserved before a rollout?
4. Which shared filesystem/CSI service is available, with what RWX, hard-link,
   sync, consistency, failover, capacity, and reclaim guarantees? Who approves
   service selection, costs, and provisioning?
5. What runtime UID/GID and security policies apply? How are mounted directory
   ownership, NFS identity mapping, and restricted parent permissions maintained?
6. Where are authoritative legacy files held: host directories, pods, existing
   images, separate origins, buckets, or caches? Are all historical versions
   retained, and who approves any later migration/retention policy?
7. Which ingress, proxy, static hosts, CDNs, aliases, and public buckets can serve
   document bytes? Who can apply denial rules and purge historical caches?
8. Do current backups include private storage, legacy storage, and a coordinated
   database recovery point? When was a complete restore demonstrated? What are
   approved RPO/RTO, retention, access, encryption, and recovery responsibilities?
9. Are host replacement, release-directory changes, volume pruning, or automated
   rollouts imminent? Can operators preserve current bytes before those events?
10. Who approves the final architecture and executes the cutover, verification,
    and rollback? What maintenance window and single-replica interim limitations
    are acceptable if shared storage is not yet available?

## Immediate action and review gate

Live data loss is unconfirmed, but urgent operator verification is warranted.
Before any imminent container/pod replacement, rescheduling, host teardown, or
volume cleanup, Novel Minds should verify durable mounts and preserve all current
private and legacy bytes with the corresponding database recovery point. If
documents are container-local or backups are absent, preservation is needed
before that lifecycle event; this audit has not performed it.

Stop for architecture review. Only this plan is proposed for review; no
configuration implementation, migration, deletion, commit, push, merge, or
deployment is authorized by completion of this stage.
