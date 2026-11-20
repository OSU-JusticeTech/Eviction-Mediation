# Transforms recognized signature slots while preserving the surrounding HTML.
class AgreementSignature
  class Invalid < StandardError; end

  SLOTS = { "signature" => "signature-line", "name" => "field", "date" => "date-line" }.freeze
  MEDIATION_ROLES = %w[Landlord Tenant Mediator].freeze
  BLANK_SLOT = "___________"

  # Older signing requests could publish a preview without recording the signer.
  # Only stored signature state authorizes a populated slot.
  def clear_unrecorded_signatures(html, file:)
    MEDIATION_ROLES.reduce(html) do |result, role|
      next result if file.public_send("#{role}Signature")

      SLOTS.reduce(result) do |source, (slot, css_class)|
        source.gsub(/(<span class="#{css_class}" data-signature-slot="#{role}-#{slot}">)[^<]*(<\/span>)/) do
          "#{$1}#{BLANK_SLOT}#{$2}"
        end
      end
    end
  end

  def call(original, file:, role:, name:, signed_at:)
    unless file.FileTypes.to_s.downcase.delete_prefix(".") == "html" &&
           File.extname(file.FileURLPath.to_s).downcase == ".html" &&
           (file.AgreementTemplate.blank? || [*%w[a b c], MoveOutTerms::TEMPLATE, CustomResolutionTerms::TEMPLATE, AgreementToMediateTerms::TEMPLATE].include?(file.AgreementTemplate))
      raise Invalid, "Unsupported agreement"
    end
    html_content = original.dup.force_encoding(Encoding::UTF_8)
    raise Invalid, "Invalid HTML encoding" unless html_content.valid_encoding?
    signed_date = signed_at.strftime("%B %d, %Y")
    escaped_signature_name = ERB::Util.html_escape(name)

    if file.revised_pay_and_stay? || file.revised_move_out? || file.custom_resolution? || file.agreement_to_mediate?
      html_content = clear_unrecorded_signatures(html_content, file: file) if file.agreement_to_mediate?
      values = { "signature" => "/s/ #{escaped_signature_name}", "name" => escaped_signature_name, "date" => signed_date }
      if file.revised_move_out?
        # Unsigned copies generated before capacities had defaults can still be signed.
        blank_capacity = %r{(<p>Title / capacity: )___________(</p>\s*<p>Date: <span class="date-line" data-signature-slot="#{role}-date">)}
        html_content.sub!(blank_capacity) { "#{$1}#{role}#{$2}" }
      end
      SLOTS.each do |slot, css_class|
        placeholder = file.revised_move_out? && slot == "name" ? "(?:___________|Filled when signed)" : BLANK_SLOT
        replace_once!(html_content, /(<span class="#{css_class}" data-signature-slot="#{role}-#{slot}">)#{placeholder}(<\/span>)/) do |match|
          "#{match[1]}#{values.fetch(slot)}#{match[2]}"
        end
      end
    elsif html_content =~ /<strong>#{role}:<\/strong>\s*<span class="signature-line">/
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
