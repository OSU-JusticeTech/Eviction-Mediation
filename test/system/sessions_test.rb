require "application_system_test_case"

class SessionsTest < ApplicationSystemTestCase
  setup do
    @user = users(:landlord1)
  end

  test "visiting the login page shows the login form" do
    visit login_path
    
    assert_selector "h2", text: "Log In"
    assert_selector "input[type='email']"
    assert_selector "input[type='password']"
    assert_button "Log In"
    assert_link "Sign up"
  end

  test "first login requires scrolling through and explicitly accepting the terms" do
    visit login_path
    window = page.current_window
    original_size = window.size
    window.resize_to(1000, 650)
    page.execute_script("localStorage.removeItem('evictionMediationTermsAccepted')")
    
    fill_in "email", with: @user.Email
    fill_in "password", with: "password"
    click_button "Log In"

    assert_current_path terms_of_use_path, ignore_query: true
    assert_selector ".terms-page__text .terms-page__actions:not([hidden]) .terms-page__agree[disabled]", visible: :all

    scroll_to_end_of_terms
    click_button "I Agree"
    assert_current_path dashboard_path
    assert_selector "h1", text: @user.FName
  ensure
    window.resize_to(*original_size) if original_size
  end

  test "logging in with invalid email shows error" do
    visit login_path
    
    fill_in "email", with: "nonexistent@example.com"
    fill_in "password", with: "anypassword"
    click_button "Log In"

    assert_text "Invalid email or password"
    assert_selector "h2", text: "Log In" # Still on login page
  end

  test "logging in with invalid password shows error" do
    visit login_path
    
    fill_in "email", with: @user.Email
    fill_in "password", with: "wrongpassword"
    click_button "Log In"

    assert_text "Invalid email or password"
    assert_selector "h2", text: "Log In" # Still on login page
  end

  test "logging out after successful login" do
    # Log in first
    visit login_path
    page.execute_script("localStorage.setItem('evictionMediationTermsAccepted', 'true')")
    fill_in "email", with: @user.Email
    fill_in "password", with: "password"
    click_button "Log In"
    
    assert_text "Logged in successfully!"

    # Then log out
    visit logout_path

    assert_text "Logged out successfully!"
    assert_current_path root_path
  end
end
