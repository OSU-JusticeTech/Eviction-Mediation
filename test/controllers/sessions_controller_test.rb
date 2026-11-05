require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  setup do
    @user = users(:landlord1)
  end

  test "renders the login page" do
    get login_url
    assert_response :success
  end

  test "creates a session with valid credentials" do
    post login_url, params: { email: @user[:Email], password: "password" }

    assert_redirected_to dashboard_url
    assert_equal @user[:UserID], session[:user_id]

    follow_redirect!
    assert_response :success
  end

  test "rejects invalid credentials" do
    post login_url, params: { email: @user[:Email], password: "wrong-password" }

    assert_response :unprocessable_entity
    assert_nil session[:user_id]
    assert_equal "Invalid email or password", flash[:error]
  end

  test "logs out and clears the session" do
    post login_url, params: { email: @user[:Email], password: "password" }
    assert_equal @user[:UserID], session[:user_id]

    get logout_url

    assert_redirected_to root_url
    assert_nil session[:user_id]
    assert_equal "Logged out successfully!", flash[:notice]

    follow_redirect!
    assert_response :success
  end

  test "logout broadcasts a user-wide disconnect with reconnect disabled" do
    log_in_as(@user)
    remote = ActionCable.server.remote_connections.where(current_user: @user)
    assert_broadcast_on(remote.send(:internal_channel), type: "disconnect", reconnect: false) do
      delete logout_path
    end
    assert_nil session[:user_id]
    assert_redirected_to root_path
  end

  test "anonymous logout does not target any authenticated connection" do
    remote = ActionCable.server.remote_connections.where(current_user: @user)
    assert_no_broadcasts(remote.send(:internal_channel)) { delete logout_path }
    assert_nil session[:user_id]
    assert_redirected_to root_path
  end
end
