require "pathname"

# Restricted in-memory manifest: never log/inspect the returned report in an
# ordinary application log. Observational only; no section authorizes deletion.
class LegacyDocumentInventory
  class Failure < StandardError; end

  def initialize(configuration: nil, records: FileDraft)
    @configuration = configuration
    @records = records
  end

  def call
    started_at = Time.now.utc
    configuration = @configuration || Rails.application.config.x.document_storage
    roots = { legacy: configuration.legacy_root, private: configuration.root }
    roots.each_value { |root| check_root!(root) }
    public_root = Pathname(configuration.public_root).cleanpath.to_s
    private_path = Pathname(configuration.root).cleanpath.to_s
    raise Failure if private_path == public_root || private_path.start_with?(public_root + "/")
    legacy, private_root = roots.values.map { |root| Pathname(root).cleanpath.to_s }
    if legacy == private_root || legacy.start_with?(private_root + "/") || private_root.start_with?(legacy + "/")
      raise Failure
    end

    deleted_column = @records.column_names.include?("UserDeletedAt")
    columns = [:FileID, :FileURLPath]
    columns << :UserDeletedAt if deleted_column
    rows = @records.unscoped.pluck(*columns)
    references = rows.map do |id, locator, deleted_at|
      { file_id: id, locator: locator, kind: locator_kind(locator),
        deletion_status: deleted_column ? (deleted_at ? :soft_deleted : :active) : :unknown }
    end
    groups = references.group_by { |reference| reference[:locator] }
    files = roots.flat_map do |kind, root|
      prefix = kind == :legacy ? "userFiles/" : "privateDocuments/"
      check_root!(root)
      Dir.children(root).map do |name|
        check_root!(root)
        locator = prefix + name
        stat = File.lstat(Pathname(root).join(name))
        reason = if stat.symlink?
          :symlink
        elsif !stat.file?
          :nonregular_entry
        elsif stat.nlink != 1
          :multiple_hard_links
        elsif (stat.mode & 0o444).zero?
          :unreadable_file
        elsif locator_kind(locator) != kind
          :invalid_filename
        end
        { locator: locator, kind: kind, status: reason ? :unsafe : :present,
          reason: reason, file_ids: groups.fetch(locator, []).map { |r| r[:file_id] },
          metadata: { size: stat.size, device: stat.dev, inode: stat.ino,
                      links: stat.nlink, mode: stat.mode, mtime: stat.mtime } }
      end
    end
    observed = files.to_h { |entry| [entry[:locator], entry] }
    locators = groups.map do |locator, refs|
      kind = refs.first[:kind]
      { locator: locator, kind: kind, file_ids: refs.map { |r| r[:file_id] },
        active_count: refs.count { |r| r[:deletion_status] == :active },
        soft_deleted_count: refs.count { |r| r[:deletion_status] == :soft_deleted },
        status: kind == :invalid ? :invalid : observed.fetch(locator, { status: :missing })[:status] }
    end
    sections = {
      valid_legacy_locators: locators.select { |r| r[:kind] == :legacy },
      valid_private_locators: locators.select { |r| r[:kind] == :private },
      invalid_or_unknown_locators: locators.select { |r| r[:kind] == :invalid },
      missing_referenced_legacy_files: locators.select { |r| r[:kind] == :legacy && r[:status] == :missing },
      missing_referenced_private_files: locators.select { |r| r[:kind] == :private && r[:status] == :missing },
      unsafe_legacy_entries: files.select { |r| r[:kind] == :legacy && r[:status] == :unsafe },
      unsafe_private_entries: files.select { |r| r[:kind] == :private && r[:status] == :unsafe },
      shared_legacy_locators: locators.select { |r| r[:kind] == :legacy && r[:file_ids].size > 1 },
      unreferenced_legacy_files: files.select { |r| r[:kind] == :legacy && r[:status] == :present && r[:file_ids].empty? },
      unreferenced_private_files: files.select { |r| r[:kind] == :private && r[:status] == :present && r[:file_ids].empty? },
      soft_deleted_legacy_references: references.select { |r| r[:kind] == :legacy && r[:deletion_status] == :soft_deleted }
    }
    roots.each_value { |root| check_root!(root) }
    { complete: true, completeness_scope: :configured_roots_only, atomic_snapshot: false,
      started_at: started_at, finished_at: Time.now.utc, read_only: true,
      physical_deletion_enabled: false,
      soft_deletion_column_present: deleted_column,
      legacy_reads_enabled: configuration.legacy_reads_enabled,
      references: references, locators: locators, entries: files, classifications: sections,
      counts: { references: references.size, unique_locators: locators.size,
                legacy_references: references.count { |r| r[:kind] == :legacy },
                private_references: references.count { |r| r[:kind] == :private },
                invalid_references: references.count { |r| r[:kind] == :invalid },
                classifications: sections.transform_values(&:size) } }
  rescue StandardError
    # Discard partial results and suppress path/ID-bearing exception causes.
    raise Failure, "Legacy document inventory failed; report incomplete", cause: nil
  end

  private

  def locator_kind(locator)
    return :invalid unless locator.is_a?(String) && locator.valid_encoding? && locator.bytesize <= 255
    return :invalid unless locator.ascii_only? && !locator.include?("..")
    return :legacy if locator.match?(/\AuserFiles\/[a-zA-Z0-9][a-zA-Z0-9_. -]*\z/)
    return :private if locator.match?(/\AprivateDocuments\/[a-zA-Z0-9][a-zA-Z0-9_. -]*\z/)

    :invalid
  end

  def check_root!(root)
    path = Pathname(root)
    raise Failure unless path.absolute? && path == path.cleanpath

    # Inspect from / downwards so even ancestor checks do not cross a symlink.
    path.ascend.to_a.reverse_each do |component|
      stat = File.lstat(component)
      raise Failure unless stat.directory? && !stat.symlink?
      raise Failure if (stat.mode & 0o444).zero? || (stat.mode & 0o111).zero?
    end
  end
end
