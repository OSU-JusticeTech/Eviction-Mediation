require "bigdecimal"

module PayAndStayTerms
  CHOICES = {
    "rental_assistance" => %w[none arrangement],
    "assistance_status" => %w[not_submitted pending approved],
    "assistance_amount_status" => %w[specified unknown],
    "assistance_confirmed" => %w[yes no],
    "assistance_pending" => %w[unchanged deferred reduced other],
    "existing_eviction_case" => %w[none filed],
    "dismissal_scope" => %w[possession entire_case],
    "correction_period" => %w[none notice],
    "additional_terms_selection" => %w[none included]
  }.freeze

  REVIEW_CHOICES = CHOICES.merge(
    "unresolved_payment_issues" => %w[yes no],
    "regular_rent_arrangement" => %w[unchanged modified],
    "payment_application" => %w[standard different],
    "conditional_reduction" => %w[none conditional]
  ).freeze

  FLAGS = %w[assistance_keep_schedule assistance_alternative_schedule assistance_review
             review_payment_arrangement other_additional_terms].freeze
  AMOUNTS = %w[assistance_amount assistance_reduced_amount].freeze
  DATES = %w[assistance_deferral_date assistance_review_date payment_review_date].freeze
  COUNTS = %w[satisfaction_business_days correction_days].freeze
  MULTILINE = %w[additional_terms additional_signature_parties attachments].freeze

  PAYMENT_METHODS = {
    "online_portal" => "Online portal", "money_order" => "Money order", "cashiers_check" => "Cashier’s check",
    "personal_check" => "Personal check", "cash" => "Cash", "other" => "Other"
  }.freeze
  PAYMENT_OPTIONS = {
    "payment_lump_sum" => %w[lump_sum_amount lump_sum_date],
    "payment_monthly" => %w[monthly_payment_amount monthly_payment_months monthly_payment_day monthly_payment_start],
    "payment_final" => %w[final_payment_amount final_payment_date],
    "payment_custom_schedule" => []
  }.freeze
  CUSTOM_ROWS = (1..6).map { |i| %W[amount#{i} date#{i} time#{i}] }.freeze
  BREAKDOWN = {
    "rent_owed" => "rent_period", "late_fees" => "late_fees_description", "utilities" => "utilities_period",
    "other_charges" => "other_charges_description", "credits_amount" => "credits_description",
    "reductions_amount" => "reductions_description"
  }.freeze
  CORE_GROUPS = {
    "agreed_payment_amount" => ["money_owed", *BREAKDOWN.keys, *BREAKDOWN.values],
    "unresolved_payment_issues" => %w[unresolved_payment_issues unresolved_payment_details],
    "regular_rent_arrangement" => %w[regular_rent_arrangement regular_rent_change_details monthly_rent regular_rent_due_day],
    "additional_payments" => PAYMENT_OPTIONS.flat_map { |choice, fields| [choice, *fields] } + CUSTOM_ROWS.flatten,
    "payment_method" => %w[payment_method payment_portal_name payment_method_other_description],
    "payment_application" => %w[payment_application payment_application_instructions],
    "conditional_reduction" => %w[conditional_reduction forgiveness_amount forgiveness_deadline forgiveness_conditions
                                  forgiveness_remaining_amount forgiveness_failure_result]
  }.freeze

  GROUPS = {
    "rental_assistance" => %w[rental_assistance assistance_provider assistance_status assistance_amount_status
      assistance_amount assistance_confirmed assistance_tenant_steps assistance_landlord_steps assistance_pending
      assistance_deferral_date assistance_reduced_amount assistance_reduced_dates assistance_pending_details
      assistance_keep_schedule assistance_alternative_schedule assistance_alternative_details assistance_review
      assistance_review_date assistance_review_schedule],
    "existing_eviction_case" => %w[existing_eviction_case eviction_court eviction_case_number dismissal_scope dismissal_deadline],
    "additional_time_to_correct" => %w[correction_period correction_notice_method correction_days correction_start],
    "additional_agreement_terms" => %w[additional_terms_selection review_payment_arrangement payment_review_date
      other_additional_terms additional_terms]
  }.freeze
  PAYMENT_REVIEW_GROUPS = %w[agreed_payment_amount additional_payments conditional_reduction].freeze
  PAYMENT_REVIEW_KEY = "payment_agreement".freeze
  REVIEW_GROUPS = CORE_GROUPS.merge(GROUPS).merge(
    PAYMENT_REVIEW_KEY => PAYMENT_REVIEW_GROUPS.flat_map { |key| CORE_GROUPS.fetch(key) }
  ).freeze
  FIELDS = (GROUPS.values.flatten + %w[satisfaction_business_days additional_signature_parties attachments landlord_signer_capacity tenant_signer_capacity]).freeze
  LEGACY_ASSISTANCE_FIELDS = %w[rental_assistance assistance_provider assistance_status assistance_amount_status
    assistance_amount assistance_confirmed].freeze
  ASSISTANCE_SCHEDULE_FIELDS = %w[rental_assistance assistance_status assistance_pending assistance_deferral_date
    assistance_reduced_amount assistance_reduced_dates assistance_pending_details assistance_keep_schedule
    assistance_alternative_schedule assistance_alternative_details assistance_review assistance_review_date
    assistance_review_schedule].freeze
  ADDITIONAL_SIGNERS_NOTICE = "Additional party signatures are outstanding. This application can collect only landlord and tenant signatures. This agreement remains incomplete in the application.".freeze

  def self.revised?(terms)
    terms["pay_and_stay_draft_version"] == "1"
  end

  def self.additional_signer_names(value)
    value.to_s.lines.map(&:strip).reject { |name| name.blank? || name.casecmp?("None") }
  end

  def self.release_error(terms, previous: {})
    previous_signers = additional_signer_names(previous["additional_signature_parties"])
    if additional_signer_names(terms["additional_signature_parties"]) != previous_signers
      return "This application supports only landlord and tenant signatures. Additional required signers cannot be added or changed."
    end

    return unless terms["rental_assistance"] == "arrangement" &&
      ASSISTANCE_SCHEDULE_FIELDS.any? { |field| terms[field].to_s.strip != previous[field].to_s.strip }

    pending = terms["assistance_pending"]
    return if pending == "unchanged" && terms["assistance_keep_schedule"] == "1"

    # The overlapping clauses must agree without interpreting free-form schedules.
    if pending == "other"
      instruction = terms["assistance_pending_details"].to_s.squish
      schedules = []
      schedules << terms["assistance_alternative_details"].to_s.squish if terms["assistance_alternative_schedule"] == "1"
      schedules << terms["assistance_review_schedule"].to_s.squish if terms["assistance_review"] == "1"
      return if schedules.any? && schedules.all? { |schedule| schedule == instruction }
    end

    "Section 4 payment instructions must agree while assistance is both pending and delayed. Keep the Section 3 schedule in both selections, or use the same payment instructions in the pending and delayed selections."
  end

  def self.payment_methods(value)
    value.to_s.split(",").map(&:strip).reject(&:empty?)
  end

  def self.valid_payment_methods?(value)
    methods = payment_methods(value)
    methods.uniq == methods && methods.all? { |method| PAYMENT_METHODS.key?(method) }
  end

  def self.payment_plan_error(terms)
    invalid_option = PAYMENT_OPTIONS.keys.find { |choice| !["", "0", "1"].include?(terms[choice].to_s) }
    return "Select a valid #{invalid_option.humanize.downcase} option." if invalid_option

    selected = PAYMENT_OPTIONS.select { |choice, _| terms[choice] == "1" }
    return "Select at least one additional payment option in Section 3." if selected.empty?

    selected.each_value do |fields|
      missing = fields.find { |field| terms[field].blank? }
      return "Enter the #{missing.humanize.downcase} for the selected payment option." if missing
    end

    if selected.key?("payment_monthly") && !terms["monthly_payment_months"].to_i.positive?
      return "Enter a whole number greater than zero for the monthly payment months."
    end
    return unless selected.key?("payment_custom_schedule")

    rows = CUSTOM_ROWS.select { |fields| fields.any? { |field| terms[field].present? } }
    return "Add at least one payment to the other payment schedule." if rows.empty?

    rows.each do |amount, date, _time|
      if terms[amount].blank? || terms[date].blank?
        return "Enter both the amount and due date for custom payment #{amount.delete_prefix('amount')}."
      end
    end
    nil
  end

  def self.breakdown_error(terms)
    rows = BREAKDOWN.select { |amount, description| terms[amount].present? || terms[description].present? }
    return if rows.empty?

    rows.each do |amount, description|
      if terms[amount].blank? || terms[description].blank?
        return "Enter both the amount and period or description for #{amount.humanize.downcase} in Section 2."
      end
    end

    total = rows.keys.sum do |field|
      amount = BigDecimal(terms.fetch(field))
      %w[credits_amount reductions_amount].include?(field) ? -amount : amount
    end
    return if total == BigDecimal(terms.fetch("money_owed"))

    "The total agreed payment amount must equal the Section 2 charges minus payments, credits, and reductions."
  end

  def self.payment_total_error(terms)
    agreed_amount = BigDecimal(terms.fetch("money_owed"))
    if terms["conditional_reduction"] == "conditional"
      agreed_amount -= BigDecimal(terms.fetch("forgiveness_amount"))
      if agreed_amount.negative? || agreed_amount != BigDecimal(terms.fetch("forgiveness_remaining_amount"))
        return "The payments required after conditional forgiveness must equal the Section 2 total minus the forgiven amount."
      end
    end

    scheduled_amount = 0
    scheduled_amount += BigDecimal(terms.fetch("lump_sum_amount")) if terms["payment_lump_sum"] == "1"
    if terms["payment_monthly"] == "1"
      scheduled_amount += BigDecimal(terms.fetch("monthly_payment_amount")) * terms.fetch("monthly_payment_months").to_i
    end
    scheduled_amount += BigDecimal(terms.fetch("final_payment_amount")) if terms["payment_final"] == "1"
    if terms["payment_custom_schedule"] == "1"
      scheduled_amount += CUSTOM_ROWS.sum { |amount, _date, _time| BigDecimal(terms[amount].presence || "0") }
    end
    return if scheduled_amount == agreed_amount

    "The Section 3 payment schedule must add up to the Section 2 total after any conditional forgiveness."
  end

  def self.valid_value?(field, value)
    return true if value.blank?
    return CHOICES.fetch(field).include?(value) if CHOICES.key?(field)
    return %w[0 1].include?(value) if FLAGS.include?(field)
    return value.match?(/\A\d+(?:\.\d{1,2})?\z/) if AMOUNTS.include?(field)
    return value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value) if DATES.include?(field)
    return value.match?(/\A\d+\z/) && value.to_i.positive? if COUNTS.include?(field)

    value.length <= (MULTILINE.include?(field) ? 5000 : 255)
  rescue Date::Error
    false
  end

  def self.validation_error(terms, complete: false)
    value = ->(field) { terms[field].to_s.strip }
    present = ->(*fields) { fields.all? { |field| value.call(field).present? } }
    active = ->(*fields) { complete || fields.any? { |field| value.call(field).present? } }

    fields_to_validate = complete ? FIELDS : FIELDS - LEGACY_ASSISTANCE_FIELDS
    if fields_to_validate.any? { |field| !valid_value?(field, value.call(field)) }
      return "Enter valid Pay-and-Stay selections, dates, amounts, day counts, and text."
    end

    if active.call(*(GROUPS.fetch("rental_assistance") - LEGACY_ASSISTANCE_FIELDS))
      unless present.call("rental_assistance")
        return "Select a rental assistance option."
      end
      if value.call("rental_assistance") == "arrangement"
        unless present.call("assistance_provider", "assistance_status", "assistance_amount_status",
                            "assistance_tenant_steps", "assistance_landlord_steps", "assistance_pending")
          return "Complete the rental assistance provider, status, amount selection, steps, and pending-payment arrangement."
        end
        if value.call("assistance_amount_status") == "specified" && !present.call("assistance_amount", "assistance_confirmed")
          return "Enter the rental assistance amount and select whether it is confirmed."
        end
        pending_fields = {
          "deferred" => %w[assistance_deferral_date],
          "reduced" => %w[assistance_reduced_amount assistance_reduced_dates],
          "other" => %w[assistance_pending_details]
        }
        unless present.call(*pending_fields.fetch(value.call("assistance_pending"), []))
          return "Complete the selected pending rental assistance payment details."
        end
        if value.call("assistance_keep_schedule") == "1" && value.call("assistance_alternative_schedule") == "1"
          return "Choose either the Section 3 schedule or an alternative schedule if rental assistance is delayed, denied, or less than expected."
        end
        if FLAGS.first(3).none? { |field| value.call(field) == "1" } ||
           (value.call("assistance_alternative_schedule") == "1" && !present.call("assistance_alternative_details")) ||
           (value.call("assistance_review") == "1" && !present.call("assistance_review_date", "assistance_review_schedule"))
          return "Select and complete what applies if rental assistance is delayed, denied, or less than expected."
        end
        if value.call("assistance_review") == "1"
          if value.call("assistance_keep_schedule") == "1"
            return "Select the review option on its own and state in the interim payment field if the Section 3 schedule continues."
          end
          if value.call("assistance_alternative_schedule") == "1" &&
             value.call("assistance_review_schedule").squish != value.call("assistance_alternative_details").squish
            return "Enter matching payment terms for the alternative and interim rental assistance schedules."
          end
        end
      end
    end

    if active.call("satisfaction_business_days") && !present.call("satisfaction_business_days")
      return "Enter the number of business days for written confirmation."
    end
    if active.call(*GROUPS.fetch("existing_eviction_case")) &&
       (!present.call("existing_eviction_case") ||
         (value.call("existing_eviction_case") == "filed" &&
           !present.call("eviction_court", "eviction_case_number", "dismissal_scope", "dismissal_deadline")))
      return "Select whether an eviction case has been filed and complete the dismissal details if applicable."
    end
    if active.call(*GROUPS.fetch("additional_time_to_correct")) &&
       (!present.call("correction_period") ||
         (value.call("correction_period") == "notice" &&
           !present.call("correction_notice_method", "correction_days", "correction_start")))
      return "Select a missed-payment correction option and complete the notice and timing details if applicable."
    end
    if active.call(*(GROUPS.fetch("additional_agreement_terms") - ["additional_terms"]))
      review = value.call("review_payment_arrangement") == "1"
      other = value.call("other_additional_terms") == "1"
      case value.call("additional_terms_selection")
      when "none"
        return "Select no additional terms or select the applicable terms." if review || other
      when "included"
        unless (review || other) && (!review || present.call("payment_review_date")) && (!other || present.call("additional_terms"))
          return "Select and complete the applicable additional terms."
        end
      else
        return "Select no additional terms or select the applicable terms."
      end
    end
    return "List the attachments or enter None." if complete && !present.call("attachments")

    nil
  end
end
