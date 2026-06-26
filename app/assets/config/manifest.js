//= link_tree ../images
// Prevent double-linking `application.css` (application.css + application.css.erb).
// Use explicit per-file links below instead of linking the aggregated file.
// Note: we do not use `app/assets/javascripts` here; use `app/javascript`.
// (Keeps Propshaft/importmap layout stable across branches.)
//= link_tree ../../javascript .js
//= link application.js
// Do not link `application.css` here (see note above).

// Individual stylesheet links
//= link base.css
//= link navbar.css 
//= link flash.css
//= link dashboard.css
//= link login.css
//= link signup.css
//= link chat.css
//= link messages_tenant.css
//= link messages_landlord.css
//= link screening_questions.css
//= link action.css
//= link admin_mediations.css
//= link mediator_screening_view.css
//= link mediations.css
//= link documents.css
//= link resources.css
//= link account_view.css//= link_tree ../builds
