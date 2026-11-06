class AddSourceEvidenceToLegacyDocumentMigrationAttempts < ActiveRecord::Migration[8.0]
  def change
    # Never fabricate evidence or rewrite historical successes to install checks.
    reversible do |direction|
      direction.up do
        if select_value("SELECT COUNT(*) FROM legacy_document_migration_attempts WHERE state IN ('published_verified','committed','verified')").to_i.positive?
          raise ActiveRecord::MigrationError, "Successful legacy attempts require explicit source-evidence reconciliation before this migration"
        end
      end
    end

    table = :legacy_document_migration_attempts
    fields = %w[source_device source_inode source_size source_link_count
      source_mtime_seconds source_mtime_nanoseconds source_ctime_seconds source_ctime_nanoseconds]
    add_column table, :source_device, :decimal, precision: 20, scale: 0
    add_column table, :source_inode, :decimal, precision: 20, scale: 0
    add_column table, :source_size, :bigint
    add_column table, :source_link_count, :bigint
    add_column table, :source_mtime_seconds, :bigint
    add_column table, :source_mtime_nanoseconds, :integer
    add_column table, :source_ctime_seconds, :bigint
    add_column table, :source_ctime_nanoseconds, :integer

    absent = fields.map { |field| "#{field} IS NULL" }.join(" AND ")
    complete = fields.map { |field| "#{field} IS NOT NULL" }.join(" AND ")
    add_check_constraint table, "(#{absent}) OR (#{complete})", name: "ck_legacy_attempt_source_complete"
    add_check_constraint table,
      "(source_device IS NULL OR source_device BETWEEN 0 AND 18446744073709551615) AND " \
      "(source_inode IS NULL OR source_inode BETWEEN 0 AND 18446744073709551615) AND " \
      "(source_size IS NULL OR source_size >= 0) AND " \
      "(source_link_count IS NULL OR source_link_count >= 1) AND " \
      "(source_mtime_nanoseconds IS NULL OR source_mtime_nanoseconds BETWEEN 0 AND 999999999) AND " \
      "(source_ctime_nanoseconds IS NULL OR source_ctime_nanoseconds BETWEEN 0 AND 999999999)",
      name: "ck_legacy_attempt_source_values"
    add_check_constraint table, "state NOT IN ('published_verified','committed','verified') OR (#{complete})",
      name: "ck_legacy_attempt_verified_source"
    add_check_constraint table, "state <> 'planned' OR (#{absent})",
      name: "ck_legacy_attempt_planned_source"
  end
end
