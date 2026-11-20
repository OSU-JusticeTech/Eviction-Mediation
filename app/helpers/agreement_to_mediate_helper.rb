require "ipaddr"

module AgreementToMediateHelper
  def agreement_privacy_policy_reference(preview:)
    label = "Data Privacy and Privacy Policy"
    path = resources_path(tab: "faqs", category: "data-privacy")
    origin = agreement_public_origin unless preview
    href = preview ? path : ("#{origin}#{path}" if origin)

    href ? link_to(label, href, target: "_blank", rel: "noopener") : label
  end

  private

  def agreement_public_origin
    # APP_URL is the configured public host (and optional port).
    host = ENV["APP_URL"].to_s.strip
    protocol = ENV.fetch("APP_PROTOCOL", "https")
    return unless host.present? && %w[http https].include?(protocol)

    uri = URI.parse("#{protocol}://#{host}")
    return unless uri.host.present? && uri.userinfo.nil? && uri.path.empty? && uri.query.nil? && uri.fragment.nil?

    hostname = uri.hostname.downcase.delete_suffix(".")
    return if hostname == "localhost" || hostname.end_with?(".localhost")
    if hostname.match?(/\A[\d.]+\z/) || hostname.include?(":")
      address = IPAddr.new(hostname).native
      return if address.loopback? || address.private? || address.link_local? || address.to_i.zero?
    end

    uri.to_s
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError
    nil
  end
end
