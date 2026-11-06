require "test_helper"
require "securerandom"
require "timeout"

# Real committed rows are necessary for independent SQL Server connections.
class LegacyDocumentMigrationClaimTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @test_runs = []
    @run = create_test_run
    @attempt = create_test_attempt(@run)
  end

  teardown do
    @test_runs&.reverse_each { |run| cleanup_test_run(run) }
  end

  def create_test_run
    run = LegacyDocumentMigrationRun.create!(run_identifier: SecureRandom.uuid,
      source_environment: "synthetic-claim-test", started_at: Time.utc(2020))
    @test_runs << run
    run
  end

  def create_test_attempt(run)
    # Run IDs make the synthetic reservation distinct across tests and reruns.
    # Use negative synthetic IDs rather than document fixture IDs.
    raise "Synthetic file ID exceeds SQL Server integer range" unless (1..2**31).cover?(run.id)

    LegacyDocumentMigrationAttempt.create!(run: run, file_id: -run.id,
      expected_legacy_locator: "userFiles/Synthetic.pdf", source_identity: "synthetic",
      started_at: Time.utc(2020))
  end

  def cleanup_test_run(run)
    # CollectionProxy#delete_all would NULL the non-null, immutable run_id.
    # Delete only this test's journal rows, never documents or other runs.
    LegacyDocumentMigrationRun.transaction do
      LegacyDocumentMigrationAttempt.where(run_id: run.id).delete_all
      LegacyDocumentMigrationRun.where(id: run.id).delete_all
    end
  end

  def credentials
    @credentials ||= @attempt.claim!(lease_seconds: 300)
  end

  def fenced(state = @attempt.state)
    credentials.merge(expected_state: state)
  end

  test "cleanup deletes owned attempts without nullifying identity or touching other runs" do
    other_run = create_test_run
    other_attempt = create_test_attempt(other_run)
    original_run_id = @attempt.run_id
    credentials

    cleanup_test_run(@run)
    cleanup_test_run(@run) # Teardown must also tolerate already-cleaned rows.

    assert_not LegacyDocumentMigrationAttempt.exists?(@attempt.id)
    assert_not LegacyDocumentMigrationRun.exists?(original_run_id)
    assert_equal other_run.id, other_attempt.reload.run_id
    assert_equal 0, other_attempt.reservation_key
  end

  test "cleanup after an exception removes an active claim and permits an explicit new attempt" do
    run = create_test_run
    attempt = nil
    assert_raises(RuntimeError) do
      begin
        attempt = create_test_attempt(run)
        attempt.claim!
        raise "synthetic worker failure"
      ensure
        cleanup_test_run(run)
      end
    end
    assert_not LegacyDocumentMigrationAttempt.exists?(attempt.id)
    assert_not LegacyDocumentMigrationRun.exists?(run.id)
    replacement = LegacyDocumentMigrationAttempt.create!(run: @run, file_id: attempt.file_id,
      expected_legacy_locator: "userFiles/Synthetic.pdf", source_identity: "synthetic",
      started_at: Time.utc(2020))
    assert_equal 0, replacement.reservation_key
  end

  test "cleanup tolerates setup failure before an attempt exists" do
    run = create_test_run
    assert_raises(ActiveModel::UnknownAttributeError) do
      begin
        LegacyDocumentMigrationAttempt.create!(run: run, file_id: -run.id,
          unexpected_synthetic_attribute: true)
      ensure
        cleanup_test_run(run)
      end
    end
    assert_not LegacyDocumentMigrationRun.exists?(run.id)
    assert_not LegacyDocumentMigrationAttempt.where(run_id: run.id).exists?
  end

  test "claim rejects an enclosing transaction without changing durable ownership" do
    assert_not self.class.use_transactional_tests
    assert_not LegacyDocumentMigrationAttempt.connection.transaction_open?
    LegacyDocumentMigrationAttempt.transaction do
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.claim! }
    end
    assert_nil @attempt.reload.lease_token
    assert_nil @attempt.lease_expires_at
    assert_equal 0, @attempt.lease_generation
    assert_equal 0, @attempt.reservation_key
  end

  test "claim acquisition uses database time and keeps reservation and evidence" do
    before = @attempt.attributes.slice("source_identity", "expected_legacy_locator", "reservation_key")
    now = @attempt.send(:database_utc_now)
    travel_to Time.utc(2040) do
      assert_match(/\A[0-9a-f-]{36}\z/, credentials.fetch(:worker_token))
    end
    assert_equal 1, @attempt.reload.lease_generation
    assert_operator @attempt.lease_expires_at, :>, now
    assert_operator @attempt.lease_expires_at, :<, now + 360
    assert_equal before, @attempt.attributes.slice(*before.keys)
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.claim! }
    assert_raises(ActiveRecord::RecordNotUnique) do
      LegacyDocumentMigrationAttempt.create!(run: @run, file_id: @attempt.file_id,
        expected_legacy_locator: "userFiles/Synthetic.pdf", source_identity: "synthetic", started_at: Time.utc(2020))
    end
  end

  test "renewal and release require exact ownership state and generation" do
    valid = fenced
    expiry = @attempt.lease_expires_at
    [valid.merge(worker_token: SecureRandom.uuid), valid.merge(generation: 0),
     valid.merge(expected_state: "copying")].each do |invalid|
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.renew_claim!(**invalid) }
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.release_claim!(**invalid) }
      assert_equal expiry, @attempt.reload.lease_expires_at
    end
    @attempt.renew_claim!(**valid, lease_seconds: 600)
    assert_operator @attempt.reload.lease_expires_at, :>, expiry
    assert_equal 1, @attempt.lease_generation
    @attempt.release_claim!(**valid)
    assert_nil @attempt.reload.lease_token
    assert_equal 1, @attempt.lease_generation
    assert_equal 0, @attempt.reservation_key
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.claim! }
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.transition_to!("copying", **valid) }
  end

  test "expired claims cannot renew release mutate or be taken over" do
    valid = fenced
    # Synthetic expired database record; application time travel cannot expire SQL time.
    @attempt.update_columns(lease_expires_at: Time.utc(2021))
    [-> { @attempt.claim! }, -> { @attempt.renew_claim!(**valid) },
     -> { @attempt.release_claim!(**valid) },
     -> { @attempt.transition_to!("copying", **valid) }].each do |operation|
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected, &operation)
    end
    assert_equal credentials[:worker_token], @attempt.reload.lease_token
    assert_equal 0, @attempt.reservation_key
    @attempt.reconcile_claim!(**valid)
    assert_equal "blocked", @attempt.reload.state
    assert_nil @attempt.lease_token
    assert_equal 0, @attempt.reservation_key
    assert_equal 2, @attempt.lease_generation
    @attempt.reconcile_claim!(worker_token: nil, generation: 2,
      expected_state: "blocked", next_state: "superseded")
    assert_equal @attempt.id, @attempt.reload.reservation_key
    assert_equal 3, @attempt.lease_generation
  end

  test "failed reconciliation rolls back generation transition lease and reservation" do
    valid = fenced
    fields = %w[lease_generation state lease_token lease_expires_at reservation_key completed_at error_code]
    before = @attempt.reload.attributes.slice(*fields)

    # Fail after each real write, including after a terminal transition releases
    # the reservation. Also rescue inside a committing caller transaction: joined
    # transactions alone would leave the successful writes durable in that case.
    %i[claim_update! transition_to!].each do |operation|
      original = @attempt.method(operation)
      @attempt.define_singleton_method(operation) do |*args, **kwargs|
        original.call(*args, **kwargs)
        raise ActiveRecord::RecordInvalid, self
      end
      begin
        [false, true].each do |enclosing_transaction|
          reconcile = lambda do
            assert_raises(ActiveRecord::RecordInvalid) do
              @attempt.reconcile_claim!(**valid, next_state: "superseded")
            end
          end
          if enclosing_transaction
            LegacyDocumentMigrationAttempt.transaction { reconcile.call }
          else
            reconcile.call
          end
          assert_equal before, @attempt.reload.attributes.slice(*fields),
            "#{operation} failure changed durable reconciliation data"
        end
      ensure
        @attempt.singleton_class.remove_method(operation)
      end
    end
  end

  test "transitions and ordinary writes cannot bypass ownership or clear claims" do
    valid = fenced
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.transition_to!("copying") }
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) do
      @attempt.transition_to!("copying", **valid.merge(generation: 2))
    end
    assert_raises(ActiveRecord::RecordInvalid) { @attempt.update!(lease_token: nil, lease_expires_at: nil) }
    @attempt.reload
    assert_raises(ActiveRecord::RecordInvalid) { @attempt.update!(error_code: "interrupted") }
    @attempt.reload.transition_to!("copying", **valid)
    assert_equal credentials[:worker_token], @attempt.reload.lease_token
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.renew_claim!(**valid) }
    @attempt.transition_to!("gone", **fenced("copying"))
    assert_nil @attempt.reload.lease_token
    assert_equal @attempt.id, @attempt.reservation_key
  end

  test "interrupted run requires explicit reconciliation and preserves claim" do
    valid = fenced
    @run.finish!(status: "interrupted")
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.renew_claim!(**valid) }
    assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) { @attempt.transition_to!("copying", **valid) }
    assert_equal credentials[:worker_token], @attempt.reload.lease_token
    @attempt.reconcile_claim!(**valid)
    assert_equal "blocked", @attempt.reload.state
    assert_equal 0, @attempt.reservation_key
  end

  test "source evidence requires a matching unexpired copying fence" do
    valid = fenced
    @attempt.transition_to!("copying", **valid)
    evidence = { source_device: 1, source_inode: 2, source_size: 12, source_link_count: 1,
      source_mtime_seconds: 1, source_mtime_nanoseconds: 0,
      source_ctime_seconds: 1, source_ctime_nanoseconds: 0 }
    [fenced("planned"), fenced("copying").merge(worker_token: "wrong"),
     fenced("copying").merge(generation: 0)].each do |invalid|
      assert_raises(LegacyDocumentMigrationAttempt::ClaimRejected) do
        @attempt.record_source_evidence!(evidence: evidence, **invalid)
      end
    end
    @attempt.record_source_evidence!(evidence: evidence, **fenced("copying"))
    assert_equal 12, @attempt.reload.source_size
    assert_raises(ActiveRecord::RecordInvalid) do
      @attempt.record_source_evidence!(evidence: evidence.merge(source_size: 99), **fenced("copying"))
    end
  end

  test "concurrent independent connections produce one durable winner" do
    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        begin
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            attempt = LegacyDocumentMigrationAttempt.find(@attempt.id)
            ready << connection.object_id
            start.pop
            results << [:won, attempt.claim!]
          end
        rescue LegacyDocumentMigrationAttempt::ClaimRejected
          results << [:rejected, nil]
        rescue => error
          results << [:error, error]
        end
      end
    end
    outcomes = Timeout.timeout(20) do
      assert_equal 2, 2.times.map { ready.pop }.uniq.size
      2.times { start << true }
      threads.each(&:join)
      2.times.map { results.pop }
    end
    assert_equal [:rejected, :won], outcomes.map(&:first).sort
    winner = outcomes.find { |status, _| status == :won }.last
    assert_equal winner[:worker_token], @attempt.reload.lease_token
    assert_equal 1, @attempt.lease_generation
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end
end
