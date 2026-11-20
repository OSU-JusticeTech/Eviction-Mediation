class CustomResolutionTerms
  TEMPLATE = "custom_resolution_v1".freeze
  SIGNER_ERROR = "Additional-party signing is not supported. Only agreements requiring one landlord-side and one tenant-side signature can be generated or signed.".freeze

  YES_NO = { "no" => "No", "yes" => "Yes" }.freeze
  ISSUES = {
    repairs: "Repairs or maintenance", cleaning: "Cleaning, trash, or accumulated belongings",
    access: "Access for repairs, inspection, or services", noise: "Noise or other disturbances",
    communication: "Communication or scheduling", other: "Other"
  }.freeze

  SECTIONS = {
    cr_parties: ["Party Information", {
      landlord_name: ["Landlord / legal entity"], landlord_representative: ["Landlord authorized representative", :text, false],
      cr_landlord_capacity: ["Landlord representative capacity", :text, false],
      tenant_name: ["Tenant(s)"], tenant_representative: ["Tenant authorized representative", :text, false],
      cr_tenant_capacity: ["Tenant representative capacity", :text, false],
      address: ["Rental property (street, unit, city, Ohio, ZIP)"], negotiation_date: ["Agreement date", :date]
    }],
    cr_issue: ["1. Issue Being Resolved", ISSUES.to_h { |key, label| [:"cr_issue_#{key}", [label, :checkbox, false]] }.merge(
      cr_other_issue: ["Describe the other issue", :area, { cr_issue_other: "yes" }],
      cr_issue_details: ["Specific issue and location", :area]
    )],
    cr_disposal: ["Disposal of belongings", { cr_disposal: ["Identify items and owner's permission, or enter No disposal authorized", :area] }],
    cr_entry: ["3. Entry, If Needed", {
      cr_entry: ["Entry arrangements", { "no" => "No entry arrangements are included", "yes" => "Entry is needed" }],
      cr_entry_people: ["Purpose and people entering", :area, { cr_entry: "yes" }],
      cr_entry_schedule: ["Date/time or scheduling process", :area, { cr_entry: "yes" }],
      cr_entry_notice: ["Notice and contact method", :area, { cr_entry: "yes" }]
    }],
    cr_resolution: ["4. Resolving the Identified Issue", {
      cr_resolution: ["Issue resolved by completing the actions", :area],
      cr_eviction: ["Does this dispute involve possible eviction or termination?", YES_NO],
      cr_during: ["Landlord promise while actions are being completed, including conditions and duration", :area, { cr_eviction: "yes" }],
      cr_after: ["Landlord promise after completion, including any required action or deadline", :area, { cr_eviction: "yes" }]
    }],
    cr_delays: ["5. Delays and Missed Commitments", {
      cr_delay_method: ["Delay notification method"],
      cr_correction: ["Additional time to correct a missed commitment", { "no" => "No additional period is agreed", "yes" => "Allow additional time" }],
      cr_correction_notice: ["Correction notice method", :text, { cr_correction: "yes" }],
      cr_correction_days: ["Number of days to correct", :days, { cr_correction: "yes" }],
      cr_correction_start: ["Starting point for the correction period", :text, { cr_correction: "yes" }],
      cr_correction_action: ["Specific corrective action", :area, { cr_correction: "yes" }]
    }],
    cr_case: ["6. Existing Cases and Other Terms", {
      cr_case: ["Related court case, order, or agency notice", { "no" => "None identified", "yes" => "Related matter identified" }],
      cr_court: ["Court or agency", :text, { cr_case: "yes" }],
      cr_case_number: ["Case number", :text, { cr_case: "yes" }],
      cr_case_requirements: ["Relevant requirements", :area, { cr_case: "yes" }],
      cr_case_action: ["Who will do what and by when, or None", :area, { cr_case: "yes" }]
    }],
    cr_other_terms: ["Additional terms", {
      cr_has_other_terms: ["Additional terms", { "no" => "None", "yes" => "Specific terms agreed to by both parties" }],
      cr_other_terms: ["Specific terms", :area, { cr_has_other_terms: "yes" }]
    }],
    cr_signing: ["7. Acknowledgement and Signatures", {
      cr_additional_signers: ["Does this agreement require additional signers?", YES_NO],
      cr_additional_parties: ["Additional parties and their roles (identify anyone who must sign using the question above)", :area, false],
      cr_attachments: ["Attachments (list or enter None)", :area]
    }]
  }.freeze

  ACTION = {
    present: ["Include this action", { "yes" => "Include action", "" => "Remove action" }, false],
    actor: ["Who will act?", { "landlord" => "Landlord", "tenant" => "Tenant", "both" => "Both" }],
    tasks: ["Identify each person's task", :area, { actor: "both" }],
    kind: ["What will be done?", {
      "repair" => "Repair or arrange repair", "clean" => "Clean or remove trash",
      "belongings" => "Organize or move belongings", "access" => "Arrange access or an appointment",
      "conduct" => "Change conduct or communication", "other" => "Other"
    }],
    details: ["Action details (item and location, destination, purpose and arrangements, or specific action)", :area],
    deadline: ["Completion date", :date], time: ["Completion time (if needed)", :time, false],
    assistance: ["Assistance, supplies, or prior steps", { "no" => "None needed", "yes" => "Assistance, supplies, or prior steps needed" }],
    help_details: ["What is needed, who will provide it, and when", :area, { assistance: "yes" }],
    compensation: ["Payment, credit, or reimbursement", {
      "none" => "None", "payment" => "Payment", "credit" => "Rent credit", "reimbursement" => "Reimbursement"
    }],
    provider: ["Who will provide it", :text, { compensation: %w[payment credit reimbursement] }],
    amount: ["Amount (dollars)", :money, { compensation: %w[payment credit reimbursement] }],
    recipient: ["Recipient", :text, { compensation: %w[payment credit reimbursement] }],
    due: ["Due or credit effective date", :date, { compensation: %w[payment credit reimbursement] }],
    method: ["Payment method or how credit will be recorded", :area, { compensation: %w[payment credit reimbursement] }],
    conditions: ["Conditions or None", :area, { compensation: %w[payment credit reimbursement] }],
    confirmation: ["How will completion be confirmed?", {
      "written" => "Written confirmation from both parties", "documents" => "Agreed photos or documents",
      "review" => "Scheduled walkthrough or review", "other" => "Other"
    }],
    confirmation_date: ["Walkthrough or review date", :date, { confirmation: "review" }],
    confirmation_details: ["Details, arrangements, or observable result", :area, { confirmation: %w[documents review other] }]
  }.freeze

  FIELDS = SECTIONS.values.flat_map { |_, fields| fields.keys.map(&:to_s) }.freeze
  ACTION_FIELD = /\A(cr_action_[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})_(\w+)\z/

  def self.action_groups(keys)
    keys.filter_map do |key|
      match = ACTION_FIELD.match(key)
      match[1] if match && ACTION.key?(match[2].to_sym)
    end.uniq
  end

  def self.action_fields(group)
    ACTION.transform_keys { |key| "#{group}_#{key}" }.transform_values do |label, type, rule|
      [label, type, rule.is_a?(Hash) ? rule.transform_keys { |key| "#{group}_#{key}" } : rule]
    end
  end

  def self.groups(keys)
    SECTIONS.transform_values { |_, fields| fields.keys.map(&:to_s) }.stringify_keys.merge(
      action_groups(keys).to_h { |group| [group, action_fields(group).keys] }
    )
  end

  def self.review_groups(current, proposed)
    existing_rows = action_groups(current.keys)
    proposed_rows = action_groups(proposed.keys)
    groups = groups(current.keys | proposed.keys)
    # Replace the entire action list atomically when all existing rows are removed.
    if (existing_rows & proposed_rows).empty?
      groups["cr_actions"] = (existing_rows | proposed_rows).flat_map { |row| groups.delete(row) }
    end
    groups
  end

  def self.definition(field)
    match = ACTION_FIELD.match(field)
    return action_fields(match[1])[field] if match

    SECTIONS.each_value do |_, fields|
      return fields[field.to_sym] if fields.key?(field.to_sym)
    end
    nil
  end

  def self.active?(rule, terms)
    !rule.is_a?(Hash) || rule.all? { |field, values| Array(values).include?(terms[field.to_s]) }
  end

  def self.normalize(terms)
    normalized = terms.transform_values { |value| value.to_s.strip }
    normalized.reject do |field, value|
      spec = definition(field)
      row = ACTION_FIELD.match(field)
      value.empty? || !spec || !active?(spec[2], normalized) ||
        (row && row[2] != "present" && normalized["#{row[1]}_present"].blank?)
    end
  end

  def self.error(terms)
    return SIGNER_ERROR if terms["cr_additional_signers"] == "yes"

    rows = action_groups(terms.keys)
    return "Add at least one agreed action." if rows.empty?
    return "Select at least one issue being resolved." unless ISSUES.keys.any? { |key| terms["cr_issue_#{key}"] == "yes" }
    %w[landlord tenant].each do |role|
      name = terms["#{role}_representative"].present?
      capacity = terms["cr_#{role}_capacity"].present?
      return "Enter both the #{role} representative name and capacity, or leave both blank." if name != capacity
    end

    groups(terms.keys).each_value do |fields|
      fields.each do |field|
        label, type, rule = definition(field)
        next unless active?(rule, terms)

        value = terms[field].to_s
        required = rule != false || field.end_with?("_present")
        next if value.empty? && !required
        return "Complete #{label.downcase}." if value.empty?
        return "Enter a valid value for #{label.downcase}." unless valid_value?(value, type)
      end
    end
    nil
  end

  def self.valid_value?(value, type)
    case type
    when Hash then type.key?(value)
    when :checkbox then value == "yes"
    when :date then value.match?(/\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z/) && MoveOutTerms.date?(value)
    when :time then value.match?(/\A(?:[01][0-9]|2[0-3]):[0-5][0-9]\z/)
    when :money then value.match?(/\A[0-9]{1,9}(?:\.[0-9]{1,2})?\z/)
    when :days then value.match?(/\A[1-9][0-9]{0,5}\z/)
    else value.length <= 4_000
    end
  end
end
