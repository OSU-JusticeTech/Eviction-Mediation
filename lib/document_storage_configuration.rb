require "pathname"

class DocumentStorageConfiguration
  class InvalidConfiguration < StandardError; end

  attr_reader :root, :legacy_root, :public_root, :legacy_reads_enabled

  def self.from_environment(environment:, rails_root:, env: ENV)
    configured_root = env["DOCUMENT_STORAGE_ROOT"]
    default_root = environment.to_s == "test" ? "tmp/document-storage" : "storage/documents"
    legacy_setting = env.fetch("DOCUMENT_LEGACY_READS_ENABLED", "true")
    unless %w[true false].include?(legacy_setting)
      raise InvalidConfiguration, "DOCUMENT_LEGACY_READS_ENABLED must be true or false"
    end

    new(root: configured_root || Pathname(rails_root).join(default_root),
        public_root: Pathname(rails_root).join("public"),
        legacy_reads_enabled: legacy_setting == "true",
        require_explicit_root: environment.to_s == "production" && configured_root.to_s.empty?)
  end

  def initialize(root:, public_root:, legacy_reads_enabled: true, require_explicit_root: false)
    @root = Pathname(root)
    @public_root = Pathname(public_root)
    @legacy_root = @public_root.join("userFiles")
    @legacy_reads_enabled = legacy_reads_enabled
    @require_explicit_root = require_explicit_root
  end

  # Validate when storage is used, not during asset compilation or application boot.
  # No directories are created here.
  def validate!
    raise InvalidConfiguration, "DOCUMENT_STORAGE_ROOT must be explicitly configured in production" if @require_explicit_root
    unless root.absolute? && public_root.absolute?
      raise InvalidConfiguration, "Document storage roots must be absolute"
    end

    private_path = canonical_path(root)
    public_path = canonical_path(public_root)
    if within?(private_path, public_path)
      raise InvalidConfiguration, "Private document storage must be outside public storage"
    end
    self
  end

  private

  def canonical_path(path)
    path = path.cleanpath
    return path.realpath if path.exist? || path.symlink?

    canonical_path(path.parent).join(path.basename)
  rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES
    raise InvalidConfiguration, "Document storage root cannot be resolved"
  end

  def within?(path, base)
    path == base || path.to_s.start_with?(base.to_s.delete_suffix(File::SEPARATOR) + File::SEPARATOR)
  end
end
