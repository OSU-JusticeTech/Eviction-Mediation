require "application_system_test_case"

class UsersTest < ApplicationSystemTestCase
  test "visiting the signup page shows the signup form" do
    visit signup_path

    assert_selector "h2", text: "Sign Up"
    assert_selector "input#user_FName"
    assert_selector "input#user_LName"
    assert_selector "input#user_Email"
    assert_selector "input#user_password"
    assert_selector "input#user_password_confirmation"
    assert_selector "input#role_tenant"
    assert_selector "input#role_landlord"
    assert_button "Sign Up"
  end

  test "signing up as a tenant with valid data" do
    visit signup_path

    within(".signup-form") do
      find("#user_FName").set("Alice")
      find("#user_LName").set("Tenant")
      find("#user_Email").set("alice.tenant.#{Time.now.to_i}@example.com")
      find("#user_password").set("SecurePassword123!")
      find("#user_password_confirmation").set("SecurePassword123!")
      choose "role_tenant"
      assert_selector "#address-line-1", visible: true
      find("#address-line-1").set("123 Main St")
      find("#city").set("Columbus")
      find("#state").set("OH")
      find("#zip-code").set("43215")
      find("#phone-number").set("614-555-0100")

      # Use JavaScript to accept disclaimer (both checkbox and termsOpened tracker)
      page.execute_script("document.getElementById('user_ProfileDisclaimer').checked = true;")
      page.execute_script("document.getElementById('termsOpened').value = 'true';")

      click_button "Sign Up"
    end

    assert_text "Account created successfully!"
    assert_current_path dashboard_path
  end

  test "signing up as a landlord with valid data" do
    visit signup_path

    within(".signup-form") do
      find("#user_FName").set("Bob")
      find("#user_LName").set("Landlord")
      find("#user_Email").set("bob.landlord.#{Time.now.to_i}@example.com")
      find("#user_password").set("SecurePassword123!")
      find("#user_password_confirmation").set("SecurePassword123!")
      choose "role_landlord"
      find("#user_CompanyName").set("Property Management LLC")
      find("#phone-number").set("614-555-0200")

      # Use JavaScript to accept disclaimer (both checkbox and termsOpened tracker)
      page.execute_script("document.getElementById('user_ProfileDisclaimer').checked = true;")
      page.execute_script("document.getElementById('termsOpened').value = 'true';")

      click_button "Sign Up"
    end

    assert_text "Account created successfully!"
    assert_current_path dashboard_path
  end

  test "signup fails with mismatched passwords" do
    visit signup_path

    attempted_email = "mismatch.#{SecureRandom.hex(4)}@example.com"

    within(".signup-form") do
      find("#user_FName").set("Mismatch")
      find("#user_LName").set("User")
      find("#user_Email").set(attempted_email)
      find("#user_password").set("SecurePassword123!")
      find("#user_password_confirmation").set("DifferentPassword123!")
      choose "role_tenant"
      find("#address-line-1").set("101 Error St")
      find("#city").set("Columbus")
      find("#state").set("OH")
      find("#zip-code").set("43215")
      find("#phone-number").set("614-555-0300")
      page.execute_script("document.getElementById('user_ProfileDisclaimer').checked = true;")
      page.execute_script("document.getElementById('termsOpened').value = 'true';")

      click_button "Sign Up"
    end

    assert_current_path signup_path
    assert_text "Password confirmation doesn't match Password"
    assert_nil User.find_by(Email: attempted_email)
  end

  test "signup fails with duplicate email" do
    visit signup_path

    existing_user = users(:landlord1)

    within(".signup-form") do
      find("#user_FName").set("Duplicate")
      find("#user_LName").set("User")
      find("#user_Email").set(existing_user.Email)
      find("#user_password").set("SecurePassword123!")
      find("#user_password_confirmation").set("SecurePassword123!")
      choose "role_landlord"
      find("#user_CompanyName").set("Duplicate Co")
      find("#phone-number").set("614-555-0400")
      page.execute_script("document.getElementById('user_ProfileDisclaimer').checked = true;")
      page.execute_script("document.getElementById('termsOpened').value = 'true';")

      click_button "Sign Up"
    end

    assert_current_path signup_path
    assert_text "Email is already registered"
  end
end
