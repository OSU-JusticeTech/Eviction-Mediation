class LegacyDocumentMigrationRun < ApplicationRecord
  STATUSES = %w[running completed interrupted failed].freeze

  has_many :attempts, class_name: "LegacyDocumentMigrationAttempt", foreign_key: :run_id

  validates :run_identifier, :source_environment, :started_at, presence: true
  validates :run_identifier, format: { with: /\A[0-9a-f-]{36}\z/ }
  validates :source_environment, length: { maximum: 100 }
  validates :status, inclusion: { in: STATUSES }
  validates :candidate_count, :verified_count, :blocked_count,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :validate_progress

  def finish!(status:, counts: {})
    raise ArgumentError, "Invalid summary fields" unless (counts.keys - %i[candidate_count verified_count blocked_count]).empty?

    with_lock do
      unless self.status == "running" && (STATUSES - ["running"]).include?(status)
        errors.add(:status, "invalid transition")
        raise ActiveRecord::RecordInvalid, self
      end
      begin
        @finishing = true
        update!(counts.merge(status: status, completed_at: Time.current))
      ensure
        @finishing = false
      end
    end
  end

  private

  def validate_progress
    if new_record?
      errors.add(:status, "must start running") unless status == "running"
    elsif status_changed? && (!@finishing || status_was != "running" || status == "running")
      errors.add(:status, "invalid transition")
    end
    if status == "completed" && attempts.where.not(state: LegacyDocumentMigrationAttempt::CLOSED_STATES).exists?
      errors.add(:status, "cannot complete with unresolved attempts")
    end
    if persisted? && (run_identifier_changed? || source_environment_changed? || started_at_changed?)
      errors.add(:base, "Run identity is immutable")
    end
    errors.add(:completed_at, "inconsistent with status") if (status == "running") != completed_at.nil?
    errors.add(:completed_at, "precedes start") if completed_at && started_at && completed_at < started_at
  end
end
