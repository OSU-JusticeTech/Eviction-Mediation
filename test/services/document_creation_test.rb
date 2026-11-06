require "test_helper"
require "tmpdir"
require "minitest/mock"

class DocumentCreationTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("document-creation-")
    @storage = DocumentStorage.new(configuration: DocumentStorageConfiguration.new(
      root: @root, public_root: Rails.root.join("public")
    ))
    @creation = DocumentCreation.new(storage: @storage)
    @file = file_drafts(:one)
    @original_locator = @file.FileURLPath
    @writer = ->(path) { path.write("complete document") }
  end

  teardown do
    FileUtils.remove_entry(@root)
  end

  test "nested success keeps bytes available until the enclosing transaction finishes" do
    locator = nil
    FileDraft.transaction(requires_new: true) do
      result = @creation.call(extension: "txt", writer: @writer) do |published|
        locator = published
        @file.update!(FileURLPath: published)
        :created
      end
      assert_equal :created, result
      assert_equal "complete document", @storage.resolve(locator).read
      assert_equal locator, @file.reload.FileURLPath
    end
    assert_equal "complete document", @storage.resolve(locator).read
    assert_equal locator, @file.reload.FileURLPath
  end

  test "enclosing rollback removes bytes after a successful inner savepoint" do
    FileDraft.transaction(requires_new: true) do
      @creation.call(extension: "txt", writer: @writer) do |locator|
        @file.update!(FileURLPath: locator)
      end
      assert_equal 1, Dir.children(@root).size
      raise ActiveRecord::Rollback
    end
    assert_equal @original_locator, @file.reload.FileURLPath
    assert_empty Dir.children(@root)
  end

  test "enclosing exception removes bytes and preserves the original error" do
    failure = RuntimeError.new("outer transaction failed")
    error = assert_raises(RuntimeError) do
      FileDraft.transaction(requires_new: true) do
        @creation.call(extension: "txt", writer: @writer) do |locator|
          @file.update!(FileURLPath: locator)
        end
        assert_equal 1, Dir.children(@root).size
        raise failure
      end
    end
    assert_same failure, error
    assert_equal @original_locator, @file.reload.FileURLPath
    assert_empty Dir.children(@root)
  end

  test "inner explicit rollback raises failure and cleans up once while outer work commits" do
    assert_inner_failure(ActiveRecord::Rollback)
  end

  test "inner exception raises failure and cleans up once while outer work commits" do
    assert_inner_failure(RuntimeError)
  end

  test "lost commit acknowledgement retains published bytes without rollback evidence" do
    callbacks = Object.new
    callbacks.define_singleton_method(:after_commit) { |&callback| }
    callbacks.define_singleton_method(:after_rollback) { |&callback| }
    records = Object.new
    records.define_singleton_method(:transaction) do |**_options, &block|
      block.call(callbacks)
      # Model a committed transaction whose acknowledgement never reaches Rails.
      raise ActiveRecord::ConnectionNotEstablished, "commit acknowledgement lost"
    end
    locator = nil
    creation = DocumentCreation.new(storage: @storage, records: records)
    @storage.stub(:delete_private, ->(*) { flunk "uncertain outcome must retain bytes" }) do
      assert_raises(DocumentCreation::Failure) do
        creation.call(extension: "txt", writer: @writer) { |published| locator = published }
      end
    end
    assert_equal "complete document", @storage.resolve(locator).read
  end

  test "transaction failure before yielding retains publication for reconciliation" do
    records = Object.new
    records.define_singleton_method(:transaction) do |**_options, &_block|
      raise ActiveRecord::ConnectionNotEstablished, "database unavailable"
    end
    creation = DocumentCreation.new(storage: @storage, records: records)
    assert_raises(DocumentCreation::Failure) do
      creation.call(extension: "txt", writer: @writer) { flunk "transaction must not yield" }
    end
    assert_equal 1, Dir.children(@root).size
    assert_equal "complete document", File.read(File.join(@root, Dir.children(@root).first))
  end

  private

  def assert_inner_failure(error_class)
    deleted = []
    original_delete = @storage.method(:delete_private)
    @storage.stub(:delete_private, ->(locator) {
      deleted << locator
      original_delete.call(locator)
    }) do
      FileDraft.transaction(requires_new: true) do
        assert_raises(DocumentCreation::Failure) do
          @creation.call(extension: "txt", writer: @writer) do |locator|
            @file.update!(FileURLPath: locator)
            raise error_class, "forced rollback"
          end
        end
        assert_equal @original_locator, @file.reload.FileURLPath
        assert_empty Dir.children(@root)
        @file.update!(FileName: "outer work survived")
      end
    end
    assert_equal 1, deleted.size
    assert_equal "outer work survived", @file.reload.FileName
    assert_equal @original_locator, @file.FileURLPath
  end
end
