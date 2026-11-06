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
    transaction_started = false
    storage = @storage || DocumentStorage.configured
    begin
      locator = storage.write(extension: extension, &writer)
    rescue DocumentStorage::CleanupFailure => error
      # Publication completed: persist these bytes rather than publishing twice.
      locator = error.locator
      @logger.error("Document creation staging cleanup failed locator=#{locator}")
    end

    transaction_started = true
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
    # An exception from transaction/commit does not prove rollback: the server
    # may have committed before the connection failed. Only the rollback
    # callback owns cleanup once database coordination has begun.
    cleanup(storage, locator) if locator && !transaction_started && !committed && !rolled_back
    if locator && transaction_started && !committed && !rolled_back
      @logger.error("Document creation outcome uncertain; publication retained locator=#{locator}")
    end
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
