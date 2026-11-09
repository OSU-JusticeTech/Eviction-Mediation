require Rails.root.join("lib/document_storage_configuration")

# This configures only the new service. Controllers continue using their existing
# storage until the separately reviewed integration step.
Rails.application.config.x.document_storage = DocumentStorageConfiguration.from_environment(
  environment: Rails.env,
  rails_root: Rails.root
)
