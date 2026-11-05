require "net/http"
require "json"

# Creates and deletes Zoom meetings using a Server-to-Server OAuth app.
# Without ZOOM_* credentials (dev/test) every call is a no-op returning nil.
class ZoomService
  class Error < StandardError; end

  API_BASE = "https://api.zoom.us/v2".freeze

  def configured?
    [ ENV["ZOOM_ACCOUNT_ID"], ENV["ZOOM_CLIENT_ID"], ENV["ZOOM_CLIENT_SECRET"] ].all?(&:present?)
  end

  # Returns the meeting's join_url.
  def create_meeting(topic:, start_time:, duration_minutes:)
    return nil unless configured?

    response = api_request(Net::HTTP::Post, "/users/me/meetings", {
      topic: topic,
      type: 2, # scheduled meeting
      start_time: start_time.utc.iso8601,
      duration: duration_minutes,
      settings: { join_before_host: true }
    })
    raise Error, "Zoom create failed (#{response.code}): #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)["join_url"]
  end

  # Deletes the meeting behind a join_url such as https://us02web.zoom.us/j/123456789?pwd=...
  def delete_meeting(join_url)
    return nil unless configured?

    meeting_id = join_url.to_s[%r{/j/(\d+)}, 1]
    return nil unless meeting_id

    response = api_request(Net::HTTP::Delete, "/meetings/#{meeting_id}")
    return true if response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPNotFound)

    raise Error, "Zoom delete failed (#{response.code}): #{response.body}"
  end

  private

  def api_request(request_class, path, body = nil)
    uri = URI("#{API_BASE}#{path}")
    request = request_class.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    if body
      request["Content-Type"] = "application/json"
      request.body = body.to_json
    end
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  end

  def access_token
    uri = URI("https://zoom.us/oauth/token")
    uri.query = URI.encode_www_form(grant_type: "account_credentials", account_id: ENV["ZOOM_ACCOUNT_ID"])
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(ENV["ZOOM_CLIENT_ID"], ENV["ZOOM_CLIENT_SECRET"])

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
    raise Error, "Zoom auth failed (#{response.code}): #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)["access_token"]
  end
end
