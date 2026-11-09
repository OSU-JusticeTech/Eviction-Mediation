require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "minitest/mock"

class DocumentRevisionTest < ActiveSupport::TestCase
  setup do
    @sandbox = Pathname(Dir.mktmpdir("document-revision-"))
    @root = @sandbox.join("documents")
    @public = @sandbox.join("public")
    @legacy = @public.join("userFiles")
    FileUtils.mkdir_p([@root, @legacy])
    @storage = build_storage
    @log = StringIO.new
    @revision = DocumentRevision.new(storage: @storage, logger: Logger.new(@log))
    @file = file_drafts(:one)
    @original = @storage.store(io: StringIO.new("original"), extension: "txt")
    @file.update!(FileURLPath: @original)
    @name = @file.FileName
    @writer = ->(bytes, path, _locked) { path.binwrite(bytes + " revised") }
  end

  teardown do
    FileUtils.remove_entry(@sandbox)
  end

  test "private revision publishes immutable private bytes and saves metadata" do
    result = revise { |locked| locked.FileName = "revised name" }
    assert_same @file, result
    refute_equal @original, @file.reload.FileURLPath
    path = @storage.resolve(@file.FileURLPath)
    assert_equal "original revised", path.binread
    assert_equal @root, path.dirname
    assert_equal 0o600, path.stat.mode & 0o777
    assert_equal "revised name", @file.FileName
    assert_original
    assert_empty @legacy.children
  end

  test "legacy input is read and left untouched while replacement is private" do
    source = @legacy.join("old agreement.txt")
    source.binwrite("legacy")
    @file.update!(FileURLPath: "userFiles/old agreement.txt")
    revise
    assert_match(/\AprivateDocuments\//, @file.reload.FileURLPath)
    assert_equal "legacy revised", @storage.resolve(@file.FileURLPath).binread
    assert_equal "legacy", source.binread
    assert_equal [source], @legacy.children
  end

  test "publication failure preserves database and original bytes" do
    File.stub(:link, ->(*) { raise Errno::EACCES }) do
      assert_raises(DocumentRevision::Failure) { revise { |file| file.FileName = "lost" } }
    end
    assert_unchanged
  end

  test "writer failure cleans partial staging without changing the original" do
    failure = RuntimeError.new("writer failed")
    writer = ->(_bytes, path, _file) { path.write("partial"); raise failure }
    error = assert_raises(DocumentRevision::Failure) { @revision.call(file: @file, extension: "txt", writer: writer) }
    assert_instance_of DocumentCreation::Failure, error.cause
    assert_same failure, error.cause.cause
    assert_unchanged
  end

  test "rollback swallowed by the locking transaction raises revision failure" do
    @file.stub(:lock!, ->(*) { raise ActiveRecord::Rollback }) do
      assert_raises(DocumentRevision::Failure) { revise }
    end
    assert_unchanged
  end

  test "unexpected failure before publication preserves its cause" do
    failure = IOError.new("source read failed")
    @storage.stub(:resolve, ->(*) { raise failure }) do
      error = assert_raises(DocumentRevision::Failure) { revise }
      assert_same failure, error.cause
    end
    assert_unchanged
  end

  test "logger failure cannot replace the revision failure or its cause" do
    failure = IOError.new("source read failed")
    logger = Minitest::Mock.new
    logger.expect(:error, nil) { |message| raise "logger failed: #{message}" }
    revision = DocumentRevision.new(storage: @storage, logger: logger)
    @storage.stub(:resolve, ->(*) { raise failure }) do
      error = assert_raises(DocumentRevision::Failure) do
        revision.call(file: @file, extension: "txt", writer: @writer)
      end
      assert_same failure, error.cause
    end
    logger.verify
    assert_unchanged
  end

  test "database save failure cleans only the new publication" do
    @file.stub(:save!, ->(*) { raise ActiveRecord::RecordInvalid.new(@file) }) do
      assert_raises(DocumentRevision::Failure) { revise { |file| file.FileName = "lost" } }
    end
    assert_unchanged
  end

  test "explicit rollback raises failure and cleans once while outer work survives" do
    deleted = []
    delete = @storage.method(:delete_private)
    @storage.stub(:delete_private, ->(locator) { deleted << locator; delete.call(locator) }) do
      FileDraft.transaction(requires_new: true) do
        assert_raises(DocumentRevision::Failure) do
          revise do |file|
            file.update!(FileName: "rolled back")
            raise ActiveRecord::Rollback
          end
        end
        assert_unchanged
        @file.update!(FileName: "outer work")
      end
    end
    assert_equal 1, deleted.size
    refute_includes deleted, @original
    assert_equal "outer work", @file.reload.FileName
  end

  test "enclosing rollback restores locator and metadata and removes replacement" do
    FileDraft.transaction(requires_new: true) do
      revise { |file| file.FileName = "provisional" }
      assert_equal "original revised", @storage.resolve(@file.FileURLPath).binread
      raise ActiveRecord::Rollback
    end
    assert_unchanged
  end

  test "enclosing exception is preserved and removes replacement" do
    failure = RuntimeError.new("outer failed")
    error = assert_raises(RuntimeError) do
      FileDraft.transaction(requires_new: true) do
        revise
        raise failure
      end
    end
    assert_same failure, error
    assert_unchanged
  end

  test "successful enclosing transaction retains both original and replacement" do
    locator = nil
    FileDraft.transaction(requires_new: true) do
      revise
      locator = @file.FileURLPath
    end
    assert_equal locator, @file.reload.FileURLPath
    assert_equal "original revised", @storage.resolve(locator).binread
    assert_original
  end

  test "multiple revisions in an enclosing rollback clean all new publications" do
    FileDraft.transaction(requires_new: true) do
      revise
      revise
      assert_equal "original revised revised", @storage.resolve(@file.FileURLPath).binread
      assert_equal 3, @root.children.size
      raise ActiveRecord::Rollback
    end
    assert_unchanged
  end

  test "stale instances reload latest bytes and metadata under the lock" do
    stale = FileDraft.find(@file.FileID)
    revise { |file| file.FileName = "latest metadata" }
    locked = false
    lock = stale.method(:lock!)
    stale.stub(:lock!, ->(*args) { result = lock.call(*args); locked = true; result }) do
      writer = ->(bytes, path, record) do
        assert locked
        assert_equal "latest metadata", record.FileName
        assert_equal "original revised", bytes
        path.binwrite(bytes + " again")
      end
      @revision.call(file: stale, extension: "txt", writer: writer)
    end
    assert_equal "original revised again", @storage.resolve(stale.reload.FileURLPath).binread
    assert_equal "latest metadata", stale.FileName
    assert_original
  end

  test "dirty caller state cannot bypass the locked reload" do
    @file.FileName = "unsaved stale metadata"
    assert_raises(DocumentRevision::Failure) { revise }
    assert_unchanged
  end

  test "caller can reject a stale domain version using the locked metadata" do
    @file.update!(AgreementVersion: 1)
    stale = FileDraft.find(@file.FileID)
    revise { |file| file.AgreementVersion = 2 }
    latest_locator = @file.FileURLPath
    assert_raises(DocumentRevision::Failure) do
      @revision.call(file: stale, extension: "txt", writer: @writer) do |locked|
        raise "stale agreement version" unless locked.AgreementVersion == 1
      end
    end
    assert_equal latest_locator, stale.reload.FileURLPath
    assert_equal 2, stale.AgreementVersion
    assert_equal "original revised", @storage.resolve(latest_locator).binread
    assert_equal 2, @root.children.size
    assert_original
  end

  test "new records are rejected before any publication" do
    assert_raises(DocumentRevision::Failure) do
      @revision.call(file: FileDraft.new, extension: "txt", writer: @writer)
    end
    assert_unchanged
  end

  test "missing invalid and disabled legacy inputs fail before publication" do
    @legacy.join("old.txt").write("legacy")
    storage = build_storage(legacy_reads_enabled: false)
    revision = DocumentRevision.new(storage: storage, logger: Logger.new(@log))
    ["privateDocuments/missing.txt", "../outside.txt", "userFiles/old.txt"].each do |locator|
      @file.update!(FileURLPath: locator)
      writer = ->(*) { flunk "writer must not run for an unreadable source" }
      assert_raises(DocumentRevision::Failure) { revision.call(file: @file, extension: "txt", writer: writer) }
      assert_equal locator, @file.reload.FileURLPath
      assert_equal [@storage.resolve(@original)], @root.children
    end
    assert_equal "legacy", @legacy.join("old.txt").read
    assert_original
  end

  test "rollback cleanup failure logs replacement locator and preserves original failure" do
    failure = RuntimeError.new("metadata failed")
    @storage.stub(:delete_private, ->(*) { raise DocumentStorage::Unavailable }) do
      error = assert_raises(DocumentRevision::Failure) { revise { raise failure } }
      assert_same failure, error.cause.cause
    end
    assert_equal @original, @file.reload.FileURLPath
    assert_equal 2, @root.children.size
    replacement = @root.children.find { |path| path != @storage.resolve(@original) }
    assert_includes @log.string, "locator=privateDocuments/#{replacement.basename}"
    assert_original
  end

  test "completed publication survives staging cleanup failure without republishing" do
    with_staging_cleanup_failure do
      revise
      assert_equal "original revised", @storage.resolve(@file.reload.FileURLPath).binread
      assert_equal 3, @root.children.size # Original, publication, failed staging cleanup.
      assert_includes @log.string, "staging cleanup failed"
    end
    assert_original
  end

  test "database failure after staging cleanup failure removes completed publication only" do
    with_staging_cleanup_failure do
      assert_raises(DocumentRevision::Failure) { revise { raise "metadata failed" } }
    end
    assert_equal @original, @file.reload.FileURLPath
    assert_equal 2, @root.children.size # Original and the staging orphan.
    assert_equal 1, @root.children.count { |path| path.basename.to_s.start_with?(".document-") }
    assert_original
  end

  private

  def build_storage(legacy_reads_enabled: true)
    DocumentStorage.new(configuration: DocumentStorageConfiguration.new(
      root: @root, public_root: @public, legacy_reads_enabled: legacy_reads_enabled
    ))
  end

  def revise(&block)
    @revision.call(file: @file, extension: "txt", writer: @writer, &block)
  end

  def assert_original
    assert_equal "original", @storage.resolve(@original).binread
  end

  def assert_unchanged
    assert_equal @original, @file.reload.FileURLPath
    assert_equal @name, @file.FileName
    assert_equal [@storage.resolve(@original)], @root.children
    assert_original
  end

  def with_staging_cleanup_failure
    unlink = File.method(:unlink)
    File.stub(:unlink, ->(path) {
      raise Errno::EACCES if File.basename(path).start_with?(".document-")
      unlink.call(path)
    }) { yield }
  end
end
