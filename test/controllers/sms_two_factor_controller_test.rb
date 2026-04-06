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

    post login_path, params: { email: @user.Email, password: "password" }
    assert_redirected_to sms_two_factor_path

    get sms_two_factor_path
    assert_response :success
  end

  test "invalid code redirects back to 2fa page" do
    @user.update!(two_factor_enabled: true, phone_verified: true, PhoneNumber: "6145551212")

    post login_path, params: { email: @user.Email, password: "password" }
    assert_redirected_to sms_two_factor_path

    post verify_sms_two_factor_path, params: { code: "000000" }
    assert_redirected_to sms_two_factor_path
  end

  test "valid local code logs user in" do
    @user.update!(
      two_factor_enabled: true,
      phone_verified: true,
      PhoneNumber: "6145551212",
      two_factor_code: nil,
      two_factor_code_sent_at: nil
    )

    post login_path, params: { email: @user.Email, password: "password" }
    assert_redirected_to sms_two_factor_path

    generated_code = @user.reload[:two_factor_code]
    assert generated_code.present?

    post verify_sms_two_factor_path, params: { code: generated_code }

    assert_redirected_to dashboard_path
    assert_nil @user.reload[:two_factor_code]
  end

  test "resend updates code and shows success" do
    @user.update!(two_factor_enabled: true, phone_verified: true, PhoneNumber: "6145551212")
    post login_path, params: { email: @user.Email, password: "password" }
    assert_redirected_to sms_two_factor_path

    previous_code = @user.reload[:two_factor_code]
    post resend_sms_two_factor_path

    assert_redirected_to sms_two_factor_path
    assert_equal "Verification code resent successfully", flash[:notice]
    assert_not_equal previous_code, @user.reload[:two_factor_code]
  end

  test "verify redirects to login without pending session" do
    post verify_sms_two_factor_path, params: { code: "123456" }

    assert_redirected_to login_path
  end

  test "resend redirects to login without pending session" do
    post resend_sms_two_factor_path

    assert_redirected_to login_path
  end

  test "expired code fails verification" do
    @user.update!(
      two_factor_enabled: true,
      phone_verified: true,
      PhoneNumber: "6145551212",
      two_factor_code: "123456",
      two_factor_code_sent_at: 20.minutes.ago
    )

    post login_path, params: { email: @user.Email, password: "password" }
    assert_redirected_to sms_two_factor_path

    post verify_sms_two_factor_path, params: { code: "123456" }

    assert_redirected_to sms_two_factor_path
    assert_equal "Invalid or expired verification code", flash[:alert]
  end
end
