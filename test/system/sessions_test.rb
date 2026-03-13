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

  test "logging in with valid credentials" do
    visit login_path
    
    fill_in "email", with: @user.Email
    fill_in "password", with: "password"
    click_button "Log In"

    assert_text "Logged in successfully!"
    assert_current_path dashboard_path
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
