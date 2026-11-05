# Coordinates only new documents. Existing documents and legacy files are untouched.
class DocumentCreation
  class Failure < StandardError; end

  def initialize(storage: nil, records: FileDraft, logger: Rails.logger)
    @storage = storage
    @records = records
    @logger = logger
  end

  def call(extension:, writer:)
    locator = nil
    committed = false
    rolled_back = false
    storage = @storage || DocumentStorage.configured
    begin
      locator = storage.write(extension: extension, &writer)
    rescue DocumentStorage::CleanupFailure => error
      # Publication completed: persist these bytes rather than publishing twice.
      locator = error.locator
      @logger.error("Document creation staging cleanup failed locator=#{locator}")
    end

    result = @records.transaction(requires_new: true) do |transaction|
      transaction.after_commit { committed = true }
      transaction.after_rollback do
        rolled_back = true
        cleanup(storage, locator)
      end
      yield locator
    end
    raise Failure, "Document transaction rolled back" if rolled_back

    result
  rescue StandardError => error
    cleanup(storage, locator) if locator && !committed && !rolled_back
    @logger.error("Document creation failed error=#{error.class}")
    raise Failure, "Unable to create document"
  end

  private

  def cleanup(storage, locator)
    storage.delete_private(locator)
  rescue StandardError => error
    # Keep the locator available for operator reconciliation; preserve the original error.
    @logger.error("Document creation cleanup failed locator=#{locator} error=#{error.class}")
  end
end
