# Deliberately independent of test_helper: these filesystem tests need neither
# Rails boot, dotenv/credentials, the database, nor application fixtures.
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../lib/document_storage_configuration"
require_relative "../../app/services/document_storage"

class DocumentStorageTest < Minitest::Test
  def setup
    @sandbox = Pathname(Dir.mktmpdir("document-storage-test-"))
    @root = @sandbox.join("storage/documents")
    @public = @sandbox.join("public")
    @legacy = @public.join("userFiles")
    FileUtils.mkdir_p([@root, @legacy])
    @configuration = configuration
    @storage = DocumentStorage.new(configuration: @configuration)
  end

  def teardown
    FileUtils.remove_entry(@sandbox) if @sandbox&.directory?
  end

  def test_upload_is_private_complete_and_owner_readable_only
    locator = @storage.store(io: StringIO.new("uploaded bytes"), extension: ".PDF")
    assert_match(/\AprivateDocuments\/[0-9a-f-]{36}\.pdf\z/, locator)
    path = @storage.resolve(locator)
    assert_equal @root, path.dirname
    assert_equal "uploaded bytes", path.binread
    assert_equal 0o600, path.stat.mode & 0o777
    assert_empty @legacy.children
    assert_equal [path], @root.children
  end

  def test_generator_can_write_to_a_private_staging_path
    locator = @storage.write(extension: "html") do |path|
      assert_equal @root, path.dirname
      path.write("<p>Agreement</p>")
    end
    assert_equal "<p>Agreement</p>", @storage.resolve(locator).read
  end

  def test_failed_generation_cleans_staging_and_preserves_legacy
    legacy = @legacy.join("TestDocument1.pdf")
    legacy.binwrite("historical bytes")
    assert_raises(RuntimeError) do
      @storage.write(extension: "pdf") do |path|
        path.write("partial")
        raise "generation failed"
      end
    end
    assert_empty @root.children
    assert_equal "historical bytes", legacy.binread
  end

  def test_historical_named_files_are_read_without_modification
    path = @legacy.join("Test Document1.pdf")
    path.binwrite("signed historical bytes")
    before = path.stat
    assert_equal path, @storage.resolve("userFiles/Test Document1.pdf")
    assert_equal "signed historical bytes", path.binread
    assert_equal before.mtime, path.stat.mtime
    assert_empty @root.children
  end

  def test_private_replacement_leaves_original_untouched
    original = @legacy.join("agreement.html")
    original.write("original")
    locator = @storage.write(extension: "html") { |path| path.write("signed") }
    assert_equal "signed", @storage.resolve(locator).read
    assert_equal "original", original.read
  end

  def test_missing_private_file_never_falls_back_to_legacy
    @legacy.join("same.pdf").write("obsolete")
    assert_raises(DocumentStorage::MissingFile) { @storage.resolve("privateDocuments/same.pdf") }
  end

  def test_legacy_reads_can_be_disabled
    @legacy.join("old.pdf").write("old")
    storage = DocumentStorage.new(configuration: configuration(legacy_reads_enabled: false))
    assert_raises(DocumentStorage::MissingFile) { storage.resolve("userFiles/old.pdf") }
    locator = storage.store(io: StringIO.new("new"), extension: "pdf")
    assert_equal "new", storage.resolve(locator).read
  end

  def test_invalid_locators_fail_closed
    [nil, "", "/etc/passwd", "other/a.pdf", "userFiles/../a.pdf",
     "userFiles/nested/a.pdf", "userFiles/a\\b.pdf", "userFiles/%2e%2e.pdf",
     "userFiles/a\0.pdf", "userFiles/.hidden", "privateDocuments/" + "a" * 256].each do |locator|
      assert_raises(DocumentStorage::InvalidLocator, locator.inspect) { @storage.resolve(locator) }
    end
  end

  def test_invalid_extensions_do_not_write_files
    ["../pdf", "pdf/evil", "", "pdf\0", "a" * 11].each do |extension|
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.store(io: StringIO.new("bytes"), extension: extension)
      end
    end
    assert_empty @root.children
  end

  def test_file_symlinks_are_rejected_for_reads_and_deletes
    target = @sandbox.join("outside.pdf")
    target.write("outside")
    File.symlink(target, @root.join("link.pdf"))
    assert_raises(DocumentStorage::InvalidLocator) { @storage.resolve("privateDocuments/link.pdf") }
    assert_raises(DocumentStorage::InvalidLocator) { @storage.delete_private("privateDocuments/link.pdf") }
    assert_equal "outside", target.read
  end

  def test_symlinked_storage_directory_is_rejected
    alias_root = @sandbox.join("alias")
    File.symlink(@root, alias_root)
    storage = DocumentStorage.new(configuration: configuration(root: alias_root))
    assert_raises(DocumentStorage::InvalidLocator) { storage.store(io: StringIO.new("bytes"), extension: "txt") }
  end

  def test_missing_storage_is_unavailable_and_is_not_created
    absent = @sandbox.join("absent/documents")
    storage = DocumentStorage.new(configuration: configuration(root: absent))
    assert_raises(DocumentStorage::Unavailable) { storage.store(io: StringIO.new("bytes"), extension: "txt") }
    refute absent.exist?
  end

  def test_io_errors_have_a_typed_error_without_a_path
    io = Object.new
    def io.read(*)
      raise IOError, "sensitive path"
    end
    error = assert_raises(DocumentStorage::Unavailable) { @storage.store(io: io, extension: "txt") }
    refute_includes error.message, "sensitive path"
    assert_empty @root.children
  end

  def test_private_deletion_is_retryable_and_cannot_delete_legacy
    locator = @storage.store(io: StringIO.new("bytes"), extension: "txt")
    assert @storage.delete_private(locator)
    refute @storage.delete_private(locator)
    @legacy.join("old.txt").write("historical")
    assert_raises(DocumentStorage::InvalidLocator) { @storage.delete_private("userFiles/old.txt") }
    assert_equal "historical", @legacy.join("old.txt").read
  end

  def test_deletion_failure_is_reported
    locator = @storage.store(io: StringIO.new("bytes"), extension: "txt")
    File.stub(:delete, ->(*) { raise Errno::EACCES }) do
      assert_raises(DocumentStorage::Unavailable) { @storage.delete_private(locator) }
    end
    assert_equal "bytes", @storage.resolve(locator).read
  end

  def test_environment_defaults_and_test_isolation
    development = DocumentStorageConfiguration.from_environment(environment: "development", rails_root: @sandbox, env: {})
    test = DocumentStorageConfiguration.from_environment(environment: "test", rails_root: @sandbox, env: {})
    assert_equal @sandbox.join("storage/documents"), development.root
    assert_equal @sandbox.join("tmp/document-storage"), test.root
    assert development.legacy_reads_enabled
  end

  def test_production_requires_an_explicit_absolute_private_root_on_use
    config = DocumentStorageConfiguration.from_environment(environment: "production", rails_root: @sandbox, env: {})
    assert_raises(DocumentStorageConfiguration::InvalidConfiguration) { config.validate! }
    assert_raises(DocumentStorageConfiguration::InvalidConfiguration) { configuration(root: "relative").validate! }
    assert_raises(DocumentStorageConfiguration::InvalidConfiguration) { configuration(root: @public.join("documents")).validate! }
    assert_equal @sandbox, configuration(root: @sandbox).validate!.root
    explicit = DocumentStorageConfiguration.from_environment(environment: "production", rails_root: @sandbox,
      env: { "DOCUMENT_STORAGE_ROOT" => @root.to_s, "DOCUMENT_LEGACY_READS_ENABLED" => "false" })
    assert_equal explicit, explicit.validate!
    refute explicit.legacy_reads_enabled
  end

  def test_symlink_into_public_is_rejected_by_configuration
    alias_root = @sandbox.join("unsafe-alias")
    File.symlink(@public, alias_root)
    assert_raises(DocumentStorageConfiguration::InvalidConfiguration) { configuration(root: alias_root.join("documents")).validate! }
  end

  def test_invalid_boolean_configuration_is_rejected
    assert_raises(DocumentStorageConfiguration::InvalidConfiguration) do
      DocumentStorageConfiguration.from_environment(environment: "test", rails_root: @sandbox,
        env: { "DOCUMENT_LEGACY_READS_ENABLED" => "yes" })
    end
  end

  def test_public_root_itself_is_rejected_but_a_sibling_prefix_is_allowed
    assert_raises(DocumentStorageConfiguration::InvalidConfiguration) { configuration(root: @public).validate! }
    sibling = @sandbox.join("public-private")
    assert_equal sibling, configuration(root: sibling).validate!.root
  end

  def test_public_descendant_is_rejected_before_directories_exist
    assert_raises(DocumentStorageConfiguration::InvalidConfiguration) do
      configuration(root: @public.join("missing/documents")).validate!
    end
    refute @public.join("missing").exist?
  end

  def test_publication_collision_preserves_existing_bytes_and_cleans_staging
    name = "00000000-0000-0000-0000-000000000000"
    existing = @root.join("#{name}.pdf")
    existing.write("original")
    SecureRandom.stub(:uuid, name) do
      assert_raises(DocumentStorage::Unavailable) do
        @storage.store(io: StringIO.new("replacement"), extension: "pdf")
      end
    end
    assert_equal "original", existing.read
    assert_equal [existing], @root.children
  end

  def test_publication_failure_cleans_staging
    File.stub(:link, ->(*) { raise Errno::EACCES }) do
      assert_raises(DocumentStorage::Unavailable) do
        @storage.store(io: StringIO.new("complete"), extension: "pdf")
      end
    end
    assert_empty @root.children
  end

  def test_generator_failure_after_removing_staging_is_preserved
    failure = RuntimeError.new("generator failed")
    error = assert_raises(RuntimeError) do
      @storage.write(extension: "pdf") do |path|
        path.unlink
        raise failure
      end
    end
    assert_same failure, error
    assert_empty @root.children
  end

  def test_missing_staging_file_is_a_typed_failure
    assert_raises(DocumentStorage::Unavailable) do
      @storage.write(extension: "pdf") { |path| path.unlink }
    end
    assert_empty @root.children
  end

  def test_staging_symlink_is_removed_without_changing_target
    target = @sandbox.join("target.pdf")
    target.write("outside")
    target.chmod(0o644)
    assert_raises(DocumentStorage::InvalidLocator) do
      @storage.write(extension: "pdf") do |path|
        path.unlink
        File.symlink(target, path)
      end
    end
    assert_equal "outside", target.read
    assert_equal 0o644, target.stat.mode & 0o777
    assert_empty @root.children
  end

  def test_staging_hard_link_is_rejected_before_changing_target_permissions
    target = @sandbox.join("target.pdf")
    target.write("outside")
    target.chmod(0o644)
    assert_raises(DocumentStorage::InvalidLocator) do
      @storage.write(extension: "pdf") do |path|
        path.unlink
        File.link(target, path)
      end
    end
    assert_equal 0o644, target.stat.mode & 0o777
    assert_equal 1, target.stat.nlink
    assert_empty @root.children
  end

  def test_cleanup_failure_does_not_mask_generator_failure
    failure = RuntimeError.new("generator failed")
    File.stub(:unlink, ->(*) { raise Errno::EACCES }) do
      error = assert_raises(RuntimeError) do
        @storage.write(extension: "pdf") { raise failure }
      end
      assert_same failure, error
    end
  end

  def test_staging_cleanup_failure_preserves_publication_and_reports_locator
    staging = nil
    original_unlink = File.method(:unlink)
    error = File.stub(:unlink, ->(path) {
      raise Errno::EACCES, "sensitive path" if path == staging
      original_unlink.call(path)
    }) do
      assert_raises(DocumentStorage::CleanupFailure) do
        @storage.write(extension: "pdf") do |path|
          staging = path
          path.write("complete")
        end
      end
    end
    published = @storage.resolve(error.locator)
    assert_equal "complete", published.binread
    assert_equal 0o600, published.stat.mode & 0o777
    assert_equal [staging, published].sort, @root.children.sort
    refute_includes error.message, "sensitive path"
    assert_instance_of Errno::EACCES, error.cause
  end

  def test_cleanup_failure_does_not_mask_publication_failure
    failure = Errno::EEXIST.new("publication failed")
    File.stub(:link, ->(*) { raise failure }) do
      File.stub(:unlink, ->(*) { raise Errno::EACCES, "cleanup failed" }) do
        error = assert_raises(DocumentStorage::Unavailable) do
          @storage.store(io: StringIO.new("complete"), extension: "pdf")
        end
        assert_same failure, error.cause
      end
    end
    assert_equal 1, @root.children.size
    assert_match(/\A\.document-/, @root.children.first.basename.to_s)
  end

  private

  def configuration(root: @root, legacy_reads_enabled: true)
    DocumentStorageConfiguration.new(root: root, public_root: @public, legacy_reads_enabled: legacy_reads_enabled)
  end
end
