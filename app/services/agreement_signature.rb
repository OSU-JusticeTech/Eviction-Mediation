# Transforms only recognized, unsigned signature/date slots. All other bytes,
# including the other party's signature, remain unchanged.
class AgreementSignature
  class Invalid < StandardError; end

  def call(original, file:, role:, name:, signed_at:)
    unless file.FileTypes.to_s.downcase.delete_prefix(".") == "html" &&
           File.extname(file.FileURLPath.to_s).downcase == ".html" &&
           (file.AgreementTemplate.blank? || %w[a b c].include?(file.AgreementTemplate))
      raise Invalid, "Unsupported agreement"
    end
    html_content = original.dup.force_encoding(Encoding::UTF_8)
    raise Invalid, "Invalid HTML encoding" unless html_content.valid_encoding?
    signed_date = signed_at.strftime("%B %d, %Y")
    escaped_signature_name = ERB::Util.html_escape(name)

    if html_content =~ /<strong>#{role}:<\/strong>\s*<span class="signature-line">/
      # Pay and Stay format
      replace_once!(html_content, /(<strong>#{role}:<\/strong>\s*<span class="signature-line">)___________(<\/span>)/m) do |match|
        "#{match[1]}/s/ #{escaped_signature_name}#{match[2]}"
      end
      replace_once!(html_content, /(<strong>#{role}:<\/strong>\s*<span class="signature-line">[^<]*<\/span>\s*<span style="margin-left: 50px;"><strong>Date:<\/strong> <span class="date-line">)___________(<\/span>)/m) do |match|
        "#{match[1]}#{signed_date}#{match[2]}"
      end
    elsif html_content =~ /<strong>#{role} Signature:<\/strong>/
      # Mediation Agreement format
      replace_once!(html_content, /(<strong>#{role} Signature:<\/strong>\s*<span class="line">)(<\/span>)/) do |match|
        "#{match[1]}/s/ #{escaped_signature_name}#{match[2]}"
      end
      replace_once!(html_content, /(<strong>#{role} Signature:<\/strong>\s*<span class="line">[^<]*<\/span>\s*<strong>Date:<\/strong> )__________/m) do |match|
        "#{match[1]}#{signed_date}"
      end
    else
      # Agree to Vacate format
      replace_once!(html_content, /(<span class="sig-underline">)(<\/span>\s*<div class="sig-label">\s*<span>#{role}<\/span>)/m) do |match|
        "#{match[1]}/s/ #{escaped_signature_name}#{match[2]}"
      end
      replace_once!(html_content, /(<span>#{role}<\/span>\s*<span style="float: right;">)Date(<\/span>)/m) do |match|
        "#{match[1]}#{signed_date}#{match[2]}"
      end
    end

    html_content
  end

  private

  def replace_once!(html, pattern)
    raise Invalid, "Missing or ambiguous signature placeholder" unless html.scan(pattern).length == 1

    html.sub!(pattern) { yield Regexp.last_match }
  end
end
