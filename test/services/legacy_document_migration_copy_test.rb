require "test_helper"
require "tmpdir"
require "minitest/mock"

# Committed synthetic rows exercise the actual journal fencing/transaction APIs.
# Run serially in a disposable SQL Server test database.
class LegacyDocumentMigrationCopyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @base = Pathname(Dir.mktmpdir("legacy-copy-test-"))
    @public = @base.join("public")
    @legacy = @public.join("userFiles")
    @private = @base.join("private")
    FileUtils.mkdir_p([@legacy, @private])
    @storage = DocumentStorage.new(configuration: DocumentStorageConfiguration.new(
      root: @private, public_root: @public, legacy_reads_enabled: true))
    @source = @legacy.join("Synthetic.PDF")
    @bytes = ("synthetic signed bytes\x00\xff".b * 60_000)
    @source.binwrite(@bytes)
    @file = FileDraft.create!(CreatorID: users(:landlord1).UserID, FileName: "synthetic",
      FileTypes: "pdf", FileURLPath: "userFiles/Synthetic.PDF", TenantSignature: true,
      UserDeletedAt: Time.utc(2020), CreatedAt: Time.utc(2020))
    @original = @file.attributes
    @run = LegacyDocumentMigrationRun.create!(run_identifier: SecureRandom.uuid,
      source_environment: "synthetic-copy-test", started_at: Time.utc(2020))
    @attempt = LegacyDocumentMigrationAttempt.create!(run: @run, file_id: @file.FileID,
      expected_legacy_locator: @file.FileURLPath, source_identity: "synthetic-frozen-source",
      started_at: Time.utc(2020))
    @credentials = @attempt.claim!
    @service = LegacyDocumentMigrationCopy.new(storage: @storage)
  end

  teardown do
    LegacyDocumentMigrationAttempt.where(run_id: @run.id).delete_all if @run&.persisted?
    LegacyDocumentMigrationRun.where(id: @run.id).delete_all if @run&.persisted?
    FileDraft.unscoped.where(FileID: @file.FileID).delete_all if @file&.persisted?
    FileUtils.remove_entry(@base) if @base&.directory?
  end

  def invoke(**overrides)
    @service.call(**{ file_id: @file.FileID, attempt_id: @attempt.id,
      expected_state: "planned", **@credentials }.merge(overrides))
  end

  def assert_unverified
    assert_equal "copying", @attempt.reload.state
    assert_equal 0, @attempt.reservation_key
    assert_equal @original, @file.reload.attributes
  end

  def expire_claim_in_database!
    # The worker loaded a different instance and has advanced lock_version.
    # update_columns on the setup instance can silently affect zero rows. This
    # test-only mutation targets the synthetic row and uses SQL Server UTC time.
    affected = LegacyDocumentMigrationAttempt.where(id: @attempt.id).update_all(
      "lease_expires_at = DATEADD(second, -60, SYSUTCDATETIME())")
    assert_equal 1, affected, "Expiry injection must change the durable claim"
    durable = LegacyDocumentMigrationAttempt.find(@attempt.id)
    assert_operator durable.lease_expires_at, :<, durable.send(:database_utc_now)
    assert_equal @credentials.fetch(:worker_token), durable.lease_token
    assert_equal @credentials.fetch(:generation), durable.lease_generation
    durable
  end

  def assert_retained_copy_evidence(digest:)
    assert_unverified
    assert_not_nil @attempt.target_locator
    assert LegacyDocumentMigrationAttempt::SOURCE_EVIDENCE_FIELDS.all? { |field| !@attempt[field].nil? }
    assert_equal @bytes.bytesize, @attempt.source_size
    assert_equal @credentials.fetch(:worker_token), @attempt.lease_token
    assert_equal @credentials.fetch(:generation), @attempt.lease_generation
    assert_nil @attempt.completed_at
    assert_equal @bytes, @source.binread
    if digest
      assert_equal @bytes.bytesize, @attempt.expected_size
      assert_equal Digest::SHA256.hexdigest(@bytes), @attempt.expected_sha256
    else
      assert_nil @attempt.expected_size
      assert_nil @attempt.expected_sha256
    end
  end

  test "copies binary bytes preserving source and every draft attribute" do
    before = @source.stat
    result = invoke
    assert_equal "published_verified", result.state
    assert_equal @original, @file.reload.attributes
    assert_equal @bytes, @source.binread
    assert_equal @bytes, @storage.resolve(result.target_locator).binread
    assert_equal @bytes.bytesize, result.expected_size
    assert_equal Digest::SHA256.hexdigest(@bytes), result.expected_sha256
    assert_equal before.dev, result.source_device
    assert_equal before.ino, result.source_inode
    assert_equal before.size, result.source_size
    assert_equal 1, result.source_link_count
    assert_equal before.mtime.to_i, result.source_mtime_seconds
    assert_equal before.mtime.nsec, result.source_mtime_nanoseconds
    assert_equal before.ctime.to_i, result.source_ctime_seconds
    assert_equal before.ctime.nsec, result.source_ctime_nanoseconds
    after = @source.stat
    assert_equal [before.ino, before.size, before.mode, before.mtime, before.ctime],
      [after.ino, after.size, after.mode, after.mtime, after.ctime]
    assert_match(/\.pdf\z/, result.target_locator)
    assert_equal 0o600, @storage.resolve(result.target_locator).stat.mode & 0o7777
    assert_equal 1, @private.children.size
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
  end

  test "rejects wrong token generation state file and enclosing transaction before source access" do
    @storage.stub(:open_legacy, ->(*) { flunk "source opened" }) do
      [{worker_token: "wrong"}, {generation: 0}, {generation: "1"},
       {expected_state: "copying"}, {file_id: @file.FileID + 100_000}].each do |invalid|
        assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected, LegacyDocumentMigrationCopy::Failure) { invoke(**invalid) }
        assert_equal "planned", @attempt.reload.state
      end
      LegacyDocumentMigrationAttempt.transaction do
        assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
      end
    end
    assert_empty @private.children
  end

  test "never claimed attempt cannot use journal compatibility as worker authority" do
    other = LegacyDocumentMigrationAttempt.create!(run: @run, file_id: -@run.id,
      expected_legacy_locator: "userFiles/Synthetic.PDF", source_identity: "synthetic", started_at: Time.utc(2020))
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) do
      invoke(attempt_id: other.id, file_id: other.file_id, worker_token: nil, generation: 0)
    end
    assert_equal "planned", other.reload.state
  end

  test "expired claim rejects before copying" do
    expire_claim_in_database!
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
    assert_equal "planned", @attempt.reload.state
    assert_empty @private.children
  end

  test "exact locator comparison rejects case and trailing-space differences" do
    ["userFiles/synthetic.PDF", "userFiles/Synthetic.PDF ", "privateDocuments/other.pdf"].each do |locator|
      @file.update_columns(FileURLPath: locator)
      assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
      assert_equal "planned", @attempt.reload.state
      assert_empty @private.children
    end
  end

  test "missing source never publishes" do
    @source.unlink
    assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    assert_unverified
    assert_nil @attempt.target_locator
    assert_empty @private.children
  end

  test "zero byte source is blocked without allocating a target" do
    @source.binwrite("")
    error = assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    assert_equal "source_unsafe", error.code
    assert_unverified
    assert_nil @attempt.target_locator
    assert_empty @private.children
  end

  test "multiply linked source is rejected without copying" do
    File.link(@source, @legacy.join("extra.pdf"))
    assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    assert_unverified
    assert_nil @attempt.source_inode
    assert_empty @private.children
    assert_equal @bytes, @source.binread
  end

  test "unsupported extension cannot allocate or publish" do
    @source.rename(@legacy.join("Synthetic"))
    @file.update_columns(FileURLPath: "userFiles/Synthetic")
    @original = @file.attributes
    # A distinct planned journal accurately identifies this synthetic source.
    @attempt.reconcile_claim!(**@credentials, expected_state: "planned", next_state: "superseded")
    @attempt = LegacyDocumentMigrationAttempt.create!(run: @run, file_id: @file.FileID,
      expected_legacy_locator: @file.FileURLPath, source_identity: "synthetic", started_at: Time.utc(2020))
    @credentials = @attempt.claim!
    assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    assert_unverified
    assert_not_nil @attempt.source_inode
    assert_nil @attempt.target_locator
    assert_empty @private.children
  end

  test "interrupted run forbids work despite otherwise valid credentials" do
    @run.finish!(status: "interrupted")
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
    assert_equal "planned", @attempt.reload.state
    assert_empty @private.children
  end

  test "target recording requires live fencing and preserves immutable evidence" do
    invoke
    evidence = @attempt.reload.attributes.slice("target_locator", "expected_size", "expected_sha256")
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) do
      @attempt.record_copy_target!(locator: "privateDocuments/other.pdf",
        **@credentials, expected_state: "copying")
    end
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) do
      @attempt.record_copy_digest!(size: 1, sha256: "a" * 64,
        **@credentials, expected_state: "published_verified")
    end
    assert_equal evidence, @attempt.reload.attributes.slice(*evidence.keys)
  end

  test "source evidence and target are durable before any publication bytes" do
    @storage.stub(:publish_private, ->(locator:, &_) {
      durable = LegacyDocumentMigrationAttempt.find(@attempt.id)
      assert_equal "copying", durable.state
      assert_equal @bytes.bytesize, durable.source_size
      assert_equal locator, durable.target_locator
      assert_nil durable.expected_sha256
      raise IOError, "synthetic sensitive path"
    }) do
      error = assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
      assert_nil error.cause
      refute_match(/sensitive/, error.message)
    end
    assert_unverified
    assert_empty @private.children
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
  end

  test "source modification during streaming stops before publication" do
    original = @storage.method(:publish_private)
    @storage.stub(:publish_private, ->(locator:, &writer) {
      original.call(locator: locator) do |path|
        @source.binwrite("changed")
        writer.call(path)
      end
    }) do
      error = assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
      assert_equal "source_changed", error.code
    end
    assert_unverified
    assert_empty @private.children
  end

  test "replacement after copying fails legacy pathname checks and retains published evidence" do
    original = @storage.method(:open_private)
    @storage.stub(:open_private, ->(locator, &reader) {
      result = original.call(locator, &reader)
      replacement = @legacy.join("replacement")
      replacement.binwrite(@bytes)
      replacement.rename(@source)
      result
    }) do
      assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    end
    assert_unverified
    assert_equal Digest::SHA256.hexdigest(@bytes), @attempt.expected_sha256
    assert @storage.resolve(@attempt.target_locator).file?
  end

  test "claim expiry during staging stops publication and retains source evidence" do
    original = @storage.method(:publish_private)
    @storage.stub(:publish_private, ->(locator:, &writer) {
      original.call(locator: locator) do |path|
        durable = LegacyDocumentMigrationAttempt.find(@attempt.id)
        assert_equal "copying", durable.state
        assert_operator durable.lock_version, :>, @attempt.lock_version
        assert path.file?
        refute @private.join(File.basename(locator)).exist?
        expire_claim_in_database!
        writer.call(path)
      end
    }) do
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
    end
    assert_retained_copy_evidence(digest: false)
    assert_empty @private.children
  end

  test "locator change during staging prevents publication" do
    original = @storage.method(:publish_private)
    @storage.stub(:publish_private, ->(locator:, &writer) {
      original.call(locator: locator) do |path|
        @file.update_columns(FileURLPath: "userFiles/new.pdf")
        writer.call(path)
      end
    }) do
      assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    end
    assert_equal "copying", @attempt.reload.state
    assert_equal "userFiles/new.pdf", @file.reload.FileURLPath
    assert_empty @private.children
  end

  test "corrupt completed target never becomes verified and is retained" do
    original = @storage.method(:publish_private)
    @storage.stub(:publish_private, ->(locator:, &writer) {
      result = original.call(locator: locator, &writer)
      @storage.resolve(locator).binwrite("corrupt")
      result
    }) do
      assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    end
    assert_unverified
    assert_equal "corrupt", @storage.resolve(@attempt.target_locator).binread
  end

  test "expiry after publication prevents verified transition and retains target" do
    original = @storage.method(:publish_private)
    @storage.stub(:publish_private, ->(locator:, &writer) {
      result = original.call(locator: locator, &writer)
      assert_equal @bytes, @storage.resolve(locator).binread
      assert_equal "copying", LegacyDocumentMigrationAttempt.find(@attempt.id).state
      expire_claim_in_database!
      result
    }) do
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
    end
    assert_retained_copy_evidence(digest: true)
    assert_equal @bytes, @storage.resolve(@attempt.target_locator).binread
  end

  test "expiry immediately before verified transition uses database UTC despite application clock skew" do
    original = @storage.method(:open_legacy)
    @storage.stub(:open_legacy, ->(locator, &reader) {
      result = original.call(locator, &reader)
      # All copy/read/path checks finished; the next operation is the final
      # claim checkpoint and published_verified transition.
      durable = expire_claim_in_database!
      assert_equal "copying", durable.state
      assert_equal @bytes, @storage.resolve(durable.target_locator).binread
      result
    }) do
      travel_to Time.utc(2000) do
        assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
      end
    end
    assert_retained_copy_evidence(digest: true)
    assert_equal @bytes, @storage.resolve(@attempt.target_locator).binread
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) do
      @attempt.transition_to!("published_verified", **@credentials, expected_state: "copying")
    end
    assert_retained_copy_evidence(digest: true)
  end

  test "live database claim permits copying despite application clock ahead of expiry" do
    travel_to Time.utc(2040) do
      assert_equal "published_verified", invoke.state
    end
    assert_equal @bytes, @storage.resolve(@attempt.reload.target_locator).binread
    assert_equal @original, @file.reload.attributes
  end

  test "locator change after publication prevents verified transition" do
    original = @storage.method(:publish_private)
    @storage.stub(:publish_private, ->(locator:, &writer) {
      result = original.call(locator: locator, &writer)
      @file.update_columns(FileURLPath: "userFiles/new.pdf")
      result
    }) do
      assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    end
    assert_equal "copying", @attempt.reload.state
    assert_equal "userFiles/new.pdf", @file.reload.FileURLPath
    assert_equal @bytes, @storage.resolve(@attempt.target_locator).binread
  end

  test "interruption immediately after publication preserves attributable copy without retry" do
    original = @storage.method(:publish_private)
    @storage.stub(:publish_private, ->(locator:, &writer) {
      original.call(locator: locator, &writer)
      raise Interrupt, "synthetic process interruption"
    }) do
      assert_raises(Interrupt) { invoke }
    end
    assert_unverified
    assert_equal @bytes, @storage.resolve(@attempt.target_locator).binread
    assert_equal Digest::SHA256.hexdigest(@bytes), @attempt.expected_sha256
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { invoke }
    assert_equal 1, @private.children.size
  end

  test "cleanup failure retains target and never attests or republishes" do
    original = @storage.method(:publish_private)
    @storage.stub(:publish_private, ->(locator:, &writer) {
      original.call(locator: locator, &writer)
      raise DocumentStorage::CleanupFailure.new(locator: locator)
    }) do
      assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
    end
    assert_unverified
    assert_equal @bytes, @storage.resolve(@attempt.target_locator).binread
  end

  test "failed final journal write preserves copying state and published bytes" do
    @attempt.class.stub(:find, @attempt) do
      original = @attempt.method(:transition_to!)
      @attempt.stub(:transition_to!, ->(state, **options) {
        raise ActiveRecord::StatementInvalid, "synthetic database failure" if state == "published_verified"
        original.call(state, **options)
      }) do
        assert_raises(LegacyDocumentMigrationCopy::Failure) { invoke }
      end
    end
    assert_unverified
    assert_equal @bytes, @storage.resolve(@attempt.target_locator).binread
  end
end
