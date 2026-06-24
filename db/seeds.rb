# db/seeds.rb
#
# Development seed data. Designed to be IDEMPOTENT — safe to run repeatedly:
#   * accounts are found-or-updated by email
#   * the mediation scenarios are built only once (guarded on the primary
#     landlord already having mediations), so re-running won't duplicate them.
#
# Every account's password is "test123".
#
# Primary logins (memorable):
#   landlord@test.com   tenant@test.com   mediator@test.com   admin@test.com
#
# After seeding, the primary landlord AND primary tenant each have a full,
# multi-page board: a pending negotiation, an active negotiation, an active
# negotiation with a mediator, several past negotiations, plus a bulk set of
# generated counterparties (with varied dates) so pagination and the date
# filter can be exercised.

PASSWORD = "test123".freeze

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Find-or-update a user by email so the seeder can be re-run without blowing up
# on duplicate-email validations.
def upsert_user!(email:, fname:, lname:, role:, **attrs)
  user = User.find_or_initialize_by(Email: email)
  user.assign_attributes(
    FName: fname,
    LName: lname,
    Role: role,
    password: PASSWORD,
    password_confirmation: PASSWORD,
    **attrs
  )
  user.save!
  user
end

def ensure_mediator!(user, cap: 5)
  mediator = Mediator.find_or_initialize_by(UserID: user.UserID)
  mediator.Available = true if mediator.Available.nil?
  mediator.ActiveMediations ||= 0
  mediator.MediationCap = cap
  mediator.save!
  mediator
end

# Valid intake answers, required before a mediation can be "active".
def build_intake!(tenant)
  IntakeQuestion.create!(
    UserID: tenant.UserID,
    Reason: "Failure to Pay Rent",
    DescribeCause: "Fell behind on rent after a temporary loss of income.",
    BestOption: "Pay Missed Rent",
    Section8: false,
    MoneyOwed: 1_800,
    TotalCostOrMonthly: true, # total cost -> MonthlyRent must stay blank
    PayableToday: 400,
    DateDue: Date.current - 10
  )
end

def submit_feedback!(mediation, user)
  SurveyResponse.create!(
    conversation_id: mediation.ConversationID,
    user_id: user.UserID,
    user_role: user.Role,
    tool_ease: "easy",
    info_clear: "yes",
    understood_mediation: "yes",
    other_participated: "yes",
    good_faith: "yes",
    helped_communicate: "yes",
    would_recommend: "yes",
    device_used: "computer",
    liked_most: "Clear, structured communication.",
    should_improve: "Nothing major."
  )
end

def seed_messages!(mediation, landlord:, tenant:, mediator:)
  broadcast = mediator.present?
  base = mediation.CreatedAt || Time.current

  Message.create!(
    ConversationID: mediation.ConversationID,
    SenderID: landlord.UserID,
    recipientID: broadcast ? nil : tenant.UserID,
    Contents: "Hi, thanks for agreeing to mediate. Could we set up a repayment plan?",
    MessageDate: base + 1.hour
  )
  Message.create!(
    ConversationID: mediation.ConversationID,
    SenderID: tenant.UserID,
    recipientID: broadcast ? nil : landlord.UserID,
    Contents: "Yes — I can pay $400 today and the rest over the next two months.",
    MessageDate: base + 2.hours
  )
  if mediator
    Message.create!(
      ConversationID: mediation.ConversationID,
      SenderID: mediator.UserID,
      recipientID: nil,
      Contents: "Great. I'll help you both put this agreement in writing.",
      MessageDate: base + 3.hours
    )
  end
end

