require "bigdecimal"
require "securerandom"

class LegacyDocumentMigrationAttempt < ApplicationRecord
  TRANSITIONS = {
    "planned" => %w[copying blocked superseded gone],
    "copying" => %w[published_verified blocked superseded gone],
    "published_verified" => %w[committed blocked superseded gone],
    "committed" => %w[verified blocked rolled_back],
    # Blocked retains its reservation. Reconciliation must explicitly close it;
    # a fresh attempt records retry work rather than rewinding old evidence.
    "blocked" => %w[superseded gone rolled_back],
    "verified" => %w[rolled_back],
    "superseded" => [], "gone" => [], "rolled_back" => []
  }.freeze
  CLOSED_STATES = %w[verified superseded gone rolled_back].freeze
  ERROR_CODES = %w[source_missing source_unsafe source_changed target_missing target_mismatch database_failure interrupted operator_blocked].freeze
  IDENTITY_FIELDS = %w[run_id file_id expected_legacy_locator source_identity started_at].freeze

  PUBLICATION_FIELDS = %w[target_locator expected_size expected_sha256].freeze
  SOURCE_EVIDENCE_RANGES = {
    "source_device" => 0..(2**64 - 1), "source_inode" => 0..(2**64 - 1),
    "source_size" => 0..(2**63 - 1), "source_link_count" => 1..(2**63 - 1),
    "source_mtime_seconds" => -(2**63)..(2**63 - 1),
    "source_mtime_nanoseconds" => 0..999_999_999,
    "source_ctime_seconds" => -(2**63)..(2**63 - 1),
    "source_ctime_nanoseconds" => 0..999_999_999
  }.freeze
  SOURCE_EVIDENCE_FIELDS = SOURCE_EVIDENCE_RANGES.keys.freeze

  class ClaimRejected < StandardError; end
  WORKER_STATES = %w[planned copying published_verified committed].freeze
  CLAIM_FIELDS = %w[lease_token lease_expires_at lease_generation].freeze
  SQL_SERVER_LOCK = "WITH (UPDLOCK, ROWLOCK, HOLDLOCK)".freeze

  around_create :serialize_run_admission

  belongs_to :run, class_name: "LegacyDocumentMigrationRun"

  validates :file_id, :expected_legacy_locator, :source_identity, :started_at, presence: true
  validates :expected_legacy_locator, :target_locator, length: { maximum: 500 }
  validates :source_identity, length: { maximum: 200 }
  validates :state, inclusion: { in: TRANSITIONS.keys }
  validates :error_code, inclusion: { in: ERROR_CODES }, allow_nil: true
  validates :expected_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :expected_sha256, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :validate_claim_ownership
  validate :validate_progress
  validate :validate_source_evidence

  # Returns credentials only after the top-level transaction commits. Never log them.
  def claim!(lease_seconds: 300)
    validate_lease_duration!(lease_seconds)
    raise ClaimRejected, "Claim requires a top-level transaction" if self.class.connection.transaction_open?

    with_claim_lock do
      raise ClaimRejected, "Attempt requires reconciliation" unless
        run.status == "running" && WORKER_STATES.include?(state) && lease_token.nil? && lease_generation.zero?
      raise ClaimRejected, "Generation exhausted" if lease_generation >= 2**63 - 1
      now = database_utc_now
      claim_update!(lease_token: SecureRandom.uuid, lease_generation: lease_generation + 1,
        lease_expires_at: now + lease_seconds)
      { worker_token: lease_token, generation: lease_generation }
    end
  end

  def renew_claim!(worker_token:, generation:, expected_state:, lease_seconds: 300)
    validate_lease_duration!(lease_seconds)
    with_claim_lock do
      now = guard_claim!(worker_token, generation, expected_state)
      claim_update!(lease_expires_at: [lease_expires_at, now + lease_seconds].max)
    end
  end

  # Release is a stop, not permission to resume or reacquire this attempt.
  def release_claim!(worker_token:, generation:, expected_state:)
    with_claim_lock do
      guard_claim!(worker_token, generation, expected_state)
      claim_update!(lease_token: nil, lease_expires_at: nil)
    end
  end

  # Operator-only, after quiescing the old worker and reconciling external evidence.
  # Matching durable credentials are required even after expiry; no takeover occurs.
  def reconcile_claim!(worker_token:, generation:, expected_state:, next_state: "blocked")
    # Isolate both writes even when a caller rescues inside an outer transaction.
    self.class.transaction(requires_new: true) do
      with_claim_lock do
        unless lease_generation.positive? && lease_token == worker_token &&
            generation.is_a?(Integer) && lease_generation == generation && state == expected_state &&
            %w[blocked superseded gone rolled_back].include?(next_state) &&
            TRANSITIONS.fetch(state, []).include?(next_state)
          raise ClaimRejected, "Claim does not match"
        end
        @worker_owned = true
        raise ClaimRejected, "Generation exhausted" if lease_generation >= 2**63 - 1
        claim_update!(lease_generation: lease_generation + 1)
        transition_to!(next_state, evidence: { error_code: "interrupted" },
          worker_token: worker_token, generation: generation, expected_state: expected_state,
          reconciliation: true)
      ensure
        @worker_owned = false
      end
    end
  end

  # Strict worker-only checkpoint; unlike historical journal APIs this never
  # permits generation-zero ownership. Blocks must contain short database work.
  def with_worker_claim!(worker_token:, generation:, expected_state:)
    raise ClaimRejected, "Worker checkpoint requires a top-level transaction" if self.class.connection.transaction_open?

    with_claim_lock do
      raise ClaimRejected, "Worker credentials required" unless lease_generation.positive? && worker_token.is_a?(String) && !worker_token.empty?

      guard_claim!(worker_token, generation, expected_state)
      yield self
    end
  end

  # Durable ownership before publication, never permission to resume publication.
  def record_copy_target!(locator:, worker_token:, generation:, expected_state:)
    with_worker_claim!(worker_token: worker_token, generation: generation, expected_state: expected_state) do
      unless state == "copying" && target_locator.nil? && SOURCE_EVIDENCE_FIELDS.all? { |field| !self[field].nil? }
        raise ClaimRejected, "Copy target requires fresh source evidence"
      end
      owned_update! { update!(target_locator: locator) }
    end
  end

  def record_copy_digest!(size:, sha256:, worker_token:, generation:, expected_state:)
    with_worker_claim!(worker_token: worker_token, generation: generation, expected_state: expected_state) do
      unless state == "copying" && target_locator.present? && expected_size.nil? && expected_sha256.nil? && source_size == size
        raise ClaimRejected, "Copy digest requires an unrecorded matching source size"
      end
      owned_update! { update!(expected_size: size, expected_sha256: sha256) }
    end
  end

  # Persist in a separate committed transaction before private publication.
  # This API does not inspect files or attest source safety.
  def record_source_evidence!(evidence:, worker_token: nil, generation: nil, expected_state: nil)
    unless evidence.keys.sort == SOURCE_EVIDENCE_FIELDS.map(&:to_sym).sort
      raise ArgumentError, "Complete source evidence required"
    end

    with_claim_lock do
      authorize_mutation!(worker_token, generation, expected_state)
      if state != "copying" || SOURCE_EVIDENCE_FIELDS.any? { |field| !self[field].nil? }
        errors.add(:base, "Source evidence requires an unrecorded copying attempt")
        raise ActiveRecord::RecordInvalid, self
      end
      owned_update! { update!(evidence) }
    end
  end

  # Serializes transitions and atomically releases the global reservation when
  # closed. No FileDraft lookup, filesystem or notification calls.
  def transition_to!(next_state, evidence: {}, worker_token: nil, generation: nil, expected_state: nil, reconciliation: false)
    allowed = %i[target_locator expected_size expected_sha256 error_code]
    raise ArgumentError, "Invalid evidence fields" unless (evidence.keys - allowed).empty?

    with_claim_lock do
      if reconciliation
        raise ClaimRejected, "Explicit reconciliation required" unless @worker_owned && %w[blocked superseded gone rolled_back].include?(next_state)
      else
        authorize_mutation!(worker_token, generation, expected_state)
      end
      unless TRANSITIONS.fetch(state, []).include?(next_state)
        errors.add(:state, "invalid transition")
        raise ActiveRecord::RecordInvalid, self
      end
      closed = CLOSED_STATES.include?(next_state)
      begin
        @transitioning = true
        owned_update! { update!(evidence.merge(state: next_state,
          reservation_key: closed ? id : 0,
          completed_at: closed ? Time.current : nil,
          lease_token: (closed || reconciliation) ? nil : lease_token,
          lease_expires_at: (closed || reconciliation) ? nil : lease_expires_at)) }
      ensure
        @transitioning = false
      end
    end
  end

  private

  def with_claim_lock(&block)
    run.with_lock(SQL_SERVER_LOCK) do
      with_lock(SQL_SERVER_LOCK, &block)
    end
  end

  def database_utc_now
    value = self.class.connection.select_value("SELECT SYSUTCDATETIME()")
    self.class.type_for_attribute("lease_expires_at").deserialize(value)
  end

  def validate_lease_duration!(seconds)
    raise ArgumentError, "Lease must be 1..3600 integer seconds" unless seconds.is_a?(Integer) && (1..3600).cover?(seconds)
  end

  def guard_claim!(token, generation, expected_state)
    now = database_utc_now
    unless token.is_a?(String) && token == lease_token && generation.is_a?(Integer) &&
        generation == lease_generation && expected_state == state && run.status == "running" &&
        WORKER_STATES.include?(state) &&
        lease_expires_at && lease_expires_at > now
      raise ClaimRejected, "Claim is invalid, expired, or in the wrong state"
    end
    now
  end

  def authorize_mutation!(token, generation, expected_state)
    # Compatibility for historical journal-only callers, never a claimed worker.
    return if lease_generation.zero? && lease_token.nil? && token.nil? && generation.nil?

    guard_claim!(token, generation, expected_state)
  end

  def owned_update!
    previous = @worker_owned
    @worker_owned = true
    yield
  ensure
    @worker_owned = previous
  end

  def claim_update!(attributes)
    owned_update! { update!(attributes) }
  end

  def validate_claim_ownership
    changed_claim = CLAIM_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
    if new_record?
      errors.add(:base, "Claims require claim!") if lease_token || lease_expires_at || lease_generation != 0
    elsif !@worker_owned && (changed_claim || lease_generation_in_database > 0)
      errors.add(:base, "Worker mutations require guarded APIs")
    end
  end

  def validate_source_evidence
    supplied = SOURCE_EVIDENCE_FIELDS.select { |field| !self[field].nil? }
    complete = supplied.size == SOURCE_EVIDENCE_FIELDS.size
    if supplied.any? && !complete
      errors.add(:base, "Complete source evidence required")
    end
    changed = SOURCE_EVIDENCE_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
    recorded = persisted? && SOURCE_EVIDENCE_FIELDS.any? { |field| !attribute_in_database(field).nil? }
    if changed
      if recorded
        errors.add(:base, "Recorded source evidence is immutable")
      elsif new_record? || state != "copying" || state_in_database != "copying"
        errors.add(:base, "Source evidence can only be recorded while copying")
      end
    end
    SOURCE_EVIDENCE_RANGES.each do |field, range|
      raw = read_attribute_before_type_cast(field)
      next if raw.nil?

      # Validate before AR casts decimals/integers, which could truncate input.
      integer = raw.is_a?(Integer) ||
        (raw.is_a?(BigDecimal) && raw.finite? && raw.frac.zero?) ||
        (raw.is_a?(String) && raw.match?(/\A[+-]?\d+\z/))
      unless integer && range.cover?(raw.to_i)
        errors.add(field, "must be an exact integer in the supported range")
      end
    end
    if %w[published_verified committed verified].include?(state) && !complete
      errors.add(:base, "Verified publication requires complete source evidence")
    end
  end

  # The same parent lock used by finish! prevents admission racing completion.
  # Existing attempts may still be reconciled after interruption or failure.
  def serialize_run_admission
    run.with_lock do
      unless run.status == "running"
        errors.add(:run, "must be running to admit an attempt")
        raise ActiveRecord::RecordInvalid, self
      end
      yield
    end
  end

  def validate_progress
    if new_record?
      errors.add(:state, "must start planned") unless state == "planned"
    elsif state_changed? && (!@transitioning || !TRANSITIONS.fetch(state_was, []).include?(state))
      errors.add(:state, "invalid transition")
    end
    if persisted? && IDENTITY_FIELDS.any? { |field| will_save_change_to_attribute?(field) }
      errors.add(:base, "Attempt identity is immutable")
    end
    if persisted? && PUBLICATION_FIELDS.any? { |field|
        will_save_change_to_attribute?(field) && !attribute_in_database(field).nil?
      }
      errors.add(:base, "Recorded publication evidence is immutable")
    end
    closed = CLOSED_STATES.include?(state)
    errors.add(:reservation_key, "inconsistent with state") unless reservation_key == (closed ? id : 0)
    errors.add(:completed_at, "inconsistent with state") unless closed == completed_at.present?
    errors.add(:completed_at, "precedes start") if completed_at && started_at && completed_at < started_at
    if %w[published_verified committed verified].include?(state)
      errors.add(:base, "Verified publication evidence required") unless target_locator.present? && !expected_size.nil? && expected_sha256.present?
    end
  end
end
