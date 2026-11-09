require "digest"

# Explicit, single-document database cutover. No publication, cleanup or retry.
class LegacyDocumentMigrationCutover
  class Failure < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super("Legacy document cutover stopped: #{code}")
    end
  end

  CHUNK_SIZE = 1024 * 1024

  def initialize(storage: nil)
    @storage = storage
  end

  def call(file_id:, attempt_id:, worker_token:, generation:, expected_state:)
    raise Failure.new("interrupted") if LegacyDocumentMigrationAttempt.connection.transaction_open?
    unless expected_state == "published_verified"
      raise LegacyDocumentMigrationAttempt::ClaimRejected, "Verified publication required"
    end

    attempt = LegacyDocumentMigrationAttempt.find(attempt_id)
    fence = { worker_token: worker_token, generation: generation, expected_state: expected_state }
    # with_worker_claim! supplies the top-level transaction and run -> attempt
    # locks. All errors escape that transaction before being translated below.
    attempt.with_worker_claim!(**fence) do
      raise Failure.new("interrupted") unless attempt.file_id == file_id
      validate_evidence!(attempt)
      file = FileDraft.unscoped.lock(LegacyDocumentMigrationAttempt::SQL_SERVER_LOCK).find_by(FileID: file_id)
      raise Failure.new("source_missing") unless file
      unless file.FileURLPath.is_a?(String) && file.FileURLPath.b == attempt.expected_legacy_locator.b
        raise Failure.new("source_changed")
      end

      storage = @storage || DocumentStorage.configured
      storage.open_private(attempt.target_locator) do |io|
        before = identity(io.stat)
        digest = Digest::SHA256.new
        size = 0
        while (chunk = io.read(CHUNK_SIZE))
          digest.update(chunk)
          size += chunk.bytesize
        end
        unless identity(io.stat) == before && size == attempt.expected_size &&
            digest.hexdigest == attempt.expected_sha256
          raise Failure.new("target_mismatch")
        end
      end
      # open_private's final pathname/root checks have completed. A locator-only
      # update deliberately bypasses callbacks, timestamps and signing workflows.
      affected = FileDraft.unscoped.where(FileID: file_id, FileURLPath: file.FileURLPath)
        .update_all(FileURLPath: attempt.target_locator)
      raise Failure.new("database_failure") unless affected == 1

      # Rechecks database UTC expiry after hashing; failure rolls back the draft.
      attempt.transition_to!("committed", **fence)
    end
    attempt
  rescue LegacyDocumentMigrationAttempt::ClaimRejected
    raise
  rescue StandardError => error
    code = if error.is_a?(Failure)
      error.code
    elsif error.is_a?(DocumentStorage::MissingFile)
      "target_missing"
    elsif error.is_a?(DocumentStorage::Error)
      "target_mismatch"
    elsif error.is_a?(ActiveRecord::ActiveRecordError)
      "database_failure"
    else
      "interrupted"
    end
    # Never guess the outcome of a lost commit or write a failure transition.
    raise Failure.new(code), cause: nil
  end

  private

  def validate_evidence!(attempt)
    legacy = attempt.expected_legacy_locator
    # Do not call valid? here: ordinary validation intentionally rejects worker
    # mutations outside the model's owned-update context, even on a clean row.
    source_valid = LegacyDocumentMigrationAttempt::SOURCE_EVIDENCE_RANGES.all? do |field, range|
      value = attempt[field]
      value && (value.is_a?(Integer) || (value.is_a?(BigDecimal) && value.finite? && value.frac.zero?)) &&
        range.cover?(value.to_i)
    end
    unless legacy.is_a?(String) && legacy.valid_encoding? && legacy.ascii_only? && legacy.bytesize <= 255 &&
        legacy.match?(/\AuserFiles\/[a-zA-Z0-9][a-zA-Z0-9_. -]*\z/) && !legacy.include?("..") &&
        attempt.target_locator.is_a?(String) && attempt.target_locator.start_with?(DocumentStorage::PRIVATE_PREFIX) &&
        attempt.source_identity.present? &&
        source_valid &&
        attempt.source_link_count == 1 && attempt.expected_size.is_a?(Integer) &&
        attempt.expected_size.positive? && attempt.source_size == attempt.expected_size &&
        attempt.expected_sha256.is_a?(String) && attempt.expected_sha256.match?(/\A[0-9a-f]{64}\z/)
      raise Failure.new("target_mismatch")
    end
  end

  def identity(stat)
    raise Failure.new("target_mismatch") unless stat.file? && stat.nlink == 1

    [stat.dev, stat.ino, stat.size, stat.nlink,
      stat.mtime.to_i, stat.mtime.nsec, stat.ctime.to_i, stat.ctime.nsec]
  end
end
