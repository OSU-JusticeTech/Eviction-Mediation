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
    publish_private(locator: allocate_private_locator(extension: extension)) { |path| yield path }
  end

  # Allocation creates no file and is not a reservation. Persist the returned
  # locator before publication when durable ownership evidence is required.
  def allocate_private_locator(extension:)
    extension = extension.to_s.delete_prefix(".").downcase
    raise InvalidLocator, "Invalid document extension" unless extension.match?(/\A[a-z0-9]{1,10}\z/)

    PRIVATE_PREFIX + "#{SecureRandom.uuid}.#{extension}"
  end

  # Same staging contract as write, but publishes to the exact private locator.
  # Never removes a published destination, including after caller DB failures.
  def publish_private(locator:)
    root, name = private_location(locator)
    extension = File.extname(name).delete_prefix(".")
    protect_io do
      checked_root!(root)
      raise Unavailable, "Document storage is not writable" unless root.writable?

      destination = root.join(name)
      check_destination!(destination)
      temp = Tempfile.create([".document-", ".#{extension}"], root.to_s)
      staged = Pathname(temp.path)
      published = false
      begin
        temp.close
        yield staged
        checked_root!(root)
        check_destination!(destination)
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

  # Yields a read-only binary descriptor, never a caller-provided path. The
  # descriptor remains open only for the block; callers calculate hashes there.
  def open_private(locator)
    caller_error = nil
    root, name = private_location(locator)
    protect_io do
      checked_root!(root)
      path = root.join(name)
      before = begin
        path.lstat
      rescue Errno::ENOENT
        raise MissingFile, "Document not found"
      end
      validate_private_stat!(before)
      unless File.const_defined?(:NOFOLLOW)
        raise Unavailable, "Safe document opening is unsupported"
      end
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        file.binmode
        opened = file.stat
        validate_private_stat!(opened)
        unless [before.dev, before.ino] == [opened.dev, opened.ino]
          raise InvalidLocator, "Document changed while opening"
        end
        checked_root!(root)
        current = path.lstat
        validate_private_stat!(current)
        unless [current.dev, current.ino] == [opened.dev, opened.ino]
          raise InvalidLocator, "Document changed while opening"
        end
        result = begin
          yield file
        rescue SystemCallError, IOError => error
          # protect_io translates storage failures, but caller failures retain
          # their original type and identity.
          caller_error = error
          raise
        end
        checked_root!(root)
        current = path.lstat
        validate_private_stat!(current)
        unless [current.dev, current.ino] == [opened.dev, opened.ino]
          raise InvalidLocator, "Document changed during inspection"
        end
        result
      end
    end
  rescue Unavailable
    raise caller_error if caller_error

    raise
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

  # Inventory only: enumerate immediate entries without reading bytes or walking
  # directories/symlinks. Never expose a deletion candidate API from this scan.
  def private_inventory_entries
    protect_io do
      checked_root!(@configuration.root)
      @configuration.root.children.map do |path|
        locator = PRIVATE_PREFIX + path.basename.to_s
        [locator, private_inventory_status(locator)]
      end
    end
  end

  def private_inventory_status(locator)
    unless locator.is_a?(String) && locator.start_with?(PRIVATE_PREFIX)
      raise InvalidLocator, "Only private documents can be inventoried"
    end
    root, name = location(locator)
    protect_io do
      checked_root!(root)
      stat = begin
        root.join(name).lstat
      rescue Errno::ENOENT
        return :missing
      end
      stat.file? && stat.nlink == 1 ? :present : :unsafe
    end
  rescue InvalidLocator
    :unsafe
  end

  private

  def private_location(locator)
    unless locator.is_a?(String) && locator.start_with?(PRIVATE_PREFIX)
      raise InvalidLocator, "Only private document locators are supported"
    end
    location(locator)
  end

  def validate_private_stat!(stat)
    unless stat.file? && stat.nlink == 1 && (stat.mode & 0o7777) == 0o600
      raise InvalidLocator, "Unsafe private document"
    end
  end

  def check_destination!(path)
    stat = path.lstat
    raise InvalidLocator, "Unsafe private destination" unless stat.file? && stat.nlink == 1
    # Existing regular files are left for the exclusive link to reject.
  rescue Errno::ENOENT
    nil
  end

  def location(locator)
    raise InvalidLocator, "Invalid document locator" unless locator.is_a?(String) && locator.valid_encoding? && locator.ascii_only? && locator.bytesize <= 255

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
    root.ascend.to_a.reverse_each do |component|
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
