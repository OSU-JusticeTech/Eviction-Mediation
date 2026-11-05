# Observational report, never authority to unlink a file. Writers do not share
# a locator lock, and superseded versions have no persistent history registry.
class DocumentFileInventory
  class Failure < StandardError; end

  def initialize(storage: nil, records: FileDraft)
    @storage = storage
    @records = records
  end

  def call
    storage = @storage || DocumentStorage.configured
    # Finish the query before classifying files. A failed query must never look
    # like an empty set of references. unscoped includes soft-deleted records.
    references = @records.unscoped.pluck(:FileID, :FileURLPath).group_by(&:last)
    report = { dry_run: true, physical_deletion_enabled: false,
               referenced_private_files: [], unreferenced_private_files: [],
               missing_referenced_files: [], invalid_or_unsafe_locators: [],
               legacy_references: [] }
    entries = storage.private_inventory_entries.to_h
    (entries.keys | references.keys).each do |locator|
      ids = references.fetch(locator, []).map(&:first)
      item = { locator: locator, file_ids: ids }
      if legacy_locator?(locator)
        report[:legacy_references] << item
        next
      end

      status = entries.fetch(locator) { storage.private_inventory_status(locator) }
      category = case status
      when :present
        ids.empty? ? :unreferenced_private_files : :referenced_private_files
      when :missing
        # A file removed during enumeration is not a missing DB reference.
        ids.empty? ? nil : :missing_referenced_files
      else
        :invalid_or_unsafe_locators
      end
      report[category] << item if category
    end
    report
  rescue StandardError => error
    # Do not return a partial report after a DB or filesystem failure.
    raise Failure, "Document file inventory failed", cause: error
  end

  private

  def legacy_locator?(locator)
    locator.is_a?(String) && locator.bytesize <= 255 &&
      locator.match?(/\AuserFiles\/[a-zA-Z0-9][a-zA-Z0-9_. -]*\z/) && !locator.include?("..")
  end
end
