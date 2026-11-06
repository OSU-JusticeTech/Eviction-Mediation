require "test_helper"
require "securerandom"

class LegacyDocumentMigrationJournalTest < ActiveSupport::TestCase
  def create_run
    LegacyDocumentMigrationRun.create!(run_identifier: SecureRandom.uuid,
      source_environment: "synthetic-test", started_at: Time.current)
  end

  def create_attempt(run: create_run, file_id: 2147483000)
    LegacyDocumentMigrationAttempt.create!(run: run, file_id: file_id,
      expected_legacy_locator: "userFiles/Synthetic Case.PDF",
      source_identity: "synthetic-source-a", started_at: Time.current)
  end

  def publication
    { target_locator: "privateDocuments/synthetic.pdf", expected_size: 12,
      expected_sha256: "a" * 64 }
  end

  def source_evidence
    { source_device: 18_446_744_073_709_551_615, source_inode: 9_223_372_036_854_775_808,
      source_size: 12, source_link_count: 1,
      source_mtime_seconds: -1, source_mtime_nanoseconds: 123_456_789,
      source_ctime_seconds: 1_794_000_000, source_ctime_nanoseconds: 987_654_321 }
  end

  test "records complete exact evidence while copying before publication" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    attempt.record_source_evidence!(evidence: source_evidence)
    attempt.reload
    source_evidence.each { |field, value| assert_equal value, attempt[field] }
    assert_equal "copying", attempt.state
    assert_equal 0, attempt.reservation_key
    assert_equal "synthetic-source-a", attempt.source_identity
    assert_nil attempt.target_locator
    attempt.update!(publication)
    attempt.reload.transition_to!("published_verified")
    assert_equal "published_verified", attempt.reload.state
    assert_raises(ActiveRecord::RecordNotUnique) { create_attempt }
  end

  test "source evidence requires every field and an existing copying state" do
    attempt = create_attempt
    assert_raises(ActiveRecord::RecordInvalid) do
      LegacyDocumentMigrationAttempt.create!(run: attempt.run, file_id: 2147482999,
        expected_legacy_locator: "userFiles/Other.pdf", source_identity: "synthetic-source-a",
        started_at: Time.current, **source_evidence)
    end
    assert_raises(ActiveRecord::RecordInvalid) { attempt.record_source_evidence!(evidence: source_evidence) }
    attempt.reload
    assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(source_evidence) }
    attempt.reload
    assert_raises(ArgumentError) { attempt.transition_to!("copying", evidence: source_evidence) }
    assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(source_evidence.merge(state: "copying")) }
    attempt.reload
    attempt.transition_to!("copying")
    source_evidence.each_key do |field|
      partial = source_evidence.except(field)
      assert_raises(ArgumentError) { attempt.record_source_evidence!(evidence: partial) }
      assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(partial) }
      attempt.reload
    end
    attempt.transition_to!("blocked")
    assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(source_evidence) }
  end

  test "source evidence cannot be replaced or cleared in any later state" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    attempt.record_source_evidence!(evidence: source_evidence)
    assert_raises(ActiveRecord::RecordInvalid) { attempt.record_source_evidence!(evidence: source_evidence) }
    %w[copying published_verified committed verified rolled_back].each do |state|
      attempt.transition_to!(state, evidence: state == "published_verified" ? publication : {}) unless attempt.state == state
      source_evidence.each do |field, value|
        [nil, value + 1].each do |replacement|
          assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(field => replacement) }
          attempt.reload
          assert_equal value, attempt[field]
        end
      end
      assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(source_evidence.transform_values { nil }) }
      attempt.reload
    end
  end

  test "source evidence rejects invalid or lossy input before type casting" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    source_evidence.each_key do |field|
      ["invalid", "1.5", 1.5, 1.0, 2**65].each do |value|
        assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(source_evidence.merge(field => value)) }
        attempt.reload
      end
    end
    { source_device: -1, source_inode: -1, source_size: -1, source_link_count: 0,
      source_mtime_seconds: -(2**63) - 1, source_ctime_seconds: -(2**63) - 1,
      source_mtime_nanoseconds: -1, source_ctime_nanoseconds: 1_000_000_000 }.each do |field, value|
      assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(source_evidence.merge(field => value)) }
      attempt.reload
    end
  end

  test "publication requires source evidence already persisted while copying" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    assert_raises(ActiveRecord::RecordInvalid) { attempt.transition_to!("published_verified", evidence: publication) }
    assert_equal "copying", attempt.reload.state
    assert_equal 0, attempt.reservation_key
    assert_nil attempt.target_locator
    attempt.record_source_evidence!(evidence: source_evidence)
    attempt.transition_to!("published_verified", evidence: publication)
  end

  test "database checks reject partial invalid and absent successful source evidence" do
    attempt = create_attempt
    # A complete bundle is also forbidden in planned, even bypassing validations.
    assert_raises(ActiveRecord::StatementInvalid) { attempt.update_columns(source_evidence) }
    attempt.reload.transition_to!("copying")
    source_evidence.each_key do |field|
      assert_raises(ActiveRecord::StatementInvalid) { attempt.update_columns(source_evidence.except(field)) }
      attempt.reload
    end
    { source_device: -1, source_inode: 2**64, source_size: -1, source_link_count: 0,
      source_mtime_nanoseconds: -1, source_ctime_nanoseconds: 1_000_000_000 }.each do |field, value|
      assert_raises(ActiveRecord::StatementInvalid) { attempt.update_columns(source_evidence.merge(field => value)) }
      attempt.reload
    end
    %w[published_verified committed verified].each do |state|
      closure = state == "verified" ? { reservation_key: attempt.id, completed_at: Time.current } : {}
      assert_raises(ActiveRecord::StatementInvalid) { attempt.update_columns(publication.merge(state: state).merge(closure)) }
      attempt.reload
    end
  end

  test "legacy attempts without evidence retain closure and reservation behavior" do
    attempt = create_attempt
    assert LegacyDocumentMigrationAttempt::SOURCE_EVIDENCE_FIELDS.all? { |field| attempt[field].nil? }
    attempt.transition_to!("copying")
    attempt.transition_to!("blocked", evidence: { error_code: "interrupted" })
    assert_raises(ActiveRecord::RecordNotUnique) { create_attempt }
    attempt.transition_to!("superseded")
    assert_equal attempt.id, attempt.reload.reservation_key
    assert create_attempt.persisted?
    assert_equal "synthetic-source-a", attempt.source_identity
  end

  test "recorded source evidence survives blocking and stale writers cannot replace it" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    stale = LegacyDocumentMigrationAttempt.find(attempt.id)
    attempt.record_source_evidence!(evidence: source_evidence)
    assert_raises(ActiveRecord::StaleObjectError) { stale.update!(source_evidence.merge(source_size: 99)) }
    attempt.transition_to!("blocked")
    assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(source_size: 99) }
    attempt.reload.transition_to!("superseded")
    source_evidence.each { |field, value| assert_equal value, attempt.reload[field] }
  end

  test "creates durable run and planned attempt with exact restricted evidence" do
    attempt = create_attempt
    assert_equal "running", attempt.run.status
    assert_equal "planned", attempt.reload.state
    assert_equal "userFiles/Synthetic Case.PDF", attempt.expected_legacy_locator
    assert_equal 0, attempt.reservation_key
    assert_nil attempt.completed_at
    assert_nil attempt.lease_token
  end

  test "progresses forward and releases reservation only on closure" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    attempt.record_source_evidence!(evidence: source_evidence)
    attempt.transition_to!("published_verified", evidence: publication)
    attempt.transition_to!("committed")
    assert_equal 0, attempt.reload.reservation_key
    attempt.transition_to!("verified")
    assert_equal attempt.id, attempt.reload.reservation_key
    assert_not_nil attempt.completed_at
    attempt.transition_to!("rolled_back")
    assert_equal "rolled_back", attempt.reload.state
  end

  test "rejects backward skipped unknown and direct model transitions" do
    attempt = create_attempt
    %w[committed verified unknown].each do |state|
      assert_raises(ActiveRecord::RecordInvalid) { attempt.transition_to!(state) }
      attempt.reload
    end
    attempt.transition_to!("copying")
    assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(state: "planned") }
    attempt.reload
    assert_raises(ActiveRecord::RecordInvalid) { attempt.transition_to!("published_verified") }
    assert_equal "copying", attempt.reload.state
    assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(expected_legacy_locator: "userFiles/other.pdf") }
  end

  test "rejects duplicate active attempts across different runs" do
    attempt = create_attempt
    assert_raises(ActiveRecord::RecordNotUnique) { create_attempt }
    assert_equal "planned", attempt.reload.state
  end

  test "interruption and lease expiry preserve reservation until explicit reconciliation" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    attempt.update!(lease_token: SecureRandom.uuid,
      lease_expires_at: 1.minute.from_now, lease_generation: 1)
    attempt.run.finish!(status: "interrupted")
    assert_equal "copying", attempt.reload.state
    travel_to 2.minutes.from_now do
      assert attempt.reload.lease_expires_at < Time.current
      assert_raises(ActiveRecord::RecordNotUnique) { create_attempt }
    end
    attempt.transition_to!("blocked", evidence: { error_code: "interrupted" })
    assert_nil attempt.reload.lease_token
    assert_raises(ActiveRecord::RecordNotUnique) { create_attempt }
    assert_raises(ActiveRecord::RecordInvalid) { attempt.transition_to!("copying") }
    attempt.reload.transition_to!("superseded")
    retry_attempt = create_attempt
    assert_not_equal attempt.id, retry_attempt.id
    assert_equal "superseded", attempt.reload.state
    assert_equal "interrupted", attempt.error_code
    retry_attempt.transition_to!("gone")
    assert_equal retry_attempt.id, retry_attempt.reload.reservation_key
    assert create_attempt.persisted?
  end

  test "all declared edges are explicit and terminal states reject further work" do
    assert_equal %w[planned copying published_verified committed verified blocked superseded gone rolled_back].sort,
      LegacyDocumentMigrationAttempt::TRANSITIONS.keys.sort
    %w[superseded gone].each_with_index do |state, index|
      attempt = create_attempt(file_id: 2147482900 + index)
      attempt.transition_to!(state)
      assert_raises(ActiveRecord::RecordInvalid) { attempt.transition_to!("copying") }
    end
  end

  test "run completion retains counts and cannot restart" do
    run = create_run
    run.finish!(status: "completed", counts: { candidate_count: 2, verified_count: 1, blocked_count: 1 })
    assert_equal 2, run.reload.candidate_count
    assert_not_nil run.completed_at
    assert_raises(ActiveRecord::RecordInvalid) { run.update!(status: "running", completed_at: nil) }
    assert_raises(ActiveRecord::RecordInvalid) { create_run.update!(candidate_count: -1) }
  end

  test "ordinary updates cannot perform otherwise valid transitions" do
    attempt = create_attempt
    assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(state: "copying") }
    assert_equal "planned", attempt.reload.state
    attempt.transition_to!("copying")
    assert_raises(ActiveRecord::RecordInvalid) do
      attempt.update!(publication.merge(state: "published_verified"))
    end
    assert_equal "copying", attempt.reload.state
    assert_nil attempt.target_locator

    %w[completed interrupted failed].each do |status|
      run = create_run
      assert_raises(ActiveRecord::RecordInvalid) do
        run.update!(status: status, completed_at: Time.current)
      end
      assert_equal "running", run.reload.status
      assert_nil run.completed_at
    end
  end

  test "publication evidence remains immutable through later states and closure" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    attempt.record_source_evidence!(evidence: source_evidence)
    attempt.transition_to!("published_verified", evidence: publication)
    changes = publication.merge(target_locator: "privateDocuments/replacement.pdf",
      expected_size: 99, expected_sha256: "b" * 64,
      expected_legacy_locator: "userFiles/replacement.pdf", source_identity: "replacement")
    %w[published_verified committed verified rolled_back].each do |state|
      attempt.transition_to!(state) unless attempt.state == state
      changes.each do |field, value|
        assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(field => value) }
        attempt.reload
      end
      publication.each_key do |field|
        assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(field => nil) }
        attempt.reload
      end
      assert_equal publication.stringify_keys, attempt.attributes.slice(*publication.keys.map(&:to_s))
    end
  end

  test "valid transition cannot rewrite publication evidence and failed guards do not leak" do
    attempt = create_attempt
    attempt.transition_to!("copying")
    assert_raises(ActiveRecord::RecordInvalid) do
      attempt.transition_to!("published_verified", evidence: publication.merge(expected_size: -1))
    end
    assert_equal "copying", attempt.reload.state
    assert_nil attempt.target_locator
    assert_raises(ActiveRecord::RecordInvalid) do
      attempt.update!(publication.merge(state: "published_verified"))
    end
    attempt.reload.record_source_evidence!(evidence: source_evidence)
    attempt.transition_to!("published_verified", evidence: publication)
    publication.each_key do |field|
      value = { target_locator: "privateDocuments/other.pdf", expected_size: 13,
        expected_sha256: "b" * 64 }.fetch(field)
      assert_raises(ActiveRecord::RecordInvalid) do
        attempt.transition_to!("committed", evidence: { field => value })
      end
      assert_equal "published_verified", attempt.reload.state
    end
    assert_raises(ActiveRecord::RecordInvalid) { attempt.update!(state: "committed") }
    attempt.reload.transition_to!("committed", evidence: publication)
    attempt.transition_to!("blocked", evidence: { error_code: "operator_blocked" })
    assert_raises(ActiveRecord::RecordInvalid) do
      attempt.transition_to!("superseded", evidence: { expected_sha256: nil })
    end
    assert_equal "blocked", attempt.reload.state
    attempt.transition_to!("superseded")
    assert_equal publication[:expected_sha256], attempt.reload.expected_sha256
  end

  test "completed runs require all attempts closed and reject later admission" do
    %w[planned copying published_verified committed blocked].each_with_index do |state, index|
      attempt = create_attempt(file_id: 2147482800 + index)
      attempt.transition_to!("copying") unless state == "planned"
      if %w[published_verified committed].include?(state)
        attempt.record_source_evidence!(evidence: source_evidence)
        attempt.transition_to!("published_verified", evidence: publication)
      end
      attempt.transition_to!("committed") if state == "committed"
      attempt.transition_to!("blocked") if state == "blocked"
      run = attempt.run
      assert_raises(ActiveRecord::RecordInvalid) { run.finish!(status: "completed") }
      assert_equal "running", run.reload.status
      assert_nil run.completed_at
      assert_raises(ActiveRecord::RecordInvalid) do
        run.update!(status: "failed", completed_at: Time.current)
      end
      run.reload
      attempt.transition_to!(state == "committed" ? "verified" : "gone")
      run.finish!(status: "completed")
      assert_equal "completed", run.reload.status
      assert_raises(ActiveRecord::RecordInvalid) do
        create_attempt(run: run, file_id: 2147482700 + index)
      end
    end
  end

  test "interrupted and failed runs retain unresolved attempts and evidence" do
    %w[interrupted failed].each_with_index do |status, index|
      attempt = create_attempt(file_id: 2147482600 + index)
      attempt.transition_to!("copying")
      attempt.record_source_evidence!(evidence: source_evidence)
      attempt.transition_to!("published_verified", evidence: publication)
      attempt.run.finish!(status: status)
      assert_equal status, attempt.run.reload.status
      assert_equal "published_verified", attempt.reload.state
      assert_equal 0, attempt.reservation_key
      assert_equal publication[:expected_sha256], attempt.expected_sha256
      assert_raises(ActiveRecord::RecordNotUnique) { create_attempt(file_id: attempt.file_id) }
      attempt.transition_to!("committed")
      assert_equal "committed", attempt.reload.state
    end
  end

  test "all closed states release only their own reservation and retain history" do
    %w[verified superseded gone rolled_back].each_with_index do |state, index|
      attempt = create_attempt(file_id: 2147482500 + index)
      if %w[verified rolled_back].include?(state)
        attempt.transition_to!("copying")
        attempt.record_source_evidence!(evidence: source_evidence)
        attempt.transition_to!("published_verified", evidence: publication)
        attempt.transition_to!("committed")
      end
      attempt.transition_to!(state)
      replacement = create_attempt(file_id: attempt.file_id)
      assert_equal attempt.id, attempt.reload.reservation_key
      assert_equal 0, replacement.reservation_key
      assert_raises(ActiveRecord::RecordNotUnique) { create_attempt(file_id: attempt.file_id) }
      replacement.transition_to!("gone")
      assert create_attempt(file_id: attempt.file_id).persisted?
      assert_equal state, attempt.reload.state
    end
  end

  test "journal never modifies document metadata and survives hard deletion" do
    draft = FileDraft.create!(CreatorID: users(:tenant1).UserID, FileName: "Synthetic",
      FileTypes: "pdf", FileURLPath: "userFiles/Synthetic Case.PDF")
    before = draft.reload.attributes
    jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size
    attempt = create_attempt(file_id: draft.FileID)
    attempt.transition_to!("copying")
    attempt.record_source_evidence!(evidence: source_evidence)
    attempt.transition_to!("published_verified", evidence: publication)
    attempt.transition_to!("committed")
    attempt.transition_to!("verified")
    assert_equal before, draft.reload.attributes
    assert_equal jobs_before, ActiveJob::Base.queue_adapter.enqueued_jobs.size
    draft.destroy!
    assert_equal draft.FileID, attempt.reload.file_id
    assert_equal "verified", attempt.state
    assert LegacyDocumentMigrationRun.exists?(attempt.run_id)
  end

  test "database rejects invalid states required fields evidence reservations and leases without validations" do
    attempt = create_attempt
    [
      { state: "invalid" }, { state: "verified" }, { state: "committed" },
      { expected_legacy_locator: nil }, { source_identity: "" }, { file_id: nil },
      { run_id: -1 }, { reservation_key: nil }, { reservation_key: 42 },
      { expected_size: -1 }, { expected_sha256: "z" * 64 },
      { error_code: "exception with sensitive path" },
      { lease_token: SecureRandom.uuid }, { lease_generation: -1 }
    ].each do |attributes|
      assert_raises(ActiveRecord::StatementInvalid, attributes.inspect) do
        attempt.update_columns(attributes)
      end
      attempt.reload
    end
    assert_raises(ActiveRecord::InvalidForeignKey) { attempt.run.delete }
    assert_equal "planned", attempt.reload.state
  end

  test "database rejects invalid run status counts timestamps and duplicate identifiers" do
    run = create_run
    [{ status: "unknown" }, { status: "completed" }, { started_at: nil },
     { candidate_count: -1 }, { source_environment: "" }].each do |attributes|
      assert_raises(ActiveRecord::StatementInvalid) { run.update_columns(attributes) }
      run.reload
    end
    assert_raises(ActiveRecord::RecordNotUnique) do
      LegacyDocumentMigrationRun.insert_all!([{
        run_identifier: run.run_identifier, source_environment: "synthetic",
        status: "running", started_at: Time.current
      }])
    end
  end

  test "optimistic locking rejects stale journal writers" do
    attempt = create_attempt
    stale = LegacyDocumentMigrationAttempt.find(attempt.id)
    attempt.transition_to!("copying")
    assert_raises(ActiveRecord::StaleObjectError) { stale.update!(error_code: "interrupted") }
  end
end
