require "test_helper"
require "tmpdir"
require "stringio"
require "minitest/mock"

class DocumentFileInventoryTest < ActiveSupport::TestCase
  setup do
    @root = Pathname(Dir.mktmpdir("document-inventory-"))
    @storage = DocumentStorage.new(configuration: DocumentStorageConfiguration.new(
      root: @root, public_root: Rails.root.join("public"), legacy_reads_enabled: false
    ))
    @inventory = DocumentFileInventory.new(storage: @storage)
    @file = file_drafts(:one)
    @locator = @storage.store(io: StringIO.new("retained"), extension: "txt")
    @file.update!(FileURLPath: @locator)
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "active attached signed and soft deleted shared references are retained without metadata changes" do
    other = file_drafts(:two)
    other.update!(FileURLPath: @locator, UserDeletedAt: Time.current)
    @file.update!(TenantSignature: true)
    before = FileDraft.unscoped.order(:FileID).map(&:attributes)
    attachments = FileAttachment.count
    report = @inventory.call
    item = report[:referenced_private_files].find { |entry| entry[:locator] == @locator }
    assert_equal [@file.FileID, other.FileID].sort, item[:file_ids].sort
    assert_equal before, FileDraft.unscoped.order(:FileID).map(&:attributes)
    assert_equal attachments, FileAttachment.count
    assert_equal "retained", @storage.resolve(@locator).binread
  end

  test "unreferenced historical bytes missing references and legacy locators have distinct categories" do
    @file.update!(FileURLPath: "privateDocuments/missing.txt")
    file_drafts(:two).update!(FileURLPath: "userFiles/old.txt")
    report = @inventory.call
    assert_includes report[:unreferenced_private_files], { locator: @locator, file_ids: [] }
    assert_includes report[:missing_referenced_files], { locator: @file.FileURLPath, file_ids: [@file.FileID] }
    assert_includes report[:legacy_references], { locator: "userFiles/old.txt", file_ids: [file_drafts(:two).FileID] }
    assert report[:dry_run]
    refute report[:physical_deletion_enabled]
    assert_equal "retained", @storage.resolve(@locator).binread
  end

  test "invalid locators traversal symlinks directories staging and hard links are unsafe" do
    @file.update!(FileURLPath: "privateDocuments/../outside.txt")
    file_drafts(:two).update!(FileURLPath: "userFiles/../outside.txt")
    File.symlink(@storage.resolve(@locator), @root.join("link.txt"))
    File.symlink(@root.join("absent"), @root.join("dangling.txt"))
    File.link(@storage.resolve(@locator), @root.join("hard.txt"))
    @root.join("directory").mkdir
    @root.join(".document-stage.txt").write("staging")
    report = @inventory.call
    unsafe = report[:invalid_or_unsafe_locators].map { |item| item[:locator] }
    [@file.FileURLPath, file_drafts(:two).FileURLPath, @locator,
     "privateDocuments/link.txt", "privateDocuments/dangling.txt", "privateDocuments/hard.txt",
     "privateDocuments/directory", "privateDocuments/.document-stage.txt"].each do |locator|
      assert_includes unsafe, locator
    end
    [nil, "", "unknown/a", "privateDocuments/a/b", "privateDocuments/" + "a" * 256].each do |locator|
      assert_equal :unsafe, @storage.private_inventory_status(locator)
    end
    assert @root.join("link.txt").symlink?
  end

  test "database query failures abort instead of reporting files as unreferenced" do
    relation = FileDraft.unscoped
    relation.stub(:pluck, ->(*) { raise ActiveRecord::StatementInvalid, "query failed" }) do
      FileDraft.stub(:unscoped, relation) do
        error = assert_raises(DocumentFileInventory::Failure) { @inventory.call }
        assert_instance_of ActiveRecord::StatementInvalid, error.cause
      end
    end
    assert_equal "retained", @storage.resolve(@locator).binread
  end

  test "reference created after the query demonstrates stale classification without deleting bytes" do
    @file.update!(FileURLPath: "userFiles/old.txt")
    scan = @storage.method(:private_inventory_entries)
    @storage.stub(:private_inventory_entries, -> {
      @file.update!(FileURLPath: @locator)
      scan.call
    }) do
      @storage.stub(:delete_private, ->(*) { flunk "inventory attempted deletion" }) do
        report = @inventory.call
        assert_includes report[:unreferenced_private_files], { locator: @locator, file_ids: [] }
      end
    end
    assert_equal @locator, @file.reload.FileURLPath
    assert_equal "retained", @storage.resolve(@locator).binread
  end

  test "filesystem failures abort without a partial report" do
    @storage.stub(:private_inventory_entries, -> { raise DocumentStorage::Unavailable }) do
      assert_raises(DocumentFileInventory::Failure) { @inventory.call }
    end
    assert_equal "retained", @storage.resolve(@locator).binread
  end

  test "symlink root and missing root abort without creating or traversing storage" do
    alias_root = @root.join("alias")
    File.symlink(@root, alias_root)
    [alias_root, @root.join("absent")].each do |root|
      storage = DocumentStorage.new(configuration: DocumentStorageConfiguration.new(
        root: root, public_root: Rails.root.join("public")
      ))
      assert_raises(DocumentFileInventory::Failure) do
        DocumentFileInventory.new(storage: storage).call
      end
    end
    refute @root.join("absent").exist?
    assert_equal "retained", @storage.resolve(@locator).binread
  end
end
