require "test_helper"
require "fileutils"

class ResourcesControllerTest < ActionDispatch::IntegrationTest
  test "renders resources index" do
    get resources_path
    assert_response :success
  end

  test "renders resources even if faq files are missing" do
    general_path = Rails.root.join("db", "faq_general.txt")
    privacy_path = Rails.root.join("db", "faq_privacy.txt")
    general_backup = Rails.root.join("db", "faq_general.txt.test_backup")
    privacy_backup = Rails.root.join("db", "faq_privacy.txt.test_backup")

    begin
      FileUtils.mv(general_path, general_backup) if File.exist?(general_path)
      FileUtils.mv(privacy_path, privacy_backup) if File.exist?(privacy_path)

      get resources_path
      assert_response :success
    ensure
      FileUtils.mv(general_backup, general_path) if File.exist?(general_backup)
      FileUtils.mv(privacy_backup, privacy_path) if File.exist?(privacy_backup)
    end
  end
end
