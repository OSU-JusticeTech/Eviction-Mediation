require "test_helper"

class SmsTwoFactorControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:tenant1)
  end

  test "redirects to login when no pending 2fa session" do
    get sms_two_factor_path
    assert_redirected_to login_path
  end

  test "shows 2fa page when pending session exists" do
    @user.update!(two_factor_enabled: true, phone_verified: true, PhoneNumber: "6145551212")

    capture_io do # Stop output from being displayed in console
      post login_path, params: { email: @user.Email, password: "password" }
      assert_redirected_to sms_two_factor_path
    end

    get sms_two_factor_path
    assert_response :success
  end

  test "invalid code redirects back to 2fa page" do
    @user.update!(two_factor_enabled: true, phone_verified: true, PhoneNumber: "6145551212")

    capture_io do # Stop output from being displayed in console
      post login_path, params: { email: @user.Email, password: "password" }
      assert_redirected_to sms_two_factor_path
    end

    capture_io do # Stop output from being displayed in console
      post verify_sms_two_factor_path, params: { code: "000000" }
      assert_redirected_to sms_two_factor_path
    end
  end
end
