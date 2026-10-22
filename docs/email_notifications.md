# Email notifications

The additions use the existing `MediationMailer` and ordinary `deliver_later` calls. The existing sender configuration, SMTP setup, request emails, unread-message mailer, and unread reminder job are unchanged. No new notification service, job type, table, or migration is needed.

## Added events

- Shared agreement previews: created and ready for signing when no suggestions are pending. Standalone drafts do not email anyone until shared in a case.
- Agreement review: changes requested on submission; approved and revised when a suggestion is accepted; ready for signing when a review finishes without counteroffers. Counteroffers request another review. Approval refers to suggested changes: the existing workflow has no separate whole-preview approval action.
- Signatures: a party signed, followed by signatures completed when both signatures are present. Re-saving an existing signature does not repeat the notification.
- New messages: recipients other than the sender receive an email after a message commits. Private chats notify only their party and current assigned mediator. System messages do not generate new-message emails. The existing message-email preference controls new-message emails as well as reminders; its account-page explanation reflects this.
- Case closure: participants receive the outcome, or a notice that it has not been recorded. Changing the outcome on a closed case sends an updated email. Saving the same outcome sends nothing.

Agreement and case notifications go separately to the tenant, landlord, and assigned mediator. Related events currently send separate emails: sharing a preview can send created and ready emails, accepting the last suggestion can send approved/revised/ready emails, and the second signature sends signed and completed emails. Email bodies exclude message contents and agreement terms and link to authenticated application pages.

## Existing behavior retained

Request emails remain at their existing intake actions. The original unread job checks tenant/landlord messages older than four hours and suppresses a reminder when the recipient has replied afterward. Its Rails cache history is unchanged; opening a chat does not suppress a reminder.

Meeting scheduling and meeting notification triggers are not implemented because there is no existing scheduling workflow to attach them to. Persistent read tracking is not implemented.

## Running and verification

Use the existing mail delivery setup and background worker. Production uses Sidekiq; development uses its existing async adapter and Mailpit. The pre-existing unread recurring configuration targets Solid Queue and is not consumed by Sidekiq, so invoking that reminder job still requires the existing scheduler arrangement or an external invocation. This change does not replace scheduling infrastructure.

Focused regression tests cover the added mailer actions, agreement review, sharing and signatures, closure outcomes, and message recipients, opt-outs, and rollback behavior. The original unread tests clear setup emails before checking reminder delivery.

Ruby syntax checks, focused RuboCop checks, and `git diff --check` passed. Thirteen standalone Action Mailer rendering checks passed for agreement events, new messages, closure details, document links, and HTML escaping; no email was sent. Full Rails tests could not boot because `tiny_tds`, `activerecord-sqlserver-adapter`, `font-awesome-sass`, and `sassc` are missing. Database-backed behavior and live SMTP delivery remain unverified.
