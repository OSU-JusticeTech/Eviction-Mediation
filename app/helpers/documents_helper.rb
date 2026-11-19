module DocumentsHelper
  AGREEMENT_MONEY_FIELDS = %w[money_owed monthly_rent rent_owed late_fees utilities other_charges
                              lump_sum_amount monthly_payment_amount final_payment_amount credits_amount reductions_amount
                              forgiveness_amount forgiveness_remaining_amount].freeze
  AGREEMENT_CHOICE_FIELDS = PayAndStayTerms::PAYMENT_OPTIONS.keys.freeze

  def pay_and_stay_counteroffer_choices(field)
    return [["Selected", "1"], ["Not selected", "0"]] if PayAndStayTerms::FLAGS.include?(field)

    PayAndStayTerms::REVIEW_CHOICES[field]&.map { |value| [value.humanize, value] }
  end

  def agreement_field_label(field)
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
    return "$#{value}" if (AGREEMENT_MONEY_FIELDS + PayAndStayTerms::AMOUNTS).include?(field) || field.match?(/\Aamount[1-6]\z/)

    if field == "payment_method"
      return PayAndStayTerms.payment_methods(value).map { |method| PayAndStayTerms::PAYMENT_METHODS.fetch(method, method.humanize) }.join(", ")
    end
    value
  end
end
