require "pathname"
require "securerandom"
require "tempfile"

# Filesystem operations only: callers must authorize the record before using it.
# This service never changes records, routes, or historical file contents.
class DocumentStorage
  class Error < StandardError; end
  class InvalidLocator < Error; end
  class MissingFile < Error; end
  class Unavailable < Error; end
  class CleanupFailure < Error
    attr_reader :locator

    def initialize(locator:)
      @locator = locator
      super("Document published but staging cleanup failed")
    end
  end

  PRIVATE_PREFIX = "privateDocuments/".freeze
  LEGACY_PREFIX = "userFiles/".freeze

  def self.configured
    new(configuration: Rails.application.config.x.document_storage)
  end

  def initialize(configuration:)
    @configuration = configuration.validate!
  end

  def resolve(locator)
    root, name = location(locator)
    protect_io do
      checked_root!(root)
      path = root.join(name)
      raise InvalidLocator, "Document symlinks are not supported" if path.symlink?
      raise MissingFile, "Document not found" unless path.file?
      raise Unavailable, "Document is not readable" unless path.readable?

      path
    end
  end

  # The block may render a PDF or HTML directly into a private staging path.
  # CleanupFailure carries the completed locator if staging cleanup fails.
  # The caller owns DB coordination and removal of unreferenced new files.
  def write(extension:)
    extension = extension.to_s.delete_prefix(".").downcase
    raise InvalidLocator, "Invalid document extension" unless extension.match?(/\A[a-z0-9]{1,10}\z/)

    protect_io do
      root = @configuration.root
      checked_root!(root)
      raise Unavailable, "Document storage is not writable" unless root.writable?

      name = "#{SecureRandom.uuid}.#{extension}"
      temp = Tempfile.create([".document-", ".#{extension}"], root.to_s)
      staged = Pathname(temp.path)
      destination = root.join(name)
      published = false
      begin
        temp.close
        yield staged
        stat = staged.lstat
        unless stat.file? && stat.nlink == 1
          raise InvalidLocator, "Invalid staged document"
        end
        File.chmod(0o600, staged)
        File.open(staged, "rb") { |file| file.fsync }
        # A hard link publishes complete bytes atomically and fails if the
        # destination exists; rename would silently overwrite an existing file.
        File.link(staged, destination)
        published = true
      ensure
        original_error = $!
        temp.close unless temp.closed?
        begin
          File.unlink(staged)
        rescue Errno::ENOENT
          # Staging is already absent; no cleanup remains.
        rescue SystemCallError, IOError
          unless original_error
            raise CleanupFailure.new(locator: PRIVATE_PREFIX + name) if published

            raise
          end
        end
      end
      PRIVATE_PREFIX + name
    end
  end

  def store(io:, extension:)
    write(extension: extension) do |path|
      File.open(path, "wb") { |destination| IO.copy_stream(io, destination) }
    end
  end

  # Deliberately private-only. Legacy physical cleanup belongs to the later
  # migration/integration review. Missing files are safe to retry.
  def delete_private(locator)
    raise InvalidLocator, "Only private documents can be deleted" unless locator.is_a?(String) && locator.start_with?(PRIVATE_PREFIX)

    protect_io { File.delete(resolve(locator)) }
    true
  rescue MissingFile
    false
  end

  private

  def location(locator)
    raise InvalidLocator, "Invalid document locator" unless locator.is_a?(String) && locator.bytesize <= 255

    prefix = [PRIVATE_PREFIX, LEGACY_PREFIX].find { |candidate| locator.start_with?(candidate) }
    raise InvalidLocator, "Unknown document storage" unless prefix

    name = locator.delete_prefix(prefix)
    unless name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_. -]*\z/) && !name.include?("..")
      raise InvalidLocator, "Invalid document filename"
    end
    if prefix == LEGACY_PREFIX
      raise MissingFile, "Legacy document access is disabled" unless @configuration.legacy_reads_enabled

      [@configuration.legacy_root, name]
    else
      [@configuration.root, name]
    end
  end

  def checked_root!(root)
    # Reject symlink components, including ancestors, so containment does not
    # depend on a string prefix check. Storage directories must be operator-owned.
    root.ascend do |component|
      raise InvalidLocator, "Document storage symlinks are not supported" if component.symlink?
    end
    raise Unavailable, "Document storage is unavailable" unless root.directory?
  end

  def protect_io
    yield
  rescue SystemCallError, IOError
    raise Unavailable, "Document storage operation failed"
  end
end
