require "test_helper"

class AccountControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = users(:tenant1)
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

  test "tenant can update address" do
    log_in_as(@tenant)

    patch "/account", params: {
      user: { TenantAddress: "500 Updated Ave, Columbus, OH" },
      commit: "Update Address"
    }

    assert_redirected_to account_path
    assert_equal "500 Updated Ave, Columbus, OH", @tenant.reload[:TenantAddress]
  end

  test "blank address update does not change tenant address" do
    log_in_as(@tenant)
    original_address = @tenant[:TenantAddress]

    patch "/account", params: {
      user: { TenantAddress: "" },
      commit: "Update Address"
    }

    assert_redirected_to account_path
    assert_equal "No changes detected.", flash[:alert]
    assert_equal original_address, @tenant.reload[:TenantAddress]
  end
end
