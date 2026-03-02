require "test_helper"

class DocumentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = users(:tenant1)
  end

  test "redirects to login when not authenticated" do
    get documents_path
    assert_redirected_to login_path
  end

  test "renders index for logged in user" do
    log_in_as(@tenant)

    get documents_path
    assert_response :success
  end

  test "create redirects when file is missing" do
    log_in_as(@tenant)

    post documents_path

    assert_redirected_to new_document_path
    assert_equal "Please choose a file to upload.", flash[:alert]
  end
end
