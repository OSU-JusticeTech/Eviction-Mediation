require "application_system_test_case"

class MediationsCreationTest < ApplicationSystemTestCase
  setup do
    @tenant = users(:tenant1)
    @landlord = users(:landlord1)
    @admin = users(:admin1)
  end

  test "new mediation page requires authentication" do
    visit new_mediation_path

    assert_current_path login_path
    assert_text "You must be logged in to access the mediations."
  end

  test "tenant can view new mediation form" do
    sign_in_as(@tenant)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "Request New Negotiation"
    assert_text "Landlord's Email:"
    assert_selector "input#landlord_email"
    assert_button "Request Negotiation"
  end

  test "landlord can view new mediation form" do
    sign_in_as(@landlord)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    assert_selector "h1", text: "Request New Negotiation"
    assert_text "Enter the tenant's email address"
    assert_selector "input#tenant-email"
    assert_button "Request Negotiation"
  end

  test "landlord must complete intake before a request is sent to an existing tenant" do
    sign_in_as(@landlord)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    fill_in "tenant-email", with: @tenant.Email
    click_button "Request Negotiation"

    assert_current_path new_landlord_intake_question_path
    assert_selector "h1", text: "Start Your Intake Questions"

    fill_in_landlord_intake

    assert_current_path messages_path
    assert_text "Negotiation request sent to #{@tenant.Email}"
  end

  test "tenant must complete intake before a request is sent to an existing landlord" do
    sign_in_as(@tenant)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    fill_in "landlord_email", with: @landlord.Email
    click_button "Request Negotiation"

    assert_current_path new_intake_question_path
    assert_selector "h1", text: "Start Your Intake Questions"

    fill_in_tenant_intake

    assert_current_path messages_path
    assert_selector ".flash-notice", text: "Negotiation requested with #{@landlord.CompanyName}"
  end

  test "tenant requesting an unregistered landlord email sends an invitation without going through intake" do
    sign_in_as(@tenant)
    visit new_mediation_path
    dismiss_terms_modal_if_present

    ActionMailer::Base.deliveries.clear

    fill_in "landlord_email", with: "not_registered@example.com"
    click_button "Request Negotiation"

    assert_current_path messages_path
    assert_selector ".flash-notice", text: "Invitation email sent to not_registered@example.com"

    invite_emails = ActionMailer::Base.deliveries.select { |m| m.to.include?("not_registered@example.com") }
    assert_equal 1, invite_emails.size
    assert_match(/invited to join/i, invite_emails.first.subject)
  end

  private

  def check_reason(reason_id)
    find(".reason-multiselect__toggle").click
    check reason_id
  end

  # Selenium's `fill_in` types into the locale-segmented native date widget,
  # which doesn't reliably land on the ISO value the form submits. Setting
  # the value directly avoids that flakiness.
  def set_date_field(id, date)
    execute_script("document.getElementById(#{id.to_json}).value = #{date.iso8601.to_json}")
  end

  def fill_in_tenant_intake
    check_reason "reason_failure_to_pay_rent"
    fill_in "intake_question_DescribeCause", with: "Lost job hours and fell behind on rent."
    select "Pay Missed Rent", from: "intake_question_BestOption"
    choose "intake_question_Section8_false"
    fill_in "intake_question_MoneyOwed", with: "1000"
    choose "total_cost_no"
    fill_in "monthly_rent_field", with: "900"
    set_date_field "intake_question_DateDue", Date.today
    fill_in "intake_question_PayableToday", with: "300"
    click_button "Submit"
  end

  def fill_in_landlord_intake
    check_reason "reason_failure_to_pay_rent"
    fill_in "landlord_intake_question_LandlordDescribeCause", with: "Tenant has not paid for two months."
    select "Receive Payment", from: "landlord_intake_question_DesiredOutcome"
    fill_in "landlord_intake_question_AmountClaimed", with: "2000"
    set_date_field "landlord_intake_question_DateDue", Date.today
    choose "landlord_intake_question_AcceptPaymentPlan_false"
    click_button "Submit"
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