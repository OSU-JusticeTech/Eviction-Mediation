require "digest"
require "json"

# One durable attempt only. Inspection never writes; recovery never publishes.
class LegacyDocumentMigrationReconciliation
  class Failure < StandardError; end
  CHUNK_SIZE = 1024 * 1024
  ACTIONS = {
    "published_unfinalized" => "finalize_publication",
    "private_verified_database_pending" => "cutover",
    "database_cutover_completed" => "verify_cutover"
  }.freeze

  def initialize(storage: nil)
    @storage = storage
  end

  def inspect_attempt(attempt_id:)
    locked(attempt_id) { |attempt, file| inspect_locked(attempt, file) }
  end

  # Explicit operator path; expiry alone never authorizes worker takeover.
  def recover_expired_claim(attempt_id:, inspection_id:, action:, approval:,
      workers_stopped:, source_frozen:, authoritative_database:)
    recover(attempt_id: attempt_id, inspection_id: inspection_id, action: action,
      worker_token: nil, generation: nil, approval: approval,
      workers_stopped: workers_stopped, source_frozen: source_frozen,
      authoritative_database: authoritative_database, expired_claim: true)
  end

  # approval is a trusted caller policy, never a worker token or request boolean.
  # It receives a frozen report and the exact action plus explicit attestations.
  def recover(attempt_id:, inspection_id:, action:, worker_token:, generation:,
      approval:, workers_stopped:, source_frozen:, authoritative_database:, expired_claim: false)
    raise Failure, "Operator policy and attestations required" unless
      approval.respond_to?(:call) && workers_stopped == true && source_frozen == true && authoritative_database == true

    locked(attempt_id) do |attempt, file|
      report = inspect_locked(attempt, file)
      raise Failure, "Inspection changed or decision unsafe" unless
        report[:inspection_id] == inspection_id && report[:action] == action && report[:lease] == (expired_claim ? "expired" : "live")
      context = report.merge(action: action, recovery_path: expired_claim ? "expired_claim" : "live_claim", workers_stopped: true,
        source_frozen: true, authoritative_database: true).freeze
      raise Failure, "Operator approval denied" unless approval.call(context) == true
      raise Failure, "Inspection changed during approval" unless inspect_locked(attempt.reload, file&.reload) == report
      fence = { worker_token: worker_token, generation: generation, expected_state: attempt.state }
      if expired_claim
        attempt.send(:begin_expired_reconciliation!)
      else
        attempt.send(:guard_claim!, worker_token, generation, attempt.state)
      end
      next_state = case action
      when "finalize_publication"
        "published_verified"
      when "cutover"
        affected = FileDraft.unscoped.where(FileID: attempt.file_id, FileURLPath: file.FileURLPath)
          .update_all(FileURLPath: attempt.target_locator)
        raise Failure, "Guarded update failed" unless affected == 1
        "committed"
      when "verify_cutover"
        "verified"
      else
        raise Failure, "Unsupported recovery"
      end
      attempt.transition_to!(next_state, **fence)
      # A nested transaction can swallow ActiveRecord::Rollback. Confirm the
      # row within our transaction before treating a checkpoint as done. This
      # is a consistency check, not evidence that the transaction has committed.
      raise Failure, "Transition not recorded" unless attempt.reload.state == next_state
      # transition_to! checks database expiry after all inspection and approval.
      attempt.send(:fence_reconciled_worker!) unless expired_claim
      attempt
    ensure
      attempt.send(:end_expired_reconciliation!)
    end
  end

  private

  def locked(id)
    raise Failure, "Top-level transaction required" if LegacyDocumentMigrationAttempt.connection.transaction_open?

    attempt = LegacyDocumentMigrationAttempt.find(id)
    result = LegacyDocumentMigrationAttempt.transaction do
      locked_result = attempt.run.with_lock(LegacyDocumentMigrationAttempt::SQL_SERVER_LOCK) do
        attempt.with_lock(LegacyDocumentMigrationAttempt::SQL_SERVER_LOCK) do
          file = FileDraft.unscoped.lock(LegacyDocumentMigrationAttempt::SQL_SERVER_LOCK).find_by(FileID: attempt.file_id)
          begin
            yield attempt, file
          rescue ActiveRecord::Rollback
            # Joined with_lock transactions swallow Rollback without rolling
            # back their caller's transaction. Escape with an ordinary failure
            # so the transaction we own rolls back every reconciliation write.
            raise Failure, "Reconciliation rolled back"
          end
        end
      end
      # Detect a rollback swallowed by a lock wrapper before our owner commits.
      raise Failure, "Transaction did not complete" unless locked_result

      locked_result
    end
    raise Failure, "Transaction did not complete" unless result

    result
  rescue ActiveRecord::ActiveRecordError
    # Commit errors are uncertain outcomes. Never retry or record a second write.
    raise Failure, "Database outcome uncertain; inspect authoritative database", cause: nil
  end

  def inspect_locked(attempt, file)
    storage = @storage || DocumentStorage.configured
    source = observe(storage, :open_legacy, attempt.expected_legacy_locator)
    target = attempt.target_locator.nil? ? { status: "unallocated" } : observe(storage, :open_private, attempt.target_locator)
    now = attempt.send(:database_utc_now)
    lease = if attempt.lease_token.nil?
      "absent"
    elsif attempt.lease_expires_at && attempt.lease_expires_at > now
      "live"
    else
      "expired"
    end
    # SQL equality deliberately catches aliases under the deployed collation.
    # Any other reference, including a case/space alias, is a conflict.
    conflicts = attempt.target_locator && (
      FileDraft.unscoped.where(FileURLPath: attempt.target_locator).where.not(FileID: attempt.file_id).exists? ||
      LegacyDocumentMigrationAttempt.where(target_locator: attempt.target_locator).where.not(id: attempt.id).exists?)
    outcome = classify(attempt, file, source, target, conflicts)
    action = ACTIONS[outcome] if %w[live expired].include?(lease) && attempt.run.status == "running"
    action = nil if attempt.state == "verified"
    report = { attempt_id: attempt.id, outcome: outcome, action: action, lease: lease,
      source: source.freeze, target: target.freeze }
    # Bind approval to all durable fields and filesystem observations. No token
    # or raw locator is returned in the report. Database time is not fingerprinted.
    report[:inspection_id] = Digest::SHA256.hexdigest(JSON.generate([
      attempt.attributes.sort, attempt.run.attributes.sort, file&.attributes&.sort, report]))
    report.freeze
  end

  def classify(a, file, source, target, conflicts)
    return "ambiguous" if conflicts || source[:status] == "unsafe" || target[:status] == "unsafe"
    return "source_changed_or_disappeared" unless file
    legacy = exact?(file.FileURLPath, a.expected_legacy_locator)
    private_reference = a.target_locator && exact?(file.FileURLPath, a.target_locator)
    return "source_changed_or_disappeared" unless legacy || private_reference
    return "source_changed_or_disappeared" unless source[:status] == "present"
    recorded = LegacyDocumentMigrationAttempt::SOURCE_EVIDENCE_FIELDS.map { |field| a[field]&.to_i }
    return "source_changed_or_disappeared" if recorded.any? && recorded != source[:identity]
    digest_recorded = a.expected_size && a.expected_sha256
    return "ambiguous" if digest_recorded && [a.expected_size, a.expected_sha256] != source[:digest]
    matches = digest_recorded && a.expected_size.positive? && a.source_size == a.expected_size &&
      [a.expected_size, a.expected_sha256] == source[:digest] && target[:digest] == source[:digest]
    if private_reference
      return "database_cutover_completed" if %w[committed verified].include?(a.state) && matches
      return "ambiguous"
    end
    case a.state
    when "planned"
      return "copy_never_started" if recorded.none? && a.target_locator.nil? && !digest_recorded
    when "copying"
      return "published_unfinalized" if matches && recorded.all?
      return "copy_interrupted_before_publication" if %w[missing unallocated].include?(target[:status])
    when "published_verified"
      return "private_verified_database_pending" if matches && recorded.all?
    end
    "ambiguous"
  end

  def exact?(left, right)
    left.is_a?(String) && right.is_a?(String) && left.b == right.b
  end

  def observe(storage, method, locator)
    result = nil
    storage.public_send(method, locator) do |io|
      before = identity(io.stat)
      digest, size = Digest::SHA256.new, 0
      while (chunk = io.read(CHUNK_SIZE))
        digest.update(chunk)
        size += chunk.bytesize
      end
      raise Failure, "File changed during inspection" unless identity(io.stat) == before && size == before[2]
      result = { status: "present", identity: before.freeze, digest: [size, digest.hexdigest].freeze }
    end
    result
  rescue DocumentStorage::MissingFile
    # Includes disabled legacy access: absence is never recovery authorization.
    { status: "missing" }
  rescue DocumentStorage::Error, Failure, SystemCallError, IOError
    { status: "unsafe" }
  end

  def identity(stat)
    raise Failure, "Unsafe file" unless stat.file? && stat.nlink == 1

    [stat.dev, stat.ino, stat.size, stat.nlink, stat.mtime.to_i, stat.mtime.nsec,
      stat.ctime.to_i, stat.ctime.nsec]
  end
end
