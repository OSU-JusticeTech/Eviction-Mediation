require "test_helper"

class AccountControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = users(:tenant1)
    @mediator_user = users(:mediator1)
  end

  test "redirects to login when not authenticated" do
    get "/account"
    assert_redirected_to login_path
  end

  test "shows account page for logged in user" do
    log_in_as(@tenant)

    get "/account"
    assert_response :success
  end

  test "shows edit page for logged in user" do
    log_in_as(@tenant)

    get "/account/edit"
    assert_response :success
  end

  test "tenant can update split address fields" do
    log_in_as(@tenant)
    follow_redirect!

    patch account_path, params: {
      commit: "Update Address",
      user: {
        AddressLine1: "500 Oak St",
        AddressLine2: "Unit 2",
        City: "Columbus",
        State: "oh",
        ZipCode: "43210-1111"
      }
    }

    assert_redirected_to account_path
    assert_equal "Address updated successfully.", flash[:notice]

    @tenant.reload
    assert_equal "500 Oak St", @tenant[:AddressLine1]
    assert_equal "Unit 2", @tenant[:AddressLine2]
    assert_equal "Columbus", @tenant[:City]
    assert_equal "OH", @tenant[:State]
    assert_equal "43210-1111", @tenant[:ZipCode]
    assert_equal "500 Oak St, Unit 2, Columbus, OH 43210-1111", @tenant.formatted_tenant_address
  end

  test "blank address update does not change tenant address" do
    log_in_as(@tenant)
    original_address = @tenant.formatted_tenant_address

    patch "/account", params: {
      user: {
        AddressLine1: "",
        AddressLine2: "",
        City: "",
        State: "",
        ZipCode: ""
      },
      commit: "Update Address"
    }

    assert_redirected_to account_path
    assert_equal "No changes detected.", flash[:alert]
    assert_equal original_address, @tenant.reload.formatted_tenant_address
  end

  test "disable 2fa updates user flags" do
    @tenant.update!(two_factor_enabled: false, phone_verified: true)
    log_in_as(@tenant)
    @tenant.update!(two_factor_enabled: true, phone_verified: true)

    patch "/account", params: {
      user: { phone_number: "6145551212" },
      commit: "Disable 2FA"
    }

    assert_redirected_to account_path
    assert_equal false, @tenant.reload[:two_factor_enabled]
    assert_equal false, @tenant.reload[:phone_verified]
  end

  test "enable 2fa requires phone number" do
    @tenant.update!(PhoneNumber: nil)
    log_in_as(@tenant)

    post enable_two_factor_account_path

    assert_redirected_to account_path
    assert_equal "Please add a phone number first.", flash[:alert]
  end

  test "confirm_phone enables 2fa with valid local code" do
    @tenant.update!(
      two_factor_code: "123456",
      two_factor_code_sent_at: 2.minutes.ago,
      PhoneNumber: "6145551212",
      two_factor_enabled: false,
      phone_verified: false
    )
    log_in_as(@tenant)

    post confirm_phone_account_path, params: { code: "123456" }

    assert_redirected_to account_path
    @tenant.reload
    assert_equal true, @tenant[:two_factor_enabled]
    assert_equal true, @tenant[:phone_verified]
    assert_nil @tenant[:two_factor_code]
  end

  test "confirm_phone rejects invalid code" do
    @tenant.update!(
      two_factor_code: "123456",
      two_factor_code_sent_at: 2.minutes.ago,
      PhoneNumber: "6145551212"
    )
    log_in_as(@tenant)

    post confirm_phone_account_path, params: { code: "999999" }

    assert_redirected_to verify_phone_account_path
    assert_equal "Invalid or expired verification code.", flash[:alert]
  end

  test "mediator can update availability" do
    log_in_as(@mediator_user)

    patch "/account", params: {
      user: { mediator_attributes: { id: @mediator_user.mediator.id, Available: false } }
    }

    assert_redirected_to account_path
    assert_equal false, @mediator_user.mediator.reload[:Available]
  end

  test "password update succeeds with confirmation" do
    log_in_as(@tenant)

    patch "/account", params: {
      user: {
        password: "newpassword",
        password_confirmation: "newpassword"
      }
    }

    assert_redirected_to account_path
    assert @tenant.reload.authenticate("newpassword")
  end

  test "password update failure renders show" do
    log_in_as(@tenant)

    patch "/account", params: {
      user: {
        password: "newpassword",
        password_confirmation: "mismatch"
      }
    }

    assert_response :success
    assert_equal "Password update failed.", flash.now[:alert]
  end

  test "update enable 2fa commit requires phone" do
    log_in_as(@tenant)

    patch "/account", params: {
      user: { phone_number: "" },
      commit: "Enable 2FA"
    }

    assert_redirected_to account_path
    assert_equal "Please enter a phone number.", flash[:alert]
  end

  test "enable_two_factor sends code and redirects to verify page" do
    @tenant.update!(PhoneNumber: "6145551212")
    log_in_as(@tenant)

    post enable_two_factor_account_path

    assert_redirected_to verify_phone_account_path
    assert_not_nil @tenant.reload[:two_factor_code]
  end

  test "verify_phone page renders for logged in user" do
    log_in_as(@tenant)

    get verify_phone_account_path

    assert_response :success
  end

  test "confirm_phone rejects expired code" do
    @tenant.update!(
      two_factor_code: "123456",
      two_factor_code_sent_at: 20.minutes.ago,
      PhoneNumber: "6145551212"
    )
    log_in_as(@tenant)

    post confirm_phone_account_path, params: { code: "123456" }

    assert_redirected_to verify_phone_account_path
    assert_equal "Invalid or expired verification code.", flash[:alert]
  end

  test "update enable 2fa commit sends code and redirects" do
    log_in_as(@tenant)

    with_stubbed_twilio(send_ok: true, verify_raises: false, verify_result: false) do
      patch "/account", params: {
        user: { phone_number: "6145551212" },
        commit: "Enable 2FA"
      }
    end

    assert_redirected_to verify_phone_account_path
    assert_not_nil @tenant.reload[:two_factor_code]
  end

  test "update phone number commit handles sms delivery failure" do
    log_in_as(@tenant)

    with_stubbed_twilio(send_ok: false, verify_raises: false, verify_result: false) do
      patch "/account", params: {
        user: { phone_number: "6145551212" },
        commit: "Update Phone Number"
      }
    end

    assert_redirected_to account_path
    assert_equal "Failed to send verification code. Please try again.", flash[:alert]
  end

  test "update enable 2fa uses twilio verify service notice when configured" do
    log_in_as(@tenant)

    with_env("TWILIO_VERIFY_SERVICE_SID" => "service_sid") do
      with_stubbed_twilio(send_ok: true, verify_raises: false, verify_result: true) do
        patch "/account", params: {
          user: { phone_number: "6145551212" },
          commit: "Enable 2FA"
        }
      end
    end

    assert_redirected_to verify_phone_account_path
    assert_match "Verification code sent via SMS", flash[:notice]
  end

  test "confirm phone falls back when twilio verify raises" do
    @tenant.update!(
      two_factor_code: "123456",
      two_factor_code_sent_at: 2.minutes.ago,
      PhoneNumber: "6145551212",
      two_factor_enabled: false,
      phone_verified: false
    )
    log_in_as(@tenant)

    with_env("TWILIO_VERIFY_SERVICE_SID" => "service_sid") do
      with_stubbed_twilio(send_ok: true, verify_raises: true, verify_result: false) do
        post confirm_phone_account_path, params: { code: "123456" }
      end
    end

    assert_redirected_to verify_phone_account_path
    assert_equal "Invalid or expired verification code.", flash[:alert]
  end
end
