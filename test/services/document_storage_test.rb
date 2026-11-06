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

  def test_allocation_normalizes_extension_and_creates_nothing
    first = @storage.allocate_private_locator(extension: ".PDF")
    second = @storage.allocate_private_locator(extension: "pdf")
    assert_match(/\AprivateDocuments\/[0-9a-f-]{36}\.pdf\z/, first)
    refute_equal first, second
    assert_empty @root.children
    assert_empty @legacy.children
    assert_raises(DocumentStorage::InvalidLocator) do
      @storage.allocate_private_locator(extension: "../pdf")
    end
  end

  def test_exact_publication_is_atomic_and_private
    locator = @storage.allocate_private_locator(extension: "pdf")
    destination = @root.join(locator.delete_prefix("privateDocuments/"))
    link = File.method(:link)
    linked = false
    File.stub(:link, ->(staged, target) {
      assert_equal destination, target
      refute target.exist?
      assert_equal "complete bytes", staged.binread
      assert_equal 0o600, staged.stat.mode & 0o777
      link.call(staged, target)
      assert_equal "complete bytes", target.binread
      linked = true
    }) do
      result = @storage.publish_private(locator: locator) do |path|
        path.binwrite("partial")
        refute destination.exist?
        path.binwrite("complete bytes")
      end
      assert_equal locator, result
    end
    assert linked
    assert_equal [destination], @root.children
  end

  def test_explicit_collision_preserves_existing_target
    locator = @storage.allocate_private_locator(extension: "txt")
    @storage.publish_private(locator: locator) { |path| path.write("original") }
    assert_raises(DocumentStorage::Unavailable) do
      @storage.publish_private(locator: locator) { |path| path.write("replacement") }
    end
    assert_equal "original", @storage.resolve(locator).read
    assert_equal 1, @root.children.size
  end

  def test_explicit_unsafe_locators_never_reach_writer_or_inspection
    [nil, "/tmp/arbitrary.pdf", "userFiles/a.pdf", "privateDocuments/../a.pdf",
     "privateDocuments/nested/a.pdf", "privateDocuments/a\\b.pdf",
     "privateDocuments/%2e.pdf", "privateDocuments/" + "a" * 256].each do |locator|
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.publish_private(locator: locator) { flunk "unsafe writer invoked" }
      end
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.open_private(locator) { flunk "unsafe file opened" }
      end
    end
    assert_empty @root.children
  end

  def test_explicit_publication_and_inspection_reject_symlinks_including_dangling
    target = @sandbox.join("outside.txt")
    target.write("outside")
    [target, @sandbox.join("missing.txt")].each_with_index do |outside, index|
      locator = "privateDocuments/link#{index}.txt"
      File.symlink(outside, @root.join("link#{index}.txt"))
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.publish_private(locator: locator) { flunk "symlink writer invoked" }
      end
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.open_private(locator) { flunk "symlink followed" }
      end
    end
    assert_equal "outside", target.read
  end

  def test_explicit_apis_reject_symlinked_ancestors
    alias_parent = @sandbox.join("alias-storage")
    File.symlink(@root.parent, alias_parent)
    storage = DocumentStorage.new(configuration: configuration(root: alias_parent.join("documents")))
    locator = storage.allocate_private_locator(extension: "txt")
    assert_raises(DocumentStorage::InvalidLocator) do
      storage.publish_private(locator: locator) { flunk "unsafe root" }
    end
    assert_raises(DocumentStorage::InvalidLocator) { storage.open_private(locator) { flunk "unsafe root" } }
    assert_empty @root.children
  end

  def test_explicit_write_and_link_failures_clean_staging
    locator = @storage.allocate_private_locator(extension: "txt")
    assert_raises(DocumentStorage::Unavailable) do
      @storage.publish_private(locator: locator) { |path| path.write("partial"); raise IOError, "write failed" }
    end
    assert_empty @root.children
    File.stub(:link, ->(*) { raise Errno::ENOSPC }) do
      assert_raises(DocumentStorage::Unavailable) do
        @storage.publish_private(locator: locator) { |path| path.write("complete") }
      end
    end
    assert_empty @root.children
    # Allocation itself is not consumed by an unsuccessful publication.
    @storage.publish_private(locator: locator) { |path| path.write("retry") }
    assert_equal "retry", @storage.resolve(locator).read
  end

  def test_later_caller_failure_does_not_remove_published_target
    locator = @storage.allocate_private_locator(extension: "txt")
    assert_raises(RuntimeError) do
      @storage.publish_private(locator: locator) { |path| path.write("retained") }
      raise "simulated journal failure"
    end
    assert_equal "retained", @storage.resolve(locator).read
  end

  def test_safe_inspection_yields_binary_read_only_descriptor_and_closes_it
    locator = @storage.store(io: StringIO.new("bytes\x00\xff".b), extension: "txt")
    descriptor = nil
    result = @storage.open_private(locator) do |file|
      descriptor = file
      assert file.binmode?
      assert_equal "bytes\x00\xff".b, file.read
      assert_raises(IOError) { file.write("replacement") }
      :inspected
    end
    assert_equal :inspected, result
    assert descriptor.closed?
    assert_raises(RuntimeError) do
      @storage.open_private(locator) { |file| descriptor = file; raise "inspection failed" }
    end
    assert descriptor.closed?
    assert_raises(DocumentStorage::MissingFile) do
      @storage.open_private("privateDocuments/absent.txt") { flunk "missing file opened" }
    end
  end

  def test_inspection_rejects_directories_and_multiple_hard_links
    @root.join("directory").mkdir
    assert_raises(DocumentStorage::InvalidLocator) do
      @storage.open_private("privateDocuments/directory") { flunk "directory opened" }
    end
    locator = @storage.store(io: StringIO.new("bytes"), extension: "txt")
    File.link(@storage.resolve(locator), @sandbox.join("another-link"))
    assert_raises(DocumentStorage::InvalidLocator) { @storage.open_private(locator) { flunk "hard link opened" } }
  end

  def test_inspection_rejects_replacement_between_lstat_and_open
    locator = @storage.store(io: StringIO.new("original"), extension: "txt")
    destination = @storage.resolve(locator)
    replacement = @sandbox.join("replacement.txt")
    replacement.write("replacement")
    open_file = File.method(:open)
    File.stub(:open, ->(path, *args, &block) {
      File.rename(replacement, destination) if Pathname(path) == destination
      open_file.call(path, *args, &block)
    }) do
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.open_private(locator) { flunk "replacement yielded" }
      end
    end
  end

  def test_inspection_rejects_destination_replacement_during_block
    locator = @storage.store(io: StringIO.new("original"), extension: "txt")
    destination = @storage.resolve(locator)
    replacement = @sandbox.join("replacement.txt")
    replacement.write("replacement")
    replacement.chmod(0o600)
    descriptor = nil
    assert_raises(DocumentStorage::InvalidLocator) do
      @storage.open_private(locator) do |file|
        descriptor = file
        File.rename(replacement, destination)
        assert_equal "original", file.read
      end
    end
    assert descriptor.closed?
    assert_equal "replacement", destination.read
  end

  def test_inspection_revalidates_root_after_block
    locator = @storage.store(io: StringIO.new("original"), extension: "txt")
    moved_root = @root.parent.join("moved-documents")
    assert_raises(DocumentStorage::InvalidLocator) do
      @storage.open_private(locator) do
        File.rename(@root, moved_root)
        File.symlink(moved_root, @root)
      end
    end
  end

  def test_inspection_rejects_permissions_outside_private_publication_contract
    locator = @storage.store(io: StringIO.new("bytes"), extension: "txt")
    destination = @storage.resolve(locator)
    [0o644, 0o620, 0o601, 0o700, 0o4600].each do |mode|
      destination.chmod(mode)
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.open_private(locator) { flunk "unsafe permissions accepted" }
      end
    end
    destination.chmod(0o600)
    assert_raises(DocumentStorage::InvalidLocator) do
      @storage.open_private(locator) { destination.chmod(0o644) }
    end
  end

  def test_caller_exception_remains_primary_when_destination_disappears
    locator = @storage.store(io: StringIO.new("bytes"), extension: "txt")
    [RuntimeError.new("inspection failed"), IOError.new("caller I/O failed"),
     Errno::EACCES.new("caller operation failed")].each do |failure|
      destination = @storage.resolve(locator)
      descriptor = nil
      error = assert_raises(failure.class) do
        @storage.open_private(locator) do |file|
          descriptor = file
          destination.unlink
          raise failure
        end
      end
      assert_same failure, error
      assert descriptor.closed?
      @storage.publish_private(locator: locator) { |path| path.write("bytes") }
    end
  end

  def test_inspection_accepts_existing_write_files_without_modification
    locator = @storage.write(extension: "pdf") { |path| path.binwrite("existing bytes") }
    destination = @storage.resolve(locator)
    before = destination.stat
    assert_equal "existing bytes", @storage.open_private(locator) { |file| file.read }
    after = destination.stat
    assert_equal [before.dev, before.ino, before.mode, before.size, before.mtime],
      [after.dev, after.ino, after.mode, after.size, after.mtime]
    assert_equal 0o600, after.mode & 0o7777
  end

  def test_explicit_publication_rejects_a_destination_symlink_created_by_writer
    locator = @storage.allocate_private_locator(extension: "txt")
    target = @sandbox.join("outside.txt")
    target.write("outside")
    destination = @root.join(locator.delete_prefix("privateDocuments/"))
    assert_raises(DocumentStorage::InvalidLocator) do
      @storage.publish_private(locator: locator) do |path|
        path.write("complete")
        File.symlink(target, destination)
      end
    end
    assert_equal "outside", target.read
    assert destination.symlink?
    assert_equal [destination], @root.children
  end

  def test_legacy_descriptor_is_binary_read_only_closed_and_preserves_source
    path = @legacy.join("Test Document1.pdf")
    bytes = "historical\x00\xff".b
    path.binwrite(bytes)
    File.chmod(0o640, path)
    before = path.stat
    descriptor = nil
    result = @storage.open_legacy("userFiles/Test Document1.pdf") do |file|
      descriptor = file
      assert_kind_of File, file
      assert file.binmode?
      assert_equal bytes, file.read
      assert_raises(IOError) { file.write("changed") }
      :inspected
    end
    assert_equal :inspected, result
    assert descriptor.closed?
    assert_equal bytes, path.binread
    after = path.stat
    assert_equal [before.dev, before.ino, before.mode, before.size, before.mtime, before.ctime],
      [after.dev, after.ino, after.mode, after.size, after.mtime, after.ctime]
    assert_empty @root.children
  end

  def test_legacy_open_rejects_missing_disabled_and_invalid_locators
    assert_raises(DocumentStorage::MissingFile) do
      @storage.open_legacy("userFiles/absent.pdf") { flunk "missing source yielded" }
    end
    @legacy.join("old.pdf").write("old")
    disabled = DocumentStorage.new(configuration: configuration(legacy_reads_enabled: false))
    assert_raises(DocumentStorage::MissingFile) do
      disabled.open_legacy("userFiles/old.pdf") { flunk "disabled source yielded" }
    end
    [nil, "", "/etc/passwd", "privateDocuments/old.pdf", "other/old.pdf",
     "userFiles/../old.pdf", "userFiles/nested/old.pdf", "userFiles/a\\b.pdf",
     "userFiles/%2e%2e.pdf", "userFiles/a\0.pdf", "userFiles/.hidden",
     "userFiles/" + "a" * 256, "userFiles/é.pdf", "userFiles/\xff.pdf".b.force_encoding("UTF-8")].each do |locator|
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.open_legacy(locator) { flunk "invalid locator yielded" }
      end
    end
  end

  def test_legacy_open_rejects_links_and_nonregular_sources
    target = @sandbox.join("outside.pdf")
    target.write("outside")
    File.symlink(target, @legacy.join("link.pdf"))
    File.symlink(@sandbox.join("absent"), @legacy.join("dangling.pdf"))
    File.link(target, @legacy.join("hard.pdf"))
    @legacy.join("directory").mkdir
    %w[link.pdf dangling.pdf hard.pdf directory].each do |name|
      assert_raises(DocumentStorage::InvalidLocator) do
        @storage.open_legacy("userFiles/#{name}") { flunk "unsafe source yielded" }
      end
    end
    assert_equal "outside", target.read
  end

  def test_legacy_open_rejects_symlinked_root_and_ancestor
    [@legacy, @public].each_with_index do |directory, index|
      moved = @sandbox.join("moved-#{index}")
      directory.rename(moved)
      File.symlink(moved, directory)
      begin
        assert_raises(DocumentStorage::InvalidLocator) do
          @storage.open_legacy("userFiles/old.pdf") { flunk "unsafe root yielded" }
        end
      ensure
        directory.unlink
        moved.rename(directory)
      end
    end
  end

  def test_legacy_open_rejects_replacement_or_symlink_swap_before_open
    path = @legacy.join("old.pdf")
    original_open = File.method(:open)
    [:replacement, :symlink].each do |kind|
      path.write("original")
      replacement = @sandbox.join("replacement-#{kind}")
      replacement.write("replacement")
      File.stub(:open, ->(opened_path, *args, &block) {
        if Pathname(opened_path) == path
          path.rename(@sandbox.join("retained-#{kind}"))
          kind == :symlink ? File.symlink(replacement, path) : replacement.rename(path)
        end
        original_open.call(opened_path, *args, &block)
      }) do
        assert_raises(DocumentStorage::Error) do
          @storage.open_legacy("userFiles/old.pdf") { flunk "replacement yielded" }
        end
      end
      path.unlink
    end
  end

  def test_legacy_open_rejects_changes_during_inspection_and_closes_descriptor
    path = @legacy.join("old.pdf")
    [:replacement, :symlink, :removed, :hard_link, :root_symlink].each do |kind|
      path.write("original")
      descriptor = nil
      assert_raises(DocumentStorage::Error) do
        @storage.open_legacy("userFiles/old.pdf") do |file|
          descriptor = file
          case kind
          when :replacement
            replacement = @sandbox.join("replacement")
            replacement.write("replacement")
            replacement.rename(path)
          when :symlink
            path.unlink
            File.symlink(@sandbox.join("absent"), path)
          when :removed
            path.unlink
          when :hard_link
            File.link(path, @sandbox.join("extra-link"))
          when :root_symlink
            @legacy.rename(@sandbox.join("moved-legacy"))
            File.symlink(@sandbox.join("moved-legacy"), @legacy)
          end
        end
      end
      assert descriptor.closed?
      if kind == :root_symlink
        @legacy.unlink
        @sandbox.join("moved-legacy").rename(@legacy)
      end
      path.unlink if path.exist? || path.symlink?
    end
  end

  {
    system_call_error: Errno::EIO,
    io_error: IOError,
    application_exception: RuntimeError
  }.each do |kind, error_class|
    define_method("test_legacy_open_preserves_caller_#{kind}_and_closes_descriptor") do
      failure = error_class.new("caller failure")
      failure.set_backtrace(["caller.rb:42:in `inspect_document'"])
      original_backtrace = failure.backtrace.dup
      original_message = failure.message
      path = @legacy.join("old.pdf")
      path.write("original")
      descriptor = nil
      error = assert_raises(error_class) do
        @storage.open_legacy("userFiles/old.pdf") do |file|
          descriptor = file
          path.unlink
          raise failure
        end
      end
      assert_same failure, error
      assert_equal original_message, error.message
      assert_equal original_backtrace, error.backtrace
      assert_nil error.cause
      assert descriptor.closed?
    end
  end

  def test_legacy_open_fails_closed_without_nofollow
    @legacy.join("old.pdf").write("original")
    original_defined = File.method(:const_defined?)
    File.stub(:const_defined?, ->(name, *args) { name == :NOFOLLOW ? false : original_defined.call(name, *args) }) do
      assert_raises(DocumentStorage::Unavailable) do
        @storage.open_legacy("userFiles/old.pdf") { flunk "unsupported opening yielded" }
      end
    end
  end

  private

  def configuration(root: @root, legacy_reads_enabled: true)
    DocumentStorageConfiguration.new(root: root, public_root: @public, legacy_reads_enabled: legacy_reads_enabled)
  end
end