# Build a full mediation (MessageString + PrimaryMessageGroup) in a given state.
#
# status: :pending_awaiting_landlord | :pending_awaiting_tenant |
#         :pending_intake | :active | :active_with_mediator | :past
def build_mediation!(landlord:, tenant:, status:, mediator: nil,
                     created_at: Time.current, ended_at: nil, with_messages: false)
  message_string = MessageString.create!(
    Role: "Primary",
    CreatedAt: created_at,
    LastMessageSentDate: created_at
  )

  attrs = {
    ConversationID: message_string.ConversationID,
    TenantID: tenant.UserID,
    LandlordID: landlord.UserID,
    CreatedAt: created_at,
    GoodFaith: false,
    MediatorRequested: false,
    MediatorAssigned: false,
    accepted_by_landlord: false,
    accepted_by_tenant: false
  }

  case status
  when :pending_awaiting_landlord # tenant initiated, landlord must accept
    attrs[:accepted_by_tenant] = true
  when :pending_awaiting_tenant   # landlord initiated, tenant must accept
    attrs[:accepted_by_landlord] = true
  when :pending_intake            # both accepted, tenant still owes intake
    attrs[:accepted_by_landlord] = true
    attrs[:accepted_by_tenant] = true
  when :active, :active_with_mediator, :past
    attrs[:accepted_by_landlord] = true
    attrs[:accepted_by_tenant] = true
    attrs[:IntakeID] = build_intake!(tenant).IntakeID
  end

  if mediator
    attrs[:MediatorRequested] = true
    attrs[:MediatorAssigned] = true
    attrs[:MediatorID] = mediator.UserID
  end

  if status == :past
    attrs[:deleted_at] = ended_at || (created_at + 7.days)
    attrs[:EndedBy] = landlord.UserID
  end

  mediation = PrimaryMessageGroup.create!(attrs)

  # Past mediations close their conversation thread too.
  message_string.update!(deleted_at: mediation.deleted_at) if mediation.deleted_at

  # No manual counter bump: creating an assigned, non-past mediation re-derives
  # the mediator's ActiveMediations counter via PrimaryMessageGroup's callback.

  seed_messages!(mediation, landlord: landlord, tenant: tenant, mediator: mediator) if with_messages

  mediation
end

# ---------------------------------------------------------------------------
# Primary accounts (memorable logins)
# ---------------------------------------------------------------------------

primary_landlord = upsert_user!(
  email: "landlord@test.com", fname: "John", lname: "Doe", role: "Landlord",
  CompanyName: "Doe Property Management", PhoneNumber: "614-555-1234"
)

primary_tenant = upsert_user!(
  email: "tenant@test.com", fname: "Jane", lname: "Smith", role: "Tenant",
  AddressLine1: "456 Elm St", City: "Columbus", State: "Ohio", ZipCode: "43215",
  PhoneNumber: "614-555-5678"
)

primary_mediator = upsert_user!(
  email: "mediator@test.com", fname: "Mary", lname: "Mediator", role: "Mediator",
  PhoneNumber: "614-555-9876"
)
ensure_mediator!(primary_mediator)

upsert_user!(
  email: "admin@test.com", fname: "Adam", lname: "Admin", role: "Admin",
  PhoneNumber: "614-555-1111"
)

# ---------------------------------------------------------------------------
# Standardized extra accounts
# ---------------------------------------------------------------------------

upsert_user!(
  email: "landlord2@test.com", fname: "Landlord", lname: "Two", role: "Landlord",
  CompanyName: "Landlord Two Properties", PhoneNumber: "614-555-2200"
)

second_mediator = upsert_user!(
  email: "mediator2@test.com", fname: "Mediator", lname: "Two", role: "Mediator",
  PhoneNumber: "614-555-2299"
)
ensure_mediator!(second_mediator)

upsert_user!(
  email: "admin2@test.com", fname: "Admin", lname: "Two", role: "Admin",
  PhoneNumber: "614-555-2211"
)

puts "Seeded accounts (password: #{PASSWORD})"

# Sample documents (idempotent: only when none exist for these users).
if FileDraft.where(CreatorID: primary_tenant.UserID).none?
  FileDraft.create!(
    CreatorID: primary_tenant.UserID,
    FileName: "Sample Tenant Document",
    FileTypes: "text/plain",
    FileURLPath: "userFiles/TestDocument1.pdf",
    TenantSignature: true
  )
end
if FileDraft.where(CreatorID: primary_landlord.UserID).none?
  FileDraft.create!(
    CreatorID: primary_landlord.UserID,
    FileName: "Sample Landlord Document",
    FileTypes: "text/plain",
    FileURLPath: "userFiles/testfile2.txt",
    LandlordSignature: true
  )
end

# ---------------------------------------------------------------------------
# Mediation scenarios + bulk pagination data (built once)
# ---------------------------------------------------------------------------

