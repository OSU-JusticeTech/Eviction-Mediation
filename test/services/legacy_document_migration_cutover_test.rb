require "test_helper"
require "tmpdir"
require "minitest/mock"
require "timeout"

# Committed synthetic rows and temporary files only. Run serially in disposable SQL Server.
class LegacyDocumentMigrationCutoverTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  setup do
    @base = Pathname(Dir.mktmpdir("legacy-cutover-test-"))
    @public = @base.join("public")
    @legacy = @public.join("userFiles")
    @private = @base.join("private")
    FileUtils.mkdir_p([@legacy, @private])
    @storage = DocumentStorage.new(configuration: DocumentStorageConfiguration.new(
      root: @private, public_root: @public, legacy_reads_enabled: true))
    @bytes = "synthetic signed bytes\x00\xff".b * 100
    @source = @legacy.join("Synthetic.pdf")
    @source.binwrite(@bytes)
    @file = FileDraft.create!(CreatorID: users(:landlord1).UserID, FileName: "synthetic",
      FileTypes: "pdf", FileURLPath: "userFiles/Synthetic.pdf", TenantSignature: true,
      UserDeletedAt: Time.utc(2020), CreatedAt: Time.utc(2020))
    @original = @file.attributes
    @run = LegacyDocumentMigrationRun.create!(run_identifier: SecureRandom.uuid,
      source_environment: "synthetic-cutover-test", started_at: Time.utc(2020))
    @attempt = LegacyDocumentMigrationAttempt.create!(run: @run, file_id: @file.FileID,
      expected_legacy_locator: @file.FileURLPath, source_identity: "synthetic-frozen-source",
      started_at: Time.utc(2020))
    @credentials = @attempt.claim!
    LegacyDocumentMigrationCopy.new(storage: @storage).call(file_id: @file.FileID,
      attempt_id: @attempt.id, expected_state: "planned", **@credentials)
    @attempt.reload
    @evidence = @attempt.attributes
    @target = @storage.resolve(@attempt.target_locator)
    @service = LegacyDocumentMigrationCutover.new(storage: @storage)
  end

  teardown do
    LegacyDocumentMigrationAttempt.where(run_id: @run.id).delete_all if @run&.persisted?
    LegacyDocumentMigrationRun.where(id: @run.id).delete_all if @run&.persisted?
    FileDraft.unscoped.where(FileID: @file.FileID).delete_all if @file&.persisted?
    FileUtils.remove_entry(@base) if @base&.directory?
  end

  def invoke(**overrides)
    @service.call(**{ file_id: @file.FileID, attempt_id: @attempt.id,
      expected_state: "published_verified", **@credentials }.merge(overrides))
  end

  def assert_unchanged
    assert_equal @original, @file.reload.attributes
    assert_equal @evidence, @attempt.reload.attributes
    assert_equal @bytes, @source.binread
  end

  test "commits only the locator and journal state preserving evidence and files without notifications" do
    assert_no_enqueued_jobs { assert_equal "committed", invoke.state }
    assert_equal @original.merge("FileURLPath" => @attempt.target_locator), @file.reload.attributes
    fields = LegacyDocumentMigrationAttempt::SOURCE_EVIDENCE_FIELDS +
      LegacyDocumentMigrationAttempt::PUBLICATION_FIELDS + LegacyDocumentMigrationAttempt::IDENTITY_FIELDS
    assert_equal @evidence.slice(*fields), @attempt.reload.attributes.slice(*fields)
    assert_equal 0, @attempt.reservation_key
    assert_equal @bytes, @source.binread
    assert_equal @bytes, @target.binread
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
  end

  test "rejects stale tokens generations states and different document IDs" do
    [{ worker_token: "wrong" }, { worker_token: nil }, { generation: 0 },
     { generation: @credentials[:generation] + 1 }, { expected_state: "copying" }].each do |invalid|
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke(**invalid) }
      assert_unchanged
    end
    assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke(file_id: -1) }
    assert_unchanged
  end

  test "rejects expired claims and interrupted runs" do
    # Expire against database UTC while keeping the lease after the 2020 start.
    affected = LegacyDocumentMigrationAttempt.where(id: @attempt.id).update_all(
      "lease_expires_at = DATEADD(second, -60, SYSUTCDATETIME())")
    assert_equal 1, affected, "Expiry injection must change the durable claim"
    @evidence = @attempt.reload.attributes
    assert_operator @attempt.lease_expires_at, :>, @attempt.started_at
    assert_operator @attempt.lease_expires_at, :<, @attempt.send(:database_utc_now)
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
    assert_unchanged
    @run.finish!(status: "interrupted")
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
    assert_unchanged
  end

  test "rejects enclosing transactions" do
    LegacyDocumentMigrationAttempt.transaction do
      assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
    end
    assert_unchanged
  end

  test "missing private file hash mismatch size mismatch and unsafe target never cut over" do
    # Removing a synthetic temporary target simulates loss; production service never deletes.
    @target.delete
    error = assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
    assert_equal "target_missing", error.code
    assert_unchanged
    ["x".b * @bytes.bytesize, @bytes + "extra"].each do |changed|
      @target.binwrite(changed)
      assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
      assert_unchanged
    end
    @target.delete
    File.symlink(@source, @target)
    assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
    assert_unchanged
  end

  test "changed locator including case and trailing spaces is rejected by exact byte comparison" do
    ["userFiles/synthetic.pdf", "userFiles/Synthetic.pdf ", "privateDocuments/new.pdf"].each do |locator|
      @file.update_columns(FileURLPath: locator)
      error = assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
      assert_equal "source_changed", error.code
      assert_equal locator, @file.reload.FileURLPath
      assert_equal @evidence, @attempt.reload.attributes
    end
  end

  test "missing draft is rejected preserving journal and both files" do
    FileDraft.unscoped.where(FileID: @file.FileID).delete_all
    assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
    assert_equal @evidence, @attempt.reload.attributes
    assert_equal @bytes, @source.binread
    assert_equal @bytes, @target.binread
  end

  test "failure after journal write rolls back both writes" do
    original = @attempt.method(:transition_to!)
    @attempt.define_singleton_method(:transition_to!) do |*args, **kwargs|
      original.call(*args, **kwargs)
      raise ActiveRecord::StatementInvalid, "synthetic failure"
    end
    LegacyDocumentMigrationAttempt.stub(:find, @attempt) do
      assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
    end
    assert_unchanged
    assert_equal @bytes, @target.binread
  end

  test "invalid journal source size is rejected without replacing evidence" do
    @attempt.update_columns(source_size: @bytes.bytesize + 1)
    @evidence = @attempt.reload.attributes
    assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
    assert_unchanged
  end

  test "private file changed while hashing is rejected" do
    open_private = @storage.method(:open_private)
    @storage.stub(:open_private, lambda { |locator, &block|
      open_private.call(locator) do |io|
        read = io.method(:read)
        changed = false
        io.define_singleton_method(:read) do |*args|
          bytes = read.call(*args)
          unless changed
            changed = true
            File.open(io.path, "ab") { |writer| writer.write("changed") }
          end
          bytes
        end
        block.call(io)
      end
    }) do
      assert_raises(LegacyDocumentMigrationCutover::Failure) { invoke }
    end
    assert_unchanged
  end

  test "expiry during hashing rolls back locator update" do
    open_private = @storage.method(:open_private)
    @storage.stub(:open_private, lambda { |locator, &block|
      open_private.call(locator, &block)
      LegacyDocumentMigrationAttempt.where(id: @attempt.id).update_all(
        "lease_expires_at = DATEADD(second, -60, SYSUTCDATETIME())")
    }) do
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
    end
    # Expiry injection is in the same transaction and also rolls back.
    assert_unchanged
  end

  test "two independent concurrent cutovers have one winner" do
    ready, start, results = Queue.new, Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ready << connection.object_id
          start.pop
          begin
            invoke
            results << :committed
          rescue LegacyDocumentMigrationAttempt::ClaimRejected
            results << :rejected
          rescue => error
            results << error
          end
        end
      end
    end
    Timeout.timeout(20) do
      assert_equal 2, 2.times.map { ready.pop }.uniq.size
      2.times { start << true }
      threads.each(&:join)
      assert_equal [:committed, :rejected], 2.times.map { results.pop }.sort
    end
    assert_equal "committed", @attempt.reload.state
    assert_equal @attempt.target_locator, @file.reload.FileURLPath
    assert_equal @bytes, @source.binread
    assert_equal @bytes, @target.binread
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end
end
