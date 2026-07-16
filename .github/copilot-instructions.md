# CSE5911 Eviction – Copilot Instructions

## Architecture & Domain
- Ruby on Rails 8.0.1 app (see `Gemfile`) supporting eviction mediation for tenants, landlords, mediators, and admins.
- Core MVC lives under `app/`; controllers handle role-specific dashboards, chat, documents, and screenings, while models mirror SQL Server tables.
- Messaging domain centers on `PrimaryMessageGroup` (tenant↔landlord), `SideMessageGroup` (mediator↔party), `MessageString`, and `Message`; follow `app/controllers/messages_controller.rb` and `mediator_messages_controller.rb` for canonical flows.
- Document workflows pair `FileDrafts` + `FileAttachments` with chats for e-signature; `app/controllers/documents_controller.rb` shows how PDF generation and manual PKs (`next_filedraft_pk_value`) work.

## Data & Conventions
- SQL Server (configured in `config/database.yml`) is the source of truth; use `DBInitTest.sql` or the walkthrough in `DB Initialization.txt` when recreating schemas and keep Azure SQL Edge volume data under `SQLData/`.
- Table columns stay PascalCase (e.g., `UserID`, `TenantAddress`); access them via `self[:ColumnName]` to avoid Rails’ snake_case expectations.
- Soft-deletes rely on `deleted_at` columns across `MessageString`, `PrimaryMessageGroup`, and screening tables; always guard against reopened conversations by redirecting to `mediation_ended_prompt` when these fields are set.
- Duplicate user input is filtered by the 2-second window in both message controllers—reuse that pattern for any new broadcasted records.

## Real-time Messaging
- ActionCable channels (`app/channels/messages_channel.rb`, `mediator_messages_channel.rb`) stream per `ConversationID`; broadcast payloads are assembled in the controllers and rendered live by `app/javascript/channels/*.js`.
- Chat composers and modals are plain JS modules under `app/javascript/chat/` that reinitialize on Turbo events; expand these helpers instead of binding raw DOM listeners elsewhere.
- Attachment payloads must include preview/download/sign URLs exactly as built in `messages_controller.rb`; adjust `buildAttachmentHtml` in `app/javascript/channels/messages_channel.js` whenever the payload changes.

## Authentication & Controllers
- Sessions hinge on `session[:user_id]`; `ApplicationController` sets `@user`, exposes `current_user`, and uses `allow_browser` to whitelist Safari versions—keep those hooks in new controllers.
- Controllers consistently use `before_action :require_login` + `:set_user` and render `Access Denied` for unauthorized roles (see the `index` action in `app/controllers/messages_controller.rb`); follow that contract for new endpoints.
- Mediator-specific features should reuse the validation logic shown in `MediatorMessagesController` (the `set_side_conversation` helper) to confirm assignments against `SideMessageGroup`.

## Environment & Tooling
- Required stack: Ruby 3.4.1, Rails 8.0.1, Node.js for ActionCable assets, and SQL Server Developer / Azure SQL Edge (full setup lives in `docs/_posts/2025-03-04-developer-manual.markdown`).
- Start the database with Docker (`docker compose up db`) or a native instance; the Rails container in `docker-compose.yml` connects via `DB_HOST=db` and shares code via a bind mount.
- Install deps with `bundle install`, run `bin/rails db:prepare`, then `bin/dev` or `bin/rails server`; there is no foreman script—start extra workers manually.
- ActionCable uses the async adapter in development (see `config/cable.yml`) and Solid Cable in production, so don’t assume Redis is present.

## Testing & QA
- Run tests with `rails test`; `test/test_helper.rb` disables parallelization because SQL Server cannot truncate fixtures concurrently.
- Fixtures under `test/fixtures` keep PascalCase keys to match the database schema; update them alongside migrations so controller tests (e.g., `MessagesControllerTest`) stay deterministic.
- When altering authentication or chat behavior, prefer integration specs in `test/controllers`/`test/system` so the GitHub workflow exercises the full Hotwire + ActionCable stack.

## Deployment & Ops
- The multi-stage `Dockerfile` precompiles assets and runs `./bin/rails db:prepare` inside `bin/docker-entrypoint`; `config/database.yml` is committed (env-var driven) and copied in with the app source, so keep new dependencies compatible with that flow.
- `docker-compose.yml` pairs the web app with Azure SQL Edge; Kamal and `k8s/` manifests assume the same env vars and port 3000/1433 mappings—update all three when credentials change.
- README defers to the docs site, so capture any new architectural decisions or setup gotchas here and in `docs/_posts` to keep future contributors unblocked.
