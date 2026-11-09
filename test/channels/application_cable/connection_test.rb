require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection

  test "authenticates using the Rails session user id" do
    user = users(:tenant1)
    connect session: { user_id: user.UserID }
    assert_equal user, connection.current_user
  end

  test "rejects anonymous connections despite claimed parameters and cookies" do
    cookies[:user_id] = users(:tenant1).UserID
    assert_reject_connection { connect params: { user_id: users(:tenant1).UserID } }
  end

  test "rejects nonexistent and blank session identities" do
    [0, "", "invalid"].each do |id|
      assert_reject_connection { connect session: { user_id: id } }
    end
  end

  test "pending two factor verification is not an authenticated session" do
    assert_reject_connection do
      connect session: { pending_user_id: users(:tenant1).UserID }
    end
  end
end

# Connection::TestCase stubs session decoding. Also exercise a real login-cookie
# round trip through Rails middleware before passing its request to the connection.
class CableSessionIntegrationTest < ActionDispatch::IntegrationTest
  test "connection accepts the session decoded from an existing Rails login cookie" do
    user = users(:tenant1)
    log_in_as(user)
    get dashboard_path
    assert_response :success
    cable = ApplicationCable::Connection.allocate
    cable.singleton_class.include(ActionCable::Connection::TestConnection)
    cable.send(:initialize, request)
    cable.connect
    assert_equal user, cable.current_user
  end
end
