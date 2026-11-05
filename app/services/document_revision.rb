# Revises an already authorized, persisted document. Callers own authorization
# and domain checks (for example, agreement versions and signing eligibility).
class DocumentRevision
  class Failure < StandardError; end

  def initialize(storage: nil, logger: Rails.logger)
    @storage = storage
    @logger = logger
  end

  # writer receives original bytes, a private staging path, and the locked,
  # reloaded record. It must write only to the staging path. The optional block
  # assigns metadata on that same record; this service saves it with the locator.
  # Pass a clean persisted record: with_lock rejects unsaved attribute changes.
  # Success inside an outer transaction remains provisional until its commit.
  def call(file:, extension:, writer:)
    raise Failure, "Document must be persisted" unless file.persisted?

    storage = @storage || DocumentStorage.configured
    result = file.with_lock(requires_new: true) do
      original = File.binread(storage.resolve(file.FileURLPath))
      DocumentCreation.new(storage: storage, records: file.class, logger: @logger).call(
        extension: extension,
        writer: ->(path) { writer.call(original, path, file) }
      ) do |locator|
        yield file if block_given?
        file.FileURLPath = locator
        file.save!
        file
      end
    end
    raise Failure, "Document revision rolled back" unless result.equal?(file)

    result
  rescue StandardError => error
    begin
      @logger.error("Document revision failed error=#{error.class}")
    rescue StandardError
      # Logging must not replace the revision failure.
    end
    raise Failure, "Unable to revise document", cause: error
  end
end