if Rails.env.test?
  # Tests load their data from fixtures, so skip the heavy scenario/bulk data
  # to avoid leaving rows in tables that have no fixture to purge them.
  puts "Test environment — skipping mediation scenario seeding (tests use fixtures)."
elsif PrimaryMessageGroup.where(LandlordID: primary_landlord.UserID).none?
  # --- Named scenarios between the two primary accounts ---
  # These appear on BOTH boards (each side sees the other party), so a single
  # record gives the landlord and the tenant a matching test case.

  # Tenant-initiated request -> landlord sees Accept/Reject, tenant waits.
  build_mediation!(landlord: primary_landlord, tenant: primary_tenant,
                   status: :pending_awaiting_landlord, created_at: 2.days.ago)

  # Landlord-initiated request -> tenant sees Accept/Reject, landlord waits.
  build_mediation!(landlord: primary_landlord, tenant: primary_tenant,
                   status: :pending_awaiting_tenant, created_at: 1.day.ago)

  # Both accepted, but the tenant still owes intake answers -> tenant sees
  # "Complete Intake Questions", landlord sees "waiting on tenant".
  build_mediation!(landlord: primary_landlord, tenant: primary_tenant,
                   status: :pending_intake, created_at: 3.days.ago)

  # Active negotiation, no mediator yet (with a short message thread).
  build_mediation!(landlord: primary_landlord, tenant: primary_tenant,
                   status: :active, created_at: 10.days.ago, with_messages: true)

  # Active negotiation WITH a mediator assigned (broadcast thread).
  build_mediation!(landlord: primary_landlord, tenant: primary_tenant,
                   status: :active_with_mediator, mediator: primary_mediator,
                   created_at: 14.days.ago, with_messages: true)

  # Past negotiation where the landlord has already left feedback but the
  # tenant has not (so each side sees a different feedback state).
  past_with_feedback = build_mediation!(landlord: primary_landlord, tenant: primary_tenant,
                                        status: :past, created_at: 60.days.ago, ended_at: 50.days.ago)
  submit_feedback!(past_with_feedback, primary_landlord)

  # Past negotiation with feedback still outstanding for both.
  build_mediation!(landlord: primary_landlord, tenant: primary_tenant,
                   status: :past, created_at: 90.days.ago, ended_at: 80.days.ago)

  # --- Bulk data so each primary board spans ~3 pages (10 cards/page) ---
  bulk_count = 20

  # Generated tenants give the LANDLORD board its volume.
  bulk_count.times do |i|
    n = format("%02d", i + 1)
    tenant = upsert_user!(
      email: "tenant-#{n}@test.com", fname: "Tenant", lname: n, role: "Tenant",
      AddressLine1: "#{100 + i} Mediation Way", City: "Columbus", State: "Ohio",
      ZipCode: "43215", PhoneNumber: "614-556-#{format('%04d', i)}"
    )
    created = (14 + i * 9).days.ago
    if i.even? # mostly past, with spread-out end dates for date-filter testing
      build_mediation!(landlord: primary_landlord, tenant: tenant, status: :past,
                       created_at: created, ended_at: created + 5.days)
    else
      build_mediation!(landlord: primary_landlord, tenant: tenant, status: :active,
                       created_at: created)
    end
  end

  # Generated landlords give the TENANT board its volume.
  bulk_count.times do |i|
    n = format("%02d", i + 1)
    landlord = upsert_user!(
      email: "landlord-#{n}@test.com", fname: "Landlord", lname: n, role: "Landlord",
      CompanyName: "Landlord #{n} Holdings", PhoneNumber: "614-557-#{format('%04d', i)}"
    )
    created = (12 + i * 8).days.ago
    if i.even?
      build_mediation!(landlord: landlord, tenant: primary_tenant, status: :past,
                       created_at: created, ended_at: created + 5.days)
    else
      build_mediation!(landlord: landlord, tenant: primary_tenant, status: :active,
                       created_at: created)
    end
  end

  puts "Seeded mediation scenarios + bulk pagination data."
else
  puts "Mediation scenarios already present — skipping (re-run safe)."
end

puts "Seeding complete."
