class MoveOutTerms
  TEMPLATE = "move_out_v1".freeze
  NO_ADDITIONAL_SIGNERS = "none".freeze
  ADDITIONAL_SIGNERS_ERROR = "Additional required parties: This application can collect only landlord and tenant signatures.".freeze
  REQUIRED = %w[landlord_name tenant_name address negotiation_date reason vacate_date
                move_out_time possession_notice case_status case_conditions deposit_choice
                move_out_payment additional_choice attachments].freeze
  CHOICES = {
    "case_status" => %w[unfiled filed],
    "case_conditions" => %w[none specific],
    "deposit_choice" => %w[none specific],
    "move_out_payment" => %w[none unresolved payment forgiveness both],
    "forgiveness_conditions_choice" => %w[none specific],
    "forgiveness_scope" => %w[all specific],
    "additional_choice" => %w[none specific]
  }.freeze
  INSTRUCTIONS = %w[key_return belongings cleaning walkthrough].freeze
  METHODS = %w[portal money_order check cash other].freeze
  METHOD_FIELDS = METHODS.map { |method| "move_out_method_#{method}" }.freeze
  DATES = %w[negotiation_date vacate_date forgiveness_cutoff].freeze
  COUNTS = %w[dismissal_days payment_confirmation_days forgiveness_confirmation_days].freeze
  PAYMENT_ROWS = PayAndStayTerms::CUSTOM_ROWS
  ROW_FIELDS = PAYMENT_ROWS.flatten.freeze
  GROUPS = {
    "landlord_representation" => %w[landlord_representative landlord_capacity],
    "tenant_representation" => %w[tenant_representative tenant_capacity],
    "move_out_deadline" => %w[vacate_date move_out_time possession_notice],
    "move_out_case" => %w[case_status move_out_court move_out_case_number dismissal_scope dismissal_days
                          case_conditions case_conditions_details],
    "move_out_financial_terms" => %w[deposit_choice deposit_details move_out_payment payment_issue
      move_out_amount move_out_schedule payment_confirmation_days forgiveness_conditions_choice
      forgiveness_conditions_details forgiveness_scope forgiveness_cutoff forgiveness_charges
      forgiveness_confirmation_days remaining_charges forgiveness_deposit_treatment
      move_out_portal check_type other_method move_out_recipient] + METHOD_FIELDS + ROW_FIELDS,
    "move_out_additional_terms" => %w[additional_choice additional_terms]
  }.freeze
  FIELDS = (REQUIRED + GROUPS.values.flatten + INSTRUCTIONS +
    %w[landlord_representative landlord_capacity tenant_representative tenant_capacity
       move_out_additional_signers]).uniq.freeze
  TIME = /\A(?:[01]\d|2[0-3]):[0-5]\d\z/
  MONEY = /\A\d+(?:\.\d{1,2})?\z/

  def self.payment?(terms)
    %w[payment both].include?(terms["move_out_payment"])
  end

  def self.forgiveness?(terms)
    %w[forgiveness both].include?(terms["move_out_payment"])
  end

  def self.rows(value)
    value.to_s.lines.filter_map do |line|
      next if line.strip.empty?

      line.strip.split(/\s*\|\s*/, -1)
    end
  end

  def self.date?(value)
    value.match?(/\A(?!0000)\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value, Date::GREGORIAN)
  rescue Date::Error
    false
  end

  def self.value_valid?(field, value)
    return false if value.length > (field == "move_out_schedule" ? 30_000 : 5_000)
    return !REQUIRED.include?(field) if value.empty?
    return CHOICES.fetch(field).include?(value) if CHOICES.key?(field)
    return value == "yes" if METHOD_FIELDS.include?(field)
    return date?(value) if DATES.include?(field) || field.match?(/\Adate[1-6]\z/)
    return value.match?(TIME) if field == "move_out_time" || field.match?(/\Atime[1-6]\z/)
    return value.match?(MONEY) if field == "move_out_amount" || field.match?(/\Aamount[1-6]\z/)
    return value.match?(/\A[1-9]\d*\z/) if COUNTS.include?(field)
    if field == "move_out_schedule"
      return rows(value).all? do |row|
        amount, date, time = row
        (2..3).cover?(row.size) && amount.match?(MONEY) && date?(date) &&
          (time.to_s.empty? || time.match?(TIME))
      end
    end

    true
  end

  # The same rules drive the editor's completion count and server validation.
  FILED_CASE_FIELDS = %w[move_out_court move_out_case_number dismissal_scope dismissal_days].freeze
  CONDITIONAL_FIELDS = [
    [FILED_CASE_FIELDS, { "case_status" => ["filed"] }],
    [%w[case_conditions_details], { "case_conditions" => ["specific"] }],
    [%w[deposit_details], { "deposit_choice" => ["specific"] }],
    [%w[additional_terms], { "additional_choice" => ["specific"] }],
    [%w[payment_issue move_out_amount payment_confirmation_days move_out_recipient],
      { "move_out_payment" => %w[payment both] }],
    [%w[move_out_portal], { "move_out_payment" => %w[payment both], "move_out_method_portal" => ["yes"] }],
    [%w[check_type], { "move_out_payment" => %w[payment both], "move_out_method_check" => ["yes"] }],
    [%w[other_method], { "move_out_payment" => %w[payment both], "move_out_method_other" => ["yes"] }],
    [%w[forgiveness_conditions_choice forgiveness_scope forgiveness_confirmation_days forgiveness_deposit_treatment],
      { "move_out_payment" => %w[forgiveness both] }],
    [%w[forgiveness_conditions_details],
      { "move_out_payment" => %w[forgiveness both], "forgiveness_conditions_choice" => ["specific"] }],
    [%w[forgiveness_cutoff], { "move_out_payment" => %w[forgiveness both], "forgiveness_scope" => ["all"] }],
    [%w[forgiveness_charges], { "move_out_payment" => %w[forgiveness both], "forgiveness_scope" => ["specific"] }],
    [%w[remaining_charges], { "move_out_payment" => ["both"] }]
  ].freeze
  REPRESENTATION = %w[landlord tenant].map { |role| ["#{role}_representative", "#{role}_capacity"] }.freeze
  LABELS = {
    "move_out_court" => "court", "move_out_case_number" => "case number",
    "dismissal_scope" => "dismissal type", "dismissal_days" => "dismissal deadline in business days",
    "move_out_amount" => "agreed payment amount", "move_out_time" => "move-out deadline time"
  }.freeze

  def self.active?(terms, conditions)
    conditions.all? { |field, choices| choices.include?(terms[field]) }
  end

  def self.inactive_fields(terms)
    inactive = CONDITIONAL_FIELDS.reject { |_, conditions| active?(terms, conditions) }.flat_map(&:first)
    inactive += METHOD_FIELDS + ROW_FIELDS + ["move_out_schedule"] unless payment?(terms)
    inactive
  end

  def self.payment_rows(terms)
    PAYMENT_ROWS.each_with_index.filter_map do |fields, index|
      values = terms.values_at(*fields)
      [index + 1, values] if values.any?(&:present?)
    end
  end

  def self.structured_schedule(terms)
    legacy = terms["move_out_schedule"].to_s
    return terms if legacy.blank? || ROW_FIELDS.any? { |key| terms.key?(key) }
    parsed = rows(legacy)
    return terms unless parsed.size <= PAYMENT_ROWS.size && value_valid?("move_out_schedule", legacy)

    terms.except("move_out_schedule").merge(PAYMENT_ROWS.zip(parsed).each_with_object({}) do |(fields, values), result|
      result.merge!(fields.zip(values).to_h.compact) if values
    end)
  end

  def self.editor_rules
    { conditional: CONDITIONAL_FIELDS, representation: REPRESENTATION, methods: METHOD_FIELDS,
      rows: PAYMENT_ROWS, instructions: INSTRUCTIONS, choices: CHOICES, dates: DATES, counts: COUNTS, labels: LABELS,
      noAdditionalSigners: NO_ADDITIONAL_SIGNERS, additionalSignersError: ADDITIONAL_SIGNERS_ERROR }
  end

  def self.error(terms)
    required = REQUIRED + CONDITIONAL_FIELDS.select { |_, conditions| active?(terms, conditions) }.flat_map(&:first)
    required += REPRESENTATION.select { |fields| fields.any? { |field| terms[field].present? } }.flatten
    required.each do |field|
      label = LABELS.fetch(field) { field.humanize.downcase }
      value = terms[field].to_s
      return "Complete the #{label}." if value.blank?
      next if value_valid?(field, value)

      return "Enter the #{label} as a whole number greater than zero." if COUNTS.include?(field)
      return "Enter a valid date for #{label}." if DATES.include?(field)
      return "Enter a valid time for #{label}." if field == "move_out_time"
      return "Enter the #{label} in dollars with up to two decimal places." if field == "move_out_amount"
      return "Enter a valid value for #{label}."
    end

    if payment?(terms)
      return "Select at least one payment method." if METHOD_FIELDS.none? { |field| terms[field] == "yes" }
      error = schedule_error(terms)
      return error if error
    end

    invalid = (FIELDS - inactive_fields(terms) - ROW_FIELDS - ["move_out_schedule"]).find do |field|
      !value_valid?(field, terms[field].to_s)
    end
    return "Enter a valid value for #{invalid.humanize.downcase}." if invalid

    signers = terms["move_out_additional_signers"].to_s.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
    ADDITIONAL_SIGNERS_ERROR unless signers.empty? || signers.casecmp?(NO_ADDITIONAL_SIGNERS)
  end

  def self.schedule_error(terms)
    legacy = terms["move_out_schedule"].to_s
    if legacy.present?
      return "Enter a valid amount, due date, and optional due time on each saved payment schedule line." unless payment_rows(terms).empty? && value_valid?("move_out_schedule", legacy)
      return
    end

    rows = payment_rows(terms)
    return "Add at least one payment with an amount and due date." if rows.empty?
    rows.each do |number, (amount, date, time)|
      return "Enter a valid amount for payment #{number} in dollars with up to two decimal places." unless amount.present? && value_valid?("amount#{number}", amount)
      return "Enter a valid due date for payment #{number}." unless date?(date.to_s)
      return "Enter a valid due time for payment #{number}." if time.present? && !time.match?(TIME)
    end
    nil
  end
end
