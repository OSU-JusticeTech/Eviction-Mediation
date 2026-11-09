require "test_helper"
require "tmpdir"
require "minitest/mock"

class LegacyDocumentInventoryTest < ActiveSupport::TestCase
  setup do
    @base = Pathname(Dir.mktmpdir("legacy-inventory-"))
    @public = @base.join("public")
    @legacy = @public.join("userFiles")
    @private = @base.join("private")
    FileUtils.mkdir_p([@legacy, @private])
    @configuration = DocumentStorageConfiguration.new(
      root: @private, public_root: @public, legacy_reads_enabled: false
    )
    @inventory = LegacyDocumentInventory.new(configuration: @configuration)
    @one = file_drafts(:one)
    @two = file_drafts(:two)
  end

  teardown do
    File.chmod(0o700, @legacy) if @legacy.directory? && !@legacy.symlink?
    FileUtils.remove_entry(@base)
  end

  test "all rows including signed unattached and soft deleted shared references are inventoried" do
    @legacy.join("shared.txt").write("synthetic")
    @one.update!(FileURLPath: "userFiles/shared.txt", TenantSignature: true)
    @two.update!(FileURLPath: "userFiles/shared.txt", UserDeletedAt: Time.current)
    FileAttachment.where(FileID: [@one.FileID, @two.FileID]).delete_all
    report = @inventory.call
    assert report[:complete]
    refute report[:atomic_snapshot]
    refute report[:legacy_reads_enabled]
    assert_equal FileDraft.unscoped.count, report[:counts][:references]
    shared = report[:classifications][:shared_legacy_locators].sole
    assert_equal [@one.FileID, @two.FileID].sort, shared[:file_ids].sort
    assert_equal 1, shared[:active_count]
    assert_equal 1, shared[:soft_deleted_count]
    assert_equal :present, shared[:status]
    assert_equal @two.FileID, report[:classifications][:soft_deleted_legacy_references].sole[:file_id]
  end

  test "missing legacy and private references and unreferenced files remain distinct" do
    @one.update!(FileURLPath: "userFiles/absent.txt")
    @two.update!(FileURLPath: "privateDocuments/absent.txt")
    @legacy.join("orphan.txt").write("synthetic")
    @private.join("orphan.txt").write("synthetic")
    sections = @inventory.call[:classifications]
    assert_equal "userFiles/absent.txt", sections[:missing_referenced_legacy_files].sole[:locator]
    assert_equal "privateDocuments/absent.txt", sections[:missing_referenced_private_files].sole[:locator]
    assert_equal "userFiles/orphan.txt", sections[:unreferenced_legacy_files].sole[:locator]
    assert_equal "privateDocuments/orphan.txt", sections[:unreferenced_private_files].sole[:locator]
    @two.update!(FileURLPath: "privateDocuments/orphan.txt")
    assert_equal :present, @inventory.call[:classifications][:valid_private_locators].sole[:status]
  end

  test "unsafe names links and directories are never traversed" do
    @legacy.join("regular.txt").write("synthetic")
    @legacy.join(".hidden").write("synthetic")
    @legacy.join("bad..txt").write("synthetic")
    @legacy.join("directory").mkdir
    @legacy.join("directory/nested.txt").write("synthetic")
    @legacy.join(".directory").mkdir
    File.symlink(@base, @legacy.join("link"))
    File.symlink(@base, @legacy.join(".link"))
    File.symlink(@base.join("absent"), @legacy.join("dangling"))
    File.link(@legacy.join("regular.txt"), @legacy.join("hard.txt"))
    @one.update!(FileURLPath: "userFiles/link")
    entries = @inventory.call[:classifications][:unsafe_legacy_entries]
    reasons = entries.to_h { |e| [e[:locator], e[:reason]] }
    assert_equal :invalid_filename, reasons["userFiles/.hidden"]
    assert_equal :invalid_filename, reasons["userFiles/bad..txt"]
    assert_equal :nonregular_entry, reasons["userFiles/directory"]
    assert_equal :nonregular_entry, reasons["userFiles/.directory"]
    assert_equal :symlink, reasons["userFiles/link"]
    assert_equal :symlink, reasons["userFiles/.link"]
    assert_equal :symlink, reasons["userFiles/dangling"]
    assert_equal :multiple_hard_links, reasons["userFiles/hard.txt"]
    assert_equal :multiple_hard_links, reasons["userFiles/regular.txt"]
    refute entries.any? { |e| e[:locator].include?("nested") }
  end

  test "invalid locators are classified without resolving paths" do
    [nil, "", "unknown/a", "userFiles/../outside", "userFiles/a/b", "userFiles/%61",
     "userFiles/" + "a" * 256, "USERFILES/a", "userFiles/é"].each do |locator|
      records = Minitest::Mock.new
      records.expect(:column_names, ["FileID", "FileURLPath", "UserDeletedAt"])
      records.expect(:unscoped, records)
      records.expect(:pluck, [[123, locator, nil]], [:FileID, :FileURLPath, :UserDeletedAt])
      report = LegacyDocumentInventory.new(configuration: @configuration, records: records).call
      reported_locator = report[:classifications][:invalid_or_unknown_locators].sole[:locator]
      if locator.nil?
        assert_nil reported_locator
      else
        assert_equal locator, reported_locator
      end
      assert_equal 1, report[:counts][:invalid_references]
      records.verify
    end
  end

  test "schema without soft deletion explicitly reports unknown status" do
    records = Minitest::Mock.new
    records.expect(:column_names, ["FileID", "FileURLPath"])
    records.expect(:unscoped, records)
    records.expect(:pluck, [[123, "userFiles/a"]], [:FileID, :FileURLPath])
    report = LegacyDocumentInventory.new(configuration: @configuration, records: records).call
    refute report[:soft_deletion_column_present]
    assert_equal :unknown, report[:references].sole[:deletion_status]
    records.verify
  end

  test "missing unreadable and symlink roots or ancestors fail without creating roots" do
    @legacy.rmdir
    error = assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
    assert_nil error.cause
    refute @legacy.exist?
    @legacy.mkdir
    File.chmod(0o000, @legacy)
    assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
    File.chmod(0o700, @legacy)
    @legacy.rmdir
    File.symlink(@private, @legacy)
    assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
    @legacy.unlink
    @public.rmdir
    File.symlink(@private, @public)
    assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
  end

  test "private root failures also prevent a complete legacy report" do
    @private.rmdir
    assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
    refute @private.exist?
    @private.mkdir
    File.chmod(0o000, @private)
    assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
  ensure
    File.chmod(0o700, @private) if @private.directory?
  end

  test "query enumeration and lstat failures never return partial success or sensitive causes" do
    relation = FileDraft.unscoped
    relation.stub(:pluck, ->(*) { raise "sensitive locator and ID" }) do
      FileDraft.stub(:unscoped, relation) do
        error = assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
        assert_nil error.cause
        refute_match(/sensitive/, error.message)
      end
    end
    Dir.stub(:children, ->(*) { raise Errno::EACCES, "sensitive path" }) do
      assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
    end
    @legacy.join("a").write("synthetic")
    original = File.method(:lstat)
    File.stub(:lstat, ->(path) {
      raise Errno::EACCES if path.to_s == @legacy.join("a").to_s
      original.call(path)
    }) do
      assert_raises(LegacyDocumentInventory::Failure) { @inventory.call }
    end
  end

  test "inventory performs no content reads filesystem writes database writes or logging" do
    @legacy.join("a.txt").write("synthetic")
    @one.update!(FileURLPath: "userFiles/a.txt")
    before_rows = FileDraft.unscoped.order(:FileID).map(&:attributes)
    before_attachments = FileAttachment.order(:FileID).map(&:attributes)
    snapshot = -> { [@base, @public, @legacy, @private, @legacy.join("a.txt")].map do |p|
      stat = p.lstat
      [p.to_s, stat.ino, stat.mode, stat.size, stat.mtime, stat.ctime, stat.nlink]
    end }
    before_files = snapshot.call
    rows = FileDraft.unscoped.pluck(:FileID, :FileURLPath, :UserDeletedAt)
    records = Minitest::Mock.new
    records.expect(:column_names, ["FileID", "FileURLPath", "UserDeletedAt"])
    records.expect(:unscoped, records)
    records.expect(:pluck, rows, [:FileID, :FileURLPath, :UserDeletedAt])
    inventory = LegacyDocumentInventory.new(configuration: @configuration, records: records)
    forbidden = ->(*) { flunk "inventory attempted content IO, mutation or logging" }
    File.stub(:open, forbidden) do
      File.stub(:read, forbidden) do
        File.stub(:binread, forbidden) do
          File.stub(:write, forbidden) do
            Dir.stub(:mkdir, forbidden) do
              Rails.logger.stub(:add, forbidden) { inventory.call }
            end
          end
        end
      end
    end
    assert_equal before_files, snapshot.call
    assert_equal before_rows, FileDraft.unscoped.order(:FileID).map(&:attributes)
    assert_equal before_attachments, FileAttachment.order(:FileID).map(&:attributes)
    assert_equal ["a.txt"], Dir.children(@legacy)
    assert_empty Dir.children(@private)
    records.verify
  end
end
