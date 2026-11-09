require "rack/utils"
require "pathname"

# Protects requests reaching Rack, before Rails can serve public files.
# Upstream static servers and caches need their own deny rules.
class LegacyDocumentAccessBlocker
  def initialize(app)
    @app = app
  end

  def call(env)
    return denied if legacy_path?(env.fetch("PATH_INFO", ""))

    @app.call(env)
  end

  private

  def legacy_path?(path)
    # Match the decoded, normalized path used by static file servers. Check
    # before normalization too, so traversal out of this namespace is denied.
    decoded = Rack::Utils.unescape_path(path).tr("\\", "/")
    [decoded, Pathname.new("/" + decoded).cleanpath.to_s].any? do |candidate|
      candidate.match?(%r{\A/+userFiles(?:/|\z)}i)
    end
  rescue ArgumentError
    true
  end

  def denied
    [404, { "content-type" => "text/plain", "cache-control" => "private, no-store" }, ["Not found"]]
  end
end
