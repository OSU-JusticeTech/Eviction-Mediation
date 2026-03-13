require "test_helper"
require "minitest/mock" # Enable Minitest's `stub` helper in this test file

class ResourcesControllerTest < ActionDispatch::IntegrationTest
  test "renders resources index" do
    get resources_path
    assert_response :success
  end

  test "renders resources even if faq files are missing" do
    general_path = Rails.root.join("db", "faq_general.txt")
    privacy_path = Rails.root.join("db", "faq_privacy.txt")
    # Keep the real method for all non-FAQ paths during request rendering
    original_exist = File.method(:exist?)

    File.stub(:exist?, ->(path) {
      pathname = Pathname.new(path.to_s)
      if pathname == general_path || pathname == privacy_path
        # Simulate only these two files as missing
        false
      else
        # Avoid affecting unrelated File.exist? checks in Rails/view rendering
        original_exist.call(path)
      end
    }) do
      get resources_path
      assert_response :success
    end
  end
end
