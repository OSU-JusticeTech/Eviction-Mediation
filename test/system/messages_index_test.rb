require "application_system_test_case"

class MessagesIndexTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @mediator = users(:mediator1)
    @admin = users(:admin1)
  end

  test "messages index requires authentication" do
    visit messages_path

    assert_current_path login_path
    assert_text "You must be logged in"
  end

  test "tenant sees tenant negotiations page" do
    sign_in_as(@tenant)
    visit messages_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "Tenant Negotiation & Messages"
    assert_text "Welcome, #{@tenant.FName}!"
  end

  test "landlord sees landlord negotiations page" do
    sign_in_as(@landlord)
    visit messages_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "Landlord Negotiation & Messages"
    assert_text "Welcome, #{@landlord.FName}!"
  end

  test "mediator is redirected to assigned mediations page" do
    sign_in_as(@mediator)
    visit messages_path

    assert_current_path third_party_mediations_path
    assert_selector "h1", text: "Your Assigned Mediation Cases"
  end

  test "landlord can filter by status and paginate the mediation list" do
    create_past_mediations_for(@landlord, count: 12)

    sign_in_as(@landlord)
    visit messages_path
    dismiss_terms_modal_if_present

    # 12 past + the fixture's 1 pending = 13, paginated 10 per page by default.
    assert_selector ".mediation-card-item", count: 10
    assert_selector ".mediation-pagination"

    # Filtering to Past flattens to only past mediations (still 10 per page).
    click_button "Past"
    assert_selector ".mediation-card-item", count: 10
    assert_no_selector ".status-badge--pending"

    # Numbered page buttons are rendered; jumping to page 2 shows the
    # remaining two past mediations.
    assert_selector ".pagination-page", text: "2"
    within ".pagination-pages" do
      click_button "2"
    end
    assert_selector ".mediation-card-item", count: 2
    assert_selector ".pagination-page.is-active", text: "2"

    # Previous returns to the full first page.
    click_button "Previous"
    assert_selector ".mediation-card-item", count: 10
    assert_selector ".pagination-page.is-active", text: "1"
  end

  private

  def create_past_mediations_for(landlord, count:)
    count.times do |i|
      tenant = User.create!(
        Email: "past-tenant-#{i}-#{SecureRandom.hex(4)}@example.com",
        FName: "Past", LName: "Tenant #{i}",
        Role: "Tenant",
        AddressLine1: "#{100 + i} Main St", City: "Columbus", State: "Ohio", ZipCode: "43210",
        password: "password", password_confirmation: "password", ProfileDisclaimer: "yes"
      )
      message_string = MessageString.create!(Role: "Primary")
      PrimaryMessageGroup.create!(
        ConversationID: message_string.ConversationID,
        TenantID: tenant.UserID,
        LandlordID: landlord.UserID,
        CreatedAt: Time.current,
        accepted_by_landlord: true,
        accepted_by_tenant: true,
        deleted_at: Time.current,
        EndedBy: landlord.UserID
      )
    end
  end

  def sign_in_as(user)
    visit login_path
    fill_in "email", with: user.Email
    fill_in "password", with: "password"
    click_button "Log In"
    dismiss_terms_modal_if_present
  end

  def dismiss_terms_modal_if_present
    return unless page.has_button?("OK", wait: 1)

    click_button "OK"
  end
end