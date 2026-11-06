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

  around_create :serialize_run_admission

  belongs_to :run, class_name: "LegacyDocumentMigrationRun"

  validates :file_id, :expected_legacy_locator, :source_identity, :started_at, presence: true
  validates :expected_legacy_locator, :target_locator, length: { maximum: 500 }
  validates :source_identity, length: { maximum: 200 }
  validates :state, inclusion: { in: TRANSITIONS.keys }
  validates :error_code, inclusion: { in: ERROR_CODES }, allow_nil: true
  validates :expected_size, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
  validates :expected_sha256, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :validate_progress

  # Serializes transitions and atomically releases the global reservation when
  # closed. No FileDraft lookup, filesystem or notification calls.
  def transition_to!(next_state, evidence: {})
    allowed = %i[target_locator expected_size expected_sha256 error_code]
    raise ArgumentError, "Invalid evidence fields" unless (evidence.keys - allowed).empty?

    with_lock do
      unless TRANSITIONS.fetch(state, []).include?(next_state)
        errors.add(:state, "invalid transition")
        raise ActiveRecord::RecordInvalid, self
      end
      closed = CLOSED_STATES.include?(next_state)
      begin
        @transitioning = true
        update!(evidence.merge(state: next_state,
          reservation_key: closed ? id : 0,
          completed_at: closed ? Time.current : nil,
          lease_token: nil, lease_expires_at: nil))
      ensure
        @transitioning = false
      end
    end
  end

  private

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
