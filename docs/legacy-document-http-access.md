# Stage 3: legacy document HTTP access

## Application changes and investigation

The only locator-derived document URL found in application code was the signed
file link in `app/views/messages/summary.html.erb`: `"/#{file.FileURLPath}"`.
It now uses `view_file_path(file.FileID)`, preserving agreement review/signing
and opening the existing authorized page and inline preview.

Document lists, chat attachment partials, message JSON attachment payloads,
JavaScript attachment rendering, agreement review/show pages, and agreement
notification emails already use record routes. Download routes are
`download_file_path` and `download_document_path` (both `download_or_view`);
`view_inline_document_path` delivers inline bytes. These authorize the record
before calling DocumentStorage and return noncacheable responses. Email uses
`view_file_url`. Template previews and local upload blob previews are separate
from stored document delivery. Other FileURLPath uses compute metadata or
perform storage operations; they do not generate direct HTTP links.

DocumentStorage still resolves validated `userFiles/<filename>` beneath
`public/userFiles` when legacy reads are enabled. It rejects traversal, nested
paths, malformed names and symlinks. No legacy files are moved/deleted and no
storage, creation, revision, signing or deletion behavior changes here.

`LegacyDocumentAccessBlocker` is inserted at position zero in the Rails middleware
stack, ahead of ActionDispatch::Static. It returns a generic 404 with no-store
for the legacy namespace for every HTTP method, without consulting the session.
It checks decoded paths, repeated separators and normalized dot segments as well
as the original decoded namespace. Other public assets still use static serving.

## Protection boundary

Development and test configure Rails static response headers; production also
sets long-lived public static headers. None previously excluded userFiles.
The new global middleware applies to all Rails environments regardless of whether
Rails static serving is enabled. Development Compose starts Rails/Puma directly.
The production Dockerfile also starts Rails directly; staging Compose selects
RAILS_ENV=production. There is no separate staging Rails environment file.
The checked-in `nginx-config.conf` proxies `/` to Puma rather than serving a
public filesystem. Requests following those paths reach the guard after the
updated application is deployed and restarted.

This is **not proof of protection in any live deployment**. No live HTTP probes
or infrastructure changes were performed. An upstream static server, CDN cache,
public bucket, alternate hostname, filesystem alias or other process serving the
public tree bypasses this guard. Staging and production require infrastructure
review and external verification; development/test with any such front end do too.
Previously downloaded or browser-cached bytes cannot be revoked by this change.

## Required infrastructure review (not applied)

For every public listener and origin, deny the normalized `/userFiles` namespace
before static lookup, cache hits or proxy fallback. For Nginx, review these rules
in each applicable server block (including HTTP, HTTPS and asset hostnames):

```nginx
location = /userFiles { add_header Cache-Control "no-store" always; return 404; }
location ^~ /userFiles/ { add_header Cache-Control "no-store" always; return 404; }
```

Review case/encoding behavior and any aliases or rewrites that expose the same
directory under different URLs. For Apache, deny the physical public/userFiles
directory with `Require all denied` in server configuration, and review Alias
and rewrite rules. These are review examples, not deployed configuration.
CDN/edge rules must deny before cache lookup; purge previously cached legacy
objects and remove public access to any replicated bucket objects. Confirm that
X-Sendfile/X-Accel-Redirect handling still permits authorized Rails delivery while
denying client requests to any internal delivery location.

Before declaring the vulnerability fixed, use a known existing nonsensitive
legacy test file on each deployed hostname/origin: GET, HEAD and Range requests,
anonymous and authenticated, must return denial without bytes. Include encoded
characters/separators, duplicate slashes, dot segments (`curl --path-as-is`),
HTTP/HTTPS, CDN cache hits and direct origin requests. Then verify authorized
download and inline preview, agreement review/signing and ordinary public assets.
Do not put real document contents or credentials in verification logs.

## Regression coverage and validation

Added controller coverage for legacy download/inline routes, anonymous and outsider
denial, missing/malformed/traversal locators, and direct HTTP denial for an existing
file for both anonymous users and its owner. Added summary coverage for authorized
record links with both legacy and private locators. Added a middleware test using
a real ActionDispatch::Static server with a positive control proving that the file
would otherwise be served, plus encoded/normalized paths, HEAD, and public assets.
Existing private-delivery, sandboxed preview and agreement signing/revision tests
remain in place. Middleware and Rails tests cannot prove upstream protection.

Only Ruby syntax checks and `git diff --check` were run for this change. The owner
will run tests with Docker Compose. No credentials or web.vars were read or edited.
