module DocumentsHelper
  AGREEMENT_MONEY_FIELDS = %w[money_owed monthly_rent rent_owed late_fees utilities other_charges
                              lump_sum_amount monthly_payment_amount final_payment_amount].freeze
  AGREEMENT_CHOICE_FIELDS = %w[payment_lump_sum payment_monthly payment_final].freeze

  def agreement_field_label(field)
    if (payment = field.match(/\A(amount|date)([1-6])\z/))
      return "Payment #{payment[2]} #{payment[1] == 'amount' ? 'amount' : 'due date'}"
    end

    { "money_owed" => "Amount Owed", "negotiation_date" => "Agreement Date",
      "best_option" => "Resolution Type", "payment_lump_sum" => "Lump sum payment",
      "payment_monthly" => "Monthly payments", "payment_final" => "Final payment" }.fetch(field, field.humanize)
  end

  def agreement_field_value(field, value)
    return value == "1" ? "Selected" : "Not selected" if AGREEMENT_CHOICE_FIELDS.include?(field)
    return "Not set" if value.blank?
    return "$#{value}" if AGREEMENT_MONEY_FIELDS.include?(field) || field.match?(/\Aamount[1-6]\z/)

    field == "payment_method" ? value.to_s.humanize : value
  end
end
