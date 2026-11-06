require "digest"

# Explicit single-document operation. Callers authorize the environment and an
# immutable source snapshot / enforced writer freeze before invoking this API.
# No retry, cutover, source mutation, cleanup, logging, or claim acquisition.
class LegacyDocumentMigrationCopy
  class Failure < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super("Legacy document copy stopped: #{code}")
    end
  end

  CHUNK_SIZE = 1024 * 1024

  def initialize(storage: nil)
    @storage = storage
  end

  def call(file_id:, attempt_id:, worker_token:, generation:, expected_state:)
    raise Failure.new("interrupted") if LegacyDocumentMigrationAttempt.connection.transaction_open?
    raise LegacyDocumentMigrationAttempt::ClaimRejected, "Fresh planned attempt required" unless expected_state == "planned"

    attempt = LegacyDocumentMigrationAttempt.find(attempt_id)
    fence = { worker_token: worker_token, generation: generation, expected_state: expected_state }
    checkpoint(attempt, file_id, fence) do
      unless attempt.target_locator.nil? && attempt.expected_size.nil? && attempt.expected_sha256.nil? &&
          LegacyDocumentMigrationAttempt::SOURCE_EVIDENCE_FIELDS.all? { |field| attempt[field].nil? }
        raise Failure.new("interrupted")
      end
      attempt.transition_to!("copying", **fence)
    end
    fence = fence.merge(expected_state: "copying")
    storage = @storage || DocumentStorage.configured
    phase = :source
    verified_copy = nil
    storage.open_legacy(attempt.expected_legacy_locator) do |source|
      identity = source_evidence(source.stat)
      raise Failure.new("source_unsafe") if identity[:source_size].zero?
      attempt.record_source_evidence!(evidence: identity, **fence)
      # Storage intentionally normalizes the extension to lowercase.
      target = storage.allocate_private_locator(extension: File.extname(attempt.expected_legacy_locator))
      attempt.record_copy_target!(locator: target, **fence)
      checkpoint(attempt, file_id, fence)
      phase = :target
      copied = nil
      storage.publish_private(locator: target) do |path|
        File.open(path, "wb") do |destination|
          copied = digest_stream(source, -> { checkpoint(attempt, file_id, fence) }) do |chunk|
            destination.write(chunk)
          end
        end
        assert_source!(source, identity)
        verify_source!(source, identity, copied, attempt, file_id, fence)
        File.open(path, "rb") do |staged|
          raise Failure.new("target_mismatch") unless digest_stream(staged) == copied
        end
        assert_source!(source, identity)
        checkpoint(attempt, file_id, fence)
        attempt.record_copy_digest!(size: copied.first, sha256: copied.last, **fence)
      end
      storage.open_private(target) do |private_file|
        before = source_evidence(private_file.stat)
        raise Failure.new("target_mismatch") unless digest_stream(private_file,
          -> { checkpoint(attempt, file_id, fence) }) == copied
        raise Failure.new("target_mismatch") unless source_evidence(private_file.stat) == before
      end
      phase = :source
      verify_source!(source, identity, copied, attempt, file_id, fence)
      verified_copy = copied
    end
    # open_legacy's pathname/root checks must also succeed before attestation.
    checkpoint(attempt, file_id, fence) do
      size, sha256 = verified_copy
      attempt.transition_to!("published_verified",
        evidence: { expected_size: size, expected_sha256: sha256 }, **fence)
    end
    attempt
  rescue LegacyDocumentMigrationAttempt::ClaimRejected
    raise
  rescue StandardError => error
    # Do not mutate a possibly ambiguous journal after failure. The durable
    # copying state, source bundle and preallocated target support reconciliation.
    code = if error.is_a?(Failure)
      error.code
    elsif error.is_a?(DocumentStorage::MissingFile)
      phase == :target ? "target_missing" : "source_missing"
    elsif error.is_a?(DocumentStorage::Error)
      phase == :target ? "target_mismatch" : "source_unsafe"
    elsif error.is_a?(ActiveRecord::ActiveRecordError)
      "database_failure"
    else
      "interrupted"
    end
    raise Failure.new(code), cause: nil
  end

  private

  def checkpoint(attempt, file_id, fence)
    attempt.with_worker_claim!(**fence) do
      raise Failure.new("interrupted") unless attempt.file_id == file_id
      # This service never locks a draft before the run/attempt. No file I/O is
      # performed under these locks, and no draft attributes are saved.
      file = FileDraft.unscoped.lock(LegacyDocumentMigrationAttempt::SQL_SERVER_LOCK).find_by(FileID: file_id)
      raise Failure.new("source_missing") unless file
      unless file.FileURLPath.is_a?(String) && file.FileURLPath.b == attempt.expected_legacy_locator.b
        raise Failure.new("source_changed")
      end
      yield if block_given?
    end
  end

  def source_evidence(stat)
    raise Failure.new("source_unsafe") unless stat.file? && stat.nlink == 1

    { source_device: stat.dev, source_inode: stat.ino, source_size: stat.size,
      source_link_count: stat.nlink, source_mtime_seconds: stat.mtime.to_i,
      source_mtime_nanoseconds: stat.mtime.nsec, source_ctime_seconds: stat.ctime.to_i,
      source_ctime_nanoseconds: stat.ctime.nsec }
  end

  def assert_source!(source, identity)
    raise Failure.new("source_changed") unless source_evidence(source.stat) == identity
  end

  def verify_source!(source, identity, copied, attempt, file_id, fence)
    assert_source!(source, identity)
    source.rewind
    unless digest_stream(source, -> { checkpoint(attempt, file_id, fence) }) == copied && copied.first == identity[:source_size]
      raise Failure.new("source_changed")
    end
    assert_source!(source, identity)
  end

  def digest_stream(io, check = nil)
    digest = Digest::SHA256.new
    size = 0
    loop do
      check&.call
      chunk = io.read(CHUNK_SIZE)
      break unless chunk
      digest.update(chunk)
      size += chunk.bytesize
      yield chunk if block_given?
    end
    [size, digest.hexdigest]
  end
end
