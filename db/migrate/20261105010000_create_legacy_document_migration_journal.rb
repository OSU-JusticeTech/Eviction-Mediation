class CreateLegacyDocumentMigrationJournal < ActiveRecord::Migration[8.0]
  def change
    create_table :legacy_document_migration_runs do |t|
      t.string :run_identifier, limit: 36, null: false
      t.string :source_environment, limit: 100, null: false
      t.string :status, limit: 20, null: false, default: "running"
      t.datetime :started_at, null: false
      t.datetime :completed_at
      t.bigint :candidate_count, null: false, default: 0
      t.bigint :verified_count, null: false, default: 0
      t.bigint :blocked_count, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      t.index :run_identifier, unique: true, name: "idx_legacy_runs_identifier"
      t.check_constraint "status IN ('running','completed','interrupted','failed')", name: "ck_legacy_run_status"
      t.check_constraint "(status = 'running' AND completed_at IS NULL) OR (status <> 'running' AND completed_at IS NOT NULL AND completed_at >= started_at)", name: "ck_legacy_run_times"
      t.check_constraint "candidate_count >= 0 AND verified_count >= 0 AND blocked_count >= 0", name: "ck_legacy_run_counts"
      t.check_constraint "LEN(LTRIM(RTRIM(source_environment))) > 0", name: "ck_legacy_run_source"
      t.check_constraint "LEN(LTRIM(RTRIM(run_identifier))) > 0", name: "ck_legacy_run_identifier"
    end

    create_table :legacy_document_migration_attempts do |t|
      t.bigint :run_id, null: false
      # Deliberately no FK to FileDrafts: audit evidence survives hard deletion.
      t.integer :file_id, null: false
      t.string :expected_legacy_locator, limit: 500, null: false
      t.string :source_identity, limit: 200, null: false
      t.string :target_locator, limit: 500
      t.bigint :expected_size
      t.string :expected_sha256, limit: 64
      t.string :state, limit: 30, null: false, default: "planned"
      t.string :error_code, limit: 40
      t.datetime :started_at, null: false
      t.datetime :completed_at
      # Active = 0; closed = own positive attempt ID. Never nullable.
      t.bigint :reservation_key, null: false, default: 0
      t.integer :lock_version, null: false, default: 0
      # Reserved lease shape only; no worker, acquisition or takeover API yet.
      t.string :lease_token, limit: 36
      t.datetime :lease_expires_at
      t.bigint :lease_generation, null: false, default: 0
      t.index :run_id, name: "idx_legacy_attempts_run"
      t.index [:file_id, :reservation_key], unique: true, name: "idx_legacy_attempts_reservation"
      t.check_constraint "state IN ('planned','copying','published_verified','committed','verified','blocked','superseded','gone','rolled_back')", name: "ck_legacy_attempt_state"
      t.check_constraint "(state IN ('planned','copying','published_verified','committed','blocked') AND reservation_key = 0 AND completed_at IS NULL) OR (state IN ('verified','superseded','gone','rolled_back') AND reservation_key = id AND id > 0 AND completed_at IS NOT NULL)", name: "ck_legacy_attempt_reservation"
      t.check_constraint "completed_at IS NULL OR completed_at >= started_at", name: "ck_legacy_attempt_times"
      t.check_constraint "expected_size IS NULL OR expected_size >= 0", name: "ck_legacy_attempt_size"
      t.check_constraint "error_code IS NULL OR error_code IN ('source_missing','source_unsafe','source_changed','target_missing','target_mismatch','database_failure','interrupted','operator_blocked')", name: "ck_legacy_attempt_error"
      t.check_constraint "expected_sha256 IS NULL OR (LEN(expected_sha256) = 64 AND expected_sha256 COLLATE Latin1_General_100_BIN2 NOT LIKE '%[^0-9a-f]%')", name: "ck_legacy_attempt_hash"
      t.check_constraint "state NOT IN ('published_verified','committed','verified') OR (target_locator IS NOT NULL AND LEN(LTRIM(RTRIM(target_locator))) > 0 AND expected_size IS NOT NULL AND expected_sha256 IS NOT NULL)", name: "ck_legacy_attempt_evidence"
      t.check_constraint "LEN(LTRIM(RTRIM(expected_legacy_locator))) > 0 AND LEN(LTRIM(RTRIM(source_identity))) > 0", name: "ck_legacy_attempt_source"
      t.check_constraint "lease_generation >= 0 AND ((lease_token IS NULL AND lease_expires_at IS NULL) OR (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND reservation_key = 0 AND lease_expires_at > started_at))", name: "ck_legacy_attempt_lease"
    end
    add_foreign_key :legacy_document_migration_attempts, :legacy_document_migration_runs,
      column: :run_id, name: "fk_legacy_attempt_run"
  end
end
