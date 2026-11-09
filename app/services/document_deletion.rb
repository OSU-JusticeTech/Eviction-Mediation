# Owns document deletion only. A soft-deleted row remains a storage reference.
class DocumentDeletion
  class Failure < StandardError; end
  class NotFound < StandardError; end
  class Unauthorized < StandardError; end

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def call(id:, user:)
    completed = false
    FileDraft.transaction(requires_new: true) do |transaction|
      file = FileDraft.lock.find_by(FileID: id)
      raise NotFound unless file
      raise Unauthorized unless authorized?(file, user)

      locator = file.FileURLPath
      # Unlike destroy_all, destroy! propagates a callback veto and rolls back
      # every attachment along with the document change.
      FileAttachment.where(FileID: file.FileID).each(&:destroy!)
      if file.has_attribute?(:UserDeletedAt)
        file.update!(UserDeletedAt: Time.current)
      else
        file.destroy!
      end
      transaction.after_commit { cleanup(locator) }
      completed = true
      transaction.after_rollback { completed = false }
    end
    raise Failure, "Document transaction rolled back" unless completed

    true
  rescue NotFound, Unauthorized
    raise
  rescue StandardError => error
    log("Document deletion failed error=#{error.class}")
    raise Failure, "Unable to delete document", cause: error
  end

  private

  def authorized?(file, user)
    return false unless user
    return true if file.CreatorID == user[:UserID]

    messages = Message.where(MessageID: FileAttachment.where(FileID: file.FileID).select(:MessageID))
    PrimaryMessageGroup.where(ConversationID: messages.select(:ConversationID))
      .where("LandlordID = ? OR TenantID = ?", user[:UserID], user[:UserID]).exists?
  end

  def cleanup(locator)
    return unless locator.is_a?(String) && locator.start_with?(DocumentStorage::PRIVATE_PREFIX)
    # Include deleted rows: agreements and attachments resolve through these
    # same FileDraft locators. Never remove bytes referenced by a surviving row.
    return if FileDraft.unscoped.where(FileURLPath: locator).exists?

    # Historical schemas can hard-delete rows. There is no locator registry or
    # shared lock protocol with attachment/revision writers, so a reference
    # check alone cannot exclude a concurrent writer reusing this locator.
    # Retain these rare orphans until coordinated cleanup is available.
    log("Document deletion cleanup deferred locator=#{locator}")
  rescue StandardError => error
    log("Document deletion cleanup failed locator=#{locator} error=#{error.class}")
  end

  def log(message)
    @logger.error(message)
  rescue StandardError
    # A logging failure cannot change the outcome of a committed deletion.
  end
end
