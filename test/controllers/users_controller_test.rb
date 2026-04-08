require "test_helper"

class UsersControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
  end

  test "renders the signup form" do
    get signup_url

    assert_response :success
    assert_select "form"
  end

  test "creates a user with valid data" do
    params = {
      Email: "new-tenant@example.com",
      password: "Password!23",
      password_confirmation: "Password!23",
      FName: "New",
      LName: "Tenant",
      Role: "Tenant",
      AddressLine1: "123 Main St",
      AddressLine2: "Apt 4B",
      City: "Columbus",
      State: "oh",
      ZipCode: "43215-1234",
      ProfileDisclaimer: "yes"
    }

    assert_enqueued_jobs 1 do
      assert_difference("User.count", 1) do
        post signup_url, params: { user: params }
      end
    end

    created_user = User.find_by(Email: "new-tenant@example.com")
    assert_redirected_to dashboard_url
    assert_equal created_user.UserID, session[:user_id]
    assert_equal "Account created successfully!", flash[:notice]
    assert_equal "123 Main St", created_user[:AddressLine1]
    assert_equal "Apt 4B", created_user[:AddressLine2]
    assert_equal "Columbus", created_user[:City]
    assert_equal "OH", created_user[:State]
    assert_equal "43215-1234", created_user[:ZipCode]
    assert_equal "123 Main St, Apt 4B, Columbus, OH 43215-1234", created_user.formatted_tenant_address
  end

  test "does not create a user with invalid data" do
    invalid_params = {
      Email: "not-an-email",
      password: "Password!23",
      password_confirmation: "Password!23",
      FName: "",
      LName: "",
      Role: "Tenant",
      AddressLine1: "123 Main St",
      City: "Columbus",
      State: "OH",
      ZipCode: "43215",
      ProfileDisclaimer: "no"
    }

    assert_no_enqueued_jobs do
      assert_no_difference("User.count") do
        post signup_url, params: { user: invalid_params }
      end
    end

    assert_response :success
    assert_select "form"
    assert_nil session[:user_id]
    assert_nil flash[:notice]
    assert_select ".error-text", text: /must be a valid email address/i
    assert_select ".error-text", text: /you must agree to the disclaimer to sign up/i
  end

  test "does not create a user with duplicate email" do
    duplicate_email_params = {
      Email: "TEST@EXAMPLE.COM",
      password: "Password!23",
      password_confirmation: "Password!23",
      FName: "Duplicate",
      LName: "Tenant",
      Role: "Tenant",
      AddressLine1: "456 Broad St",
      City: "Columbus",
      State: "OH",
      ZipCode: "43215",
      ProfileDisclaimer: "yes"
    }

    assert_no_enqueued_jobs do
      assert_no_difference("User.count") do
        post signup_url, params: { user: duplicate_email_params }
      end
    end

    assert_response :success
    assert_select "form"
    assert_nil session[:user_id]
    assert_nil flash[:notice]
    assert_select ".error-text", text: /already registered/i
  end
end
