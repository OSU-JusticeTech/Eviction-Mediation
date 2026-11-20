class AgreementToMediateTerms
  TEMPLATE = "agreement_to_mediate_v1".freeze
  REQUIRED = %w[landlord_name tenant_name address mediator_name].freeze
  FIELDS = (REQUIRED + %w[landlord_representative tenant_representative landlord_capacity tenant_capacity]).freeze

  def self.error(terms)
    return "Complete the landlord, tenant, rental property, and mediator fields." if REQUIRED.any? { |key| terms[key].blank? }
    return "Limit each field to 255 characters." if FIELDS.any? { |key| terms[key].to_s.length > 255 }
    if terms["additional_signature_parties"].present?
      "This agreement supports one landlord signature, one tenant signature, and the assigned mediator’s signature. Contact the mediator if another signature is required."
    end
  end

  def self.account_name(user)
    [user&.FName, user&.LName].compact.join(" ").squish
  end
end
