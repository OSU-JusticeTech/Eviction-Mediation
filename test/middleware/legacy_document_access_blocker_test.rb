require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rack/mock"
require "action_dispatch"
require_relative "../../lib/legacy_document_access_blocker"

class LegacyDocumentAccessBlockerTest < Minitest::Test
  def test_blocks_real_static_files_before_static_delivery
    Dir.mktmpdir("legacy-static-") do |root|
      FileUtils.mkdir_p(File.join(root, "userFiles"))
      File.write(File.join(root, "userFiles", "legacy.txt"), "sensitive legacy bytes")
      File.write(File.join(root, "asset.txt"), "public asset")
      fallback = ->(_) { [404, {}, ["fallback"]] }
      static = ActionDispatch::Static.new(fallback, root)
      # Positive control: the static server really can expose these bytes.
      assert_equal "sensitive legacy bytes", Rack::MockRequest.new(static).get("/userFiles/legacy.txt").body
      request = Rack::MockRequest.new(LegacyDocumentAccessBlocker.new(static))
      %w[GET HEAD].each do |method|
        ["/userFiles/legacy.txt", "/userFiles", "/userFiles/", "/%75serFiles/legacy.txt",
         "/userFiles%2flegacy.txt", "//userFiles/legacy.txt", "/x/../userFiles/legacy.txt",
         "/userFiles/../asset.txt"].each do |path|
          # Preserve the raw path: URI parsing treats a leading // as a host.
          response = request.request(method, path, "PATH_INFO" => path)
          assert_equal 404, response.status, path
          assert_includes response["cache-control"], "no-store", path
          refute_includes response.body, "sensitive legacy bytes"
        end
      end
      assert_equal "public asset", request.get("/asset.txt").body
    end
  end
end
