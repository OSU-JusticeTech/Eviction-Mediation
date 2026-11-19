module DocumentsHelper
  AGREEMENT_MONEY_FIELDS = %w[money_owed monthly_rent rent_owed late_fees utilities other_charges
                              lump_sum_amount monthly_payment_amount final_payment_amount credits_amount reductions_amount
                              forgiveness_amount forgiveness_remaining_amount].freeze
  AGREEMENT_CHOICE_FIELDS = PayAndStayTerms::PAYMENT_OPTIONS.keys.freeze

  def pay_and_stay_counteroffer_choices(field)
    return [["Selected", "1"], ["Not selected", "0"]] if PayAndStayTerms::FLAGS.include?(field)

    PayAndStayTerms::REVIEW_CHOICES[field]&.map { |value| [value.humanize, value] }
  end

  def custom_resolution_inline_field(field, terms)
    label, type, rule = CustomResolutionTerms.definition(field)
    input = { area: "textarea", money: "number", days: "positive-integer" }.fetch(type, type || "text")
    choices = type if type.is_a?(Hash)
    tag.span(choices&.fetch(terms[field], nil) || terms[field].presence || "___________",
             class: "value", title: label, data: {
               agreement_field: field, agreement_input: choices ? "select" : input,
               agreement_options: choices&.to_json,
               custom_required: rule != false, custom_rule: (rule.is_a?(Hash) ? rule : {}).to_json
             })
  end

  def custom_resolution_clause(terms, editor, conditions, element: :div, &block)
    selected = CustomResolutionTerms.active?(conditions, terms)
    return capture(&block) if selected && !editor
    return unless editor

    tag.public_send(element, hidden: !selected, data: { custom_clause: conditions.to_json }, &block)
  end

  def custom_resolution_group_label(field)
    return "Agreed actions" if field == "cr_actions"
    return "Agreed action" if field.start_with?("cr_action_")

    CustomResolutionTerms::SECTIONS.fetch(field.to_sym).first
  end

  def agreement_field_label(field)
    if field.start_with?("cr_") && (spec = CustomResolutionTerms.definition(field))
      return spec.first
    end
    if (payment = field.match(/\A(amount|date|time)([1-6])\z/))
      detail = { "amount" => "amount", "date" => "due date", "time" => "due time" }.fetch(payment[1])
      return "Payment #{payment[2]} #{detail}"
    end

    { "money_owed" => "Amount Owed", "agreed_payment_amount" => "Agreed payment amount",
      "payment_agreement" => "Agreed amount, payment schedule, and conditional forgiveness",
      "negotiation_date" => "Agreement Date",
      "best_option" => "Resolution Type", "payment_lump_sum" => "Lump sum payment",
      "payment_monthly" => "Monthly payments", "payment_final" => "Final payment" }.fetch(field, field.humanize)
  end

  def agreement_field_value(field, value)
    return value == "1" ? "Selected" : "Not selected" if (AGREEMENT_CHOICE_FIELDS + PayAndStayTerms::FLAGS).include?(field)
    return "Not set" if value.blank?
    if field.start_with?("cr_") && (type = CustomResolutionTerms.definition(field)&.at(1))
      return type.fetch(value, value) if type.is_a?(Hash)
      return "$#{value}" if type == :money
      return "Selected" if type == :checkbox
    end
    return "$#{value}" if (AGREEMENT_MONEY_FIELDS + PayAndStayTerms::AMOUNTS).include?(field) || field.match?(/\Aamount[1-6]\z/)

    if field == "payment_method"
      return PayAndStayTerms.payment_methods(value).map { |method| PayAndStayTerms::PAYMENT_METHODS.fetch(method, method.humanize) }.join(", ")
    end
    value
  end
end
