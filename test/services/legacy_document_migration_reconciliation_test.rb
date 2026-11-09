require "test_helper"
require "tmpdir"
require "minitest/mock"
require "timeout"

# Committed synthetic rows and temporary files only. Run serially in disposable SQL Server.
class LegacyDocumentMigrationReconciliationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  self.use_transactional_tests = false

  setup do
    @base = Pathname(Dir.mktmpdir("legacy-reconciliation-test-"))
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
      source_environment: "synthetic-reconciliation-test", started_at: Time.utc(2020))
    @attempt = LegacyDocumentMigrationAttempt.create!(run: @run, file_id: @file.FileID,
      expected_legacy_locator: @file.FileURLPath, source_identity: "synthetic-frozen-source",
      started_at: Time.utc(2020))
    @credentials = @attempt.claim!
    @service = LegacyDocumentMigrationReconciliation.new(storage: @storage)
  end

  teardown do
    LegacyDocumentMigrationAttempt.where(run_id: @run.id).delete_all if @run&.persisted?
    LegacyDocumentMigrationRun.where(id: @run.id).delete_all if @run&.persisted?
    FileDraft.unscoped.where(FileID: @file.FileID).delete_all if @file&.persisted?
    FileUtils.remove_entry(@base) if @base&.directory?
  end

  def inspect_now
    @service.inspect_attempt(attempt_id: @attempt.id)
  end

  def recover(report = inspect_now, **overrides)
    @service.recover(**{ attempt_id: @attempt.id, inspection_id: report[:inspection_id],
      action: report[:action], approval: ->(context) { context[:workers_stopped] },
      workers_stopped: true, source_frozen: true, authoritative_database: true,
      **@credentials }.merge(overrides))
  end

  def copy
    LegacyDocumentMigrationCopy.new(storage: @storage).call(file_id: @file.FileID,
      attempt_id: @attempt.id, expected_state: "planned", **@credentials)
    @attempt.reload
  end

  def interrupt_at(method, after: false)
    original = @storage.method(method)
    @storage.stub(method, lambda { |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block) if after
      raise Interrupt, "synthetic checkpoint"
    }) { assert_raises(Interrupt) { copy } }
    @attempt.reload
  end

  test "inspection is idempotent and never starts a planned copy" do
    before = @attempt.attributes
    first = inspect_now
    assert_equal "copy_never_started", first[:outcome]
    assert_nil first[:action]
    assert_equal first, inspect_now
    assert_equal before, @attempt.reload.attributes
    assert_equal @original, @file.reload.attributes
    assert_empty @private.children
  end

  test "interruptions before source opening and before staging publication retain evidence" do
    interrupt_at(:open_legacy)
    assert_equal "copy_interrupted_before_publication", inspect_now[:outcome]
    assert_nil inspect_now[:action]
    assert_empty @private.children
  end

  test "interruption after allocation before staging is inspectable without retry" do
    interrupt_at(:publish_private)
    assert_not_nil @attempt.target_locator
    assert_nil @attempt.expected_sha256
    assert_equal "copy_interrupted_before_publication", inspect_now[:outcome]
    assert_nil inspect_now[:action]
  end

  test "interruption after digest recording before publication is not permission to recopy" do
    original = @attempt.method(:record_copy_digest!)
    @attempt.define_singleton_method(:record_copy_digest!) do |**kwargs|
      original.call(**kwargs)
      raise Interrupt, "synthetic digest checkpoint"
    end
    LegacyDocumentMigrationAttempt.stub(:find, @attempt) { assert_raises(Interrupt) { copy } }
    assert_not_nil @attempt.reload.expected_sha256
    assert_equal "copy_interrupted_before_publication", inspect_now[:outcome]
    assert_nil inspect_now[:action]
  end

  test "published unfinalized copy can be approved without copying or changing draft" do
    interrupt_at(:publish_private, after: true)
    report = inspect_now
    assert_equal "published_unfinalized", report[:outcome]
    fields = LegacyDocumentMigrationAttempt::SOURCE_EVIDENCE_FIELDS + LegacyDocumentMigrationAttempt::PUBLICATION_FIELDS
    evidence = @attempt.attributes.slice(*fields)
    @storage.stub(:publish_private, ->(*) { flunk "republication" }) { recover(report) }
    assert_equal "published_verified", @attempt.reload.state
    assert_equal evidence, @attempt.attributes.slice(*fields)
    assert_equal @original, @file.reload.attributes
    assert_equal 1, @private.children.size
    assert_equal @credentials[:generation] + 1, @attempt.lease_generation
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) do
      LegacyDocumentMigrationCutover.new(storage: @storage).call(file_id: @file.FileID,
        attempt_id: @attempt.id, expected_state: "published_verified", **@credentials)
    end
  end

  test "approved cutover and already completed cutover use existing private locator" do
    copy
    assert_equal "private_verified_database_pending", inspect_now[:outcome]
    generation = @attempt.lease_generation
    result = recover
    assert_not LegacyDocumentMigrationAttempt.connection.transaction_open?
    assert_equal "committed", result.state
    assert_equal "committed", @attempt.reload.state
    assert_equal generation + 1, @attempt.lease_generation
    assert_equal @attempt.reload.target_locator, @file.reload.FileURLPath
    @credentials[:generation] = @attempt.lease_generation
    report = inspect_now
    assert_equal "database_cutover_completed", report[:outcome]
    # Verifying a committed mapping must not perform another draft write.
    # Keep unscoped's block return intact: reload needs a record, not a relation.
    draft_updates = []
    capture_draft_updates = lambda do |*event|
      sql = event.last[:sql]
      draft_updates << sql if sql.match?(/\bUPDATE\b/i) && sql.match?(/\bFileDrafts\b/i)
    end
    ActiveSupport::Notifications.subscribed(capture_draft_updates, "sql.active_record") do
      result = recover(report)
    end
    assert_empty draft_updates
    assert_not LegacyDocumentMigrationAttempt.connection.transaction_open?
    assert_equal "verified", result.state
    assert_equal "verified", @attempt.reload.state
    assert_equal generation + 2, @attempt.lease_generation
    assert_nil inspect_now[:action]
    assert_equal @original.merge("FileURLPath" => @attempt.target_locator), @file.reload.attributes
    assert_equal 1, @private.children.size
  end

  test "worker credentials alone and missing attestations never authorize recovery" do
    copy
    before = @attempt.reload.attributes
    [ { approval: nil }, { approval: ->(_) { false } }, { workers_stopped: false },
      { source_frozen: false }, { authoritative_database: false },
      { worker_token: "wrong" }, { generation: 0 } ].each do |invalid|
      assert_raises(LegacyDocumentMigrationReconciliation::Failure,
        LegacyDocumentMigrationAttempt::ClaimRejected) { recover(**invalid) }
      assert_equal before, @attempt.reload.attributes
      assert_equal @original, @file.reload.attributes
    end
  end

  test "stale inspection and expired claims fail closed" do
    copy
    report = inspect_now
    @attempt.renew_claim!(**@credentials, expected_state: "published_verified", lease_seconds: 3600)
    assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover(report) }
    LegacyDocumentMigrationAttempt.where(id: @attempt.id).update_all(
      "lease_expires_at = DATEADD(second, -60, SYSUTCDATETIME())")
    assert_equal "expired", inspect_now[:lease]
    assert_equal "cutover", inspect_now[:action]
    assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover }
    assert_equal @original, @file.reload.attributes
  end

  test "expiry during approval rolls back the guarded locator update" do
    copy
    before = @attempt.attributes
    policy = lambda do |_context|
      LegacyDocumentMigrationAttempt.where(id: @attempt.id).update_all(
        "lease_expires_at = DATEADD(second, -60, SYSUTCDATETIME())")
      true
    end
    assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover(approval: policy) }
    assert_equal before, @attempt.reload.attributes
    assert_equal @original, @file.reload.attributes
  end

  test "enclosing transactions and swallowed rollback never report success" do
    copy
    before = @attempt.attributes
    report = inspect_now
    LegacyDocumentMigrationAttempt.transaction do
      assert_raises(LegacyDocumentMigrationReconciliation::Failure) { inspect_now }
      assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover(report) }
      assert_equal before, @attempt.reload.attributes
      assert_equal @original, @file.reload.attributes
    end
    @attempt.define_singleton_method(:fence_reconciled_worker!) { raise ActiveRecord::Rollback }
    LegacyDocumentMigrationAttempt.stub(:find, @attempt) do
      assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover }
    end
    assert_equal "published_verified", @attempt.reload.state
    assert_equal before, @attempt.attributes
    assert_equal @original, @file.reload.attributes
    assert_equal report, inspect_now
  end

  test "exceptions after the locator update roll back before the journal transition" do
    copy
    before = @attempt.attributes
    report = inspect_now
    [RuntimeError, ActiveRecord::Rollback].each do |error_class|
      @attempt.define_singleton_method(:transition_to!) do |*args, **kwargs|
        raise error_class, "synthetic failure after locator update"
      end
      LegacyDocumentMigrationAttempt.stub(:find, @attempt) do
        expected = error_class == ActiveRecord::Rollback ? LegacyDocumentMigrationReconciliation::Failure : error_class
        assert_raises(expected) { recover(report) }
      end
      assert_equal before, @attempt.reload.attributes
      assert_equal @original, @file.reload.attributes
      assert_equal report, inspect_now
    end
  end

  test "rollback swallowed inside a transition never commits the locator" do
    copy
    before = @attempt.attributes
    report = inspect_now
    @attempt.define_singleton_method(:transition_to!) do |*args, **kwargs|
      self.class.transaction { raise ActiveRecord::Rollback }
    end
    LegacyDocumentMigrationAttempt.stub(:find, @attempt) do
      assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover(report) }
    end
    assert_equal before, @attempt.reload.attributes
    assert_equal @original, @file.reload.attributes
    assert_equal report, inspect_now
  end

  test "filesystem mismatch missing source and conflicting references have no recovery action" do
    copy
    target = @storage.resolve(@attempt.target_locator)
    target.binwrite("wrong")
    assert_equal "ambiguous", inspect_now[:outcome]
    assert_nil inspect_now[:action]
    target.binwrite(@bytes)
    @source.binwrite("changed")
    assert_equal "source_changed_or_disappeared", inspect_now[:outcome]
    @source.delete
    assert_equal "source_changed_or_disappeared", inspect_now[:outcome]
  end

  test "a second draft referencing the target blocks reconciliation" do
    copy
    other = FileDraft.create!(CreatorID: users(:landlord1).UserID, FileName: "synthetic",
      FileTypes: "pdf", FileURLPath: @attempt.target_locator)
    assert_equal "ambiguous", inspect_now[:outcome]
    assert_nil inspect_now[:action]
  ensure
    FileDraft.unscoped.where(FileID: other.FileID).delete_all if other
  end

  test "changed draft missing draft and inconsistent private mapping are never updated" do
    copy
    @file.update_columns(FileURLPath: "userFiles/changed.pdf")
    assert_equal "source_changed_or_disappeared", inspect_now[:outcome]
    @file.update_columns(FileURLPath: @attempt.target_locator)
    assert_equal "ambiguous", inspect_now[:outcome]
    FileDraft.unscoped.where(FileID: @file.FileID).delete_all
    assert_equal "source_changed_or_disappeared", inspect_now[:outcome]
  end

  test "failure after both database writes rolls back locator journal and generation" do
    copy
    before = @attempt.attributes
    original = @attempt.method(:fence_reconciled_worker!)
    @attempt.define_singleton_method(:fence_reconciled_worker!) do
      original.call
      raise ActiveRecord::StatementInvalid, "synthetic uncertain failure"
    end
    LegacyDocumentMigrationAttempt.stub(:find, @attempt) do
      assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover }
    end
    assert_equal before, @attempt.reload.attributes
    assert_equal @original, @file.reload.attributes
    assert_equal "private_verified_database_pending", inspect_now[:outcome]
    assert_equal 1, @private.children.size
  end

  def expire_claim
    LegacyDocumentMigrationAttempt.where(id: @attempt.id).update_all(
      "lease_expires_at = DATEADD(second, -60, SYSUTCDATETIME())")
    @attempt.reload
  end

  def recover_expired(report = inspect_now, **overrides)
    @service.recover_expired_claim(**{ attempt_id: @attempt.id,
      inspection_id: report[:inspection_id], action: report[:action],
      approval: ->(context) { context[:workers_stopped] && context[:recovery_path] == "expired_claim" },
      workers_stopped: true, source_frozen: true, authoritative_database: true }.merge(overrides))
  end

  test "approved expired claim fences before cutover and rejects the stale worker" do
    copy
    expire_claim
    generation = @attempt.lease_generation
    report = inspect_now
    result = recover_expired(report)
    assert_not LegacyDocumentMigrationAttempt.connection.transaction_open?
    assert_equal "committed", result.state
    assert_equal generation + 1, @attempt.reload.lease_generation
    assert_equal @attempt.target_locator, @file.reload.FileURLPath
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) do
      @attempt.renew_claim!(**@credentials, expected_state: "committed")
    end
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.claim! }
    recover_expired
    assert_equal "verified", @attempt.reload.state
  end

  test "expired publication finalization retains bytes and requires a new decision" do
    interrupt_at(:publish_private, after: true)
    expire_claim
    report = inspect_now
    @storage.stub(:publish_private, ->(*) { flunk "republication" }) { recover_expired(report) }
    assert_equal "published_verified", @attempt.reload.state
    assert_equal @original, @file.reload.attributes
    assert_equal @bytes, @storage.resolve(@attempt.target_locator).binread
    assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover_expired(report) }
  end

  test "expired claims require operator approval and every attestation" do
    copy
    expire_claim
    before = @attempt.attributes
    [{ approval: nil }, { approval: ->(_) { false } }, { workers_stopped: false },
      { source_frozen: false }, { authoritative_database: false }].each do |invalid|
      assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover_expired(**invalid) }
      assert_equal before, @attempt.reload.attributes
      assert_equal @original, @file.reload.attributes
    end
  end

  test "expired recovery rolls back generation locator and journal even for swallowed rollback" do
    copy
    expire_claim
    before = @attempt.attributes
    report = inspect_now
    [false, true].each do |swallow|
      @attempt.define_singleton_method(:transition_to!) do |*args, **kwargs|
        raise "generation was not fenced first" unless lease_generation == before["lease_generation"] + 1
        if swallow
          self.class.transaction { raise ActiveRecord::Rollback }
        else
          raise ActiveRecord::Rollback
        end
      end
      LegacyDocumentMigrationAttempt.stub(:find, @attempt) do
        assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover_expired(report) }
      end
      assert_equal before, @attempt.reload.attributes
      assert_equal @original, @file.reload.attributes
    end
  end

  test "expired recovery rejects changed evidence and stale inspection IDs" do
    copy
    live_report = inspect_now
    expire_claim
    assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover_expired(live_report) }
    report = inspect_now
    before = @attempt.attributes
    policy = ->(_) { @storage.resolve(@attempt.target_locator).binwrite("conflict"); true }
    assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover_expired(report, approval: policy) }
    assert_equal before, @attempt.reload.attributes
    assert_equal @original, @file.reload.attributes
    assert_raises(LegacyDocumentMigrationReconciliation::Failure) { recover_expired(report) }
  end

  test "two independent recoveries serialize and only one accepts the inspected decision" do
    copy
    report = inspect_now
    ready, start, results = Queue.new, Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ready << connection.object_id
          start.pop
          begin
            recover(report)
            results << :committed
          rescue LegacyDocumentMigrationReconciliation::Failure
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
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end
  test "two expired claim recoveries serialize and only one accepts the inspected decision" do
    copy
    expire_claim
    report = inspect_now
    ready, start, results = Queue.new, Queue.new, Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do |connection|
          ready << connection.object_id
          start.pop
          begin
            recover_expired(report)
            results << :committed
          rescue LegacyDocumentMigrationReconciliation::Failure
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
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end
end
