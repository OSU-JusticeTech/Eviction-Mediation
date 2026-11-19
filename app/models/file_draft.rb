class FileDraft < ApplicationRecord
  self.table_name  = "FileDrafts"
  self.primary_key = 'FileID'

  has_many :file_attachments, foreign_key: :FileID
  has_many :messages, through: :file_attachments

  after_update_commit :notify_agreement_update

  def self.find_viewable_by(user, id)
    return unless user

    scope = FileDraft.where(FileID: id)
    scope = scope.where(UserDeletedAt: nil) if FileDraft.column_names.include?("UserDeletedAt")

    file = scope.first
    return unless file
    return file if file.CreatorID == user[:UserID]

    attachments = FileAttachment.where(FileID: file.FileID)
    return unless attachments.exists?

    message_ids = attachments.select(:MessageID)
    messages = Message.where(MessageID: message_ids)

    # Check if user is a direct participant (sender or recipient)
    message_table = Message.arel_table
    participant_condition = message_table[:SenderID].eq(user[:UserID])
                             .or(message_table[:recipientID].eq(user[:UserID]))

    return file if messages.where(participant_condition).exists?

    # Check if user is a mediator or other party in the conversation
    conversation_ids = messages.pluck(:ConversationID).uniq
    # Role is authoritative even if inconsistent historical group rows overlap.
    # Include retired conversations so historical documents remain viewable.
    MessageString.where(ConversationID: conversation_ids).each do |conversation|
      case conversation.Role
      when "Primary"
        pmg = PrimaryMessageGroup.find_by(ConversationID: conversation.ConversationID)
        next unless pmg

        return file if pmg.LandlordID == user[:UserID]
        return file if pmg.TenantID == user[:UserID]
        return file if pmg.MediatorID == user[:UserID]
      when "Side"
        smg = SideMessageGroup.find_by(ConversationID: conversation.ConversationID)
        next unless smg

        return file if smg.UserID == user[:UserID]
        return file if smg.MediatorID == user[:UserID]
      end
    end

    nil
  end

  # Size of the stored file, e.g. "245 KB". nil if the file can't be read.
  def human_file_size
    size = DocumentStorage.configured.resolve(self.FileURLPath).size
    ActiveSupport::NumberHelper.number_to_human_size(size)
  rescue StandardError
    nil
  end

  def agreement_terms
    return {} unless has_attribute?(:AgreementTerms)
    terms = JSON.parse(self[:AgreementTerms].presence || "{}")
    return {} unless terms.is_a?(Hash)
    return terms unless revised_move_out? && terms["move_out_schedule"].present?

    # Pending proposals created against the old schedule must still apply to that field.
    if agreement_suggestions_pending? && agreement_proposal.fetch("changes").key?("move_out_schedule")
      return terms
    end
    MoveOutTerms.structured_schedule(terms)
  rescue JSON::ParserError
    {}
  end

  def agreement_proposal
    return {} unless has_attribute?(:AgreementProposal)
    proposal = JSON.parse(self[:AgreementProposal].presence || "{}")
    proposal.is_a?(Hash) ? proposal : {}
  rescue JSON::ParserError
    {}
  end

  def agreement_suggestions_pending?
    proposal = agreement_proposal
    proposal["base_version"].to_i == self[:AgreementVersion].to_i &&
      proposal["changes"].is_a?(Hash) &&
      proposal["changes"].values.any? { |change| change.is_a?(Hash) && change["decision"] == "pending" }
  end

  def agreement_suggestion_items
    proposal = agreement_proposal
    changes = proposal["changes"]
    return [] unless changes.is_a?(Hash)

    terms = agreement_terms
    grouped = {}
    (revised_move_out? ? [] : (1..6)).each do |number|
      amount_key = "amount#{number}"
      date_key = "date#{number}"
      amount = changes[amount_key]
      date = changes[date_key]
      next if self[:AgreementTemplate] == "b" && amount.is_a?(Hash) && PayAndStayTerms::REVIEW_GROUPS.key?(amount["group_key"])

      grouped_payment = amount.is_a?(Hash) && amount["group_key"] == "payment#{number}"
      added_payment = amount.is_a?(Hash) && amount["from"].blank? && amount["to"].present?
      removed_payment = amount.is_a?(Hash) && amount["from"].present? && amount["to"].blank? &&
                        (date ? date["to"] : terms[date_key]).blank?
      next unless grouped_payment || added_payment || removed_payment

      decisions = [amount["decision"], date&.dig("decision")].compact
      next if decisions.uniq.length > 1
      offerers = [amount["offered_by_id"] || proposal["proposer_id"],
                  (date["offered_by_id"] || proposal["proposer_id"] if date)].compact
      next if offerers.uniq.length > 1

      grouped[amount_key] = {
        key: "payment#{number}", fields: [amount_key, (date_key if date)].compact,
        payment_group: true, added_payment: added_payment,
        removed_payment: amount["to"].blank? && (date ? date["to"] : terms[date_key]).blank?,
        offered_by_id: amount["offered_by_id"] || proposal["proposer_id"],
        change: { "from_amount" => amount["from"], "from_date" => date ? date["from"] : terms[date_key],
                  "to_amount" => amount["to"], "to_date" => date ? date["to"] : terms[date_key],
                  "decision" => decisions.uniq.length == 1 ? decisions.first : "pending" }
      }
      grouped[date_key] = :skip if date
    end

    group_keys = if custom_resolution?
      changes.values.pluck("group_key").compact.uniq
    elsif revised_move_out?
      MoveOutTerms::GROUPS.keys
    elsif self[:AgreementTemplate] == "b"
      PayAndStayTerms::REVIEW_GROUPS.keys
    else
      []
    end
    group_keys.each do |key|
      fields = changes.keys.select { |field| changes[field]["group_key"] == key }
      next if fields.empty?

      first, *rest = fields
      change = changes.fetch(first)
      grouped[first] = { key: key, fields: fields, terms_group: true,
                         offered_by_id: change["offered_by_id"] || proposal["proposer_id"], change: change }
      rest.each { |field| grouped[field] = :skip }
    end

    changes.filter_map do |field, change|
      item = grouped[field]
      next if item == :skip
      item || { key: field, fields: [field], payment_group: false, added_payment: false, removed_payment: false,
                offered_by_id: change["offered_by_id"] || proposal["proposer_id"], change: change }
    end
  end

  def agreement_document?
    has_attribute?(:AgreementTemplate) && self[:AgreementTemplate].present? &&
      has_attribute?(:AgreementVersion) && self[:AgreementVersion].present? &&
      agreement_conversation_id.present?
  end

  def custom_resolution?
    has_attribute?(:AgreementTemplate) && self[:AgreementTemplate] == CustomResolutionTerms::TEMPLATE
  end

  def revised_move_out?
    has_attribute?(:AgreementTemplate) && self[:AgreementTemplate] == MoveOutTerms::TEMPLATE
  end

  def revised_pay_and_stay?
    has_attribute?(:AgreementTemplate) && self[:AgreementTemplate] == "b" &&
      PayAndStayTerms.revised?(agreement_terms)
  end

  def additional_pay_and_stay_signers?
    revised_pay_and_stay? && PayAndStayTerms.additional_signer_names(agreement_terms["additional_signature_parties"]).any?
  end

  def agreement_fully_executed?
    self[:LandlordSignature] && self[:TenantSignature] && !additional_pay_and_stay_signers? &&
      (!custom_resolution? || agreement_terms["cr_additional_signers"] == "no")
  end

  def agreement_signable?
    return false if custom_resolution? && agreement_terms["cr_additional_signers"] != "no"

    !has_attribute?(:AgreementTemplate) || self[:AgreementTemplate].blank? || agreement_document?
  end

  def agreement_editable?
    agreement_document? && !(self[:TenantSignature] && self[:LandlordSignature])
  end

  def agreement_conversation_id
    self[:AgreementConversationID] if has_attribute?(:AgreementConversationID)
  end

  def uploaded_at
    self[:CreatedAt] || self[:created_at] || self[:UpdatedAt] || self[:updated_at]
  end

  private

  def notify_agreement_update
    return unless agreement_document?

    tenant_signed = saved_change_to_TenantSignature? && self.TenantSignature
    landlord_signed = saved_change_to_LandlordSignature? && self.LandlordSignature
    return unless tenant_signed || landlord_signed

    conversation = PrimaryMessageGroup.find_by(ConversationID: agreement_conversation_id)
    return unless conversation && !conversation.past?

    actor = tenant_signed ? conversation.tenant : conversation.landlord
    completed = agreement_fully_executed?
    # Completion is a useful receipt for everyone; do not also send a signed email.
    recipients = if completed
      conversation.notification_participants
    else
      [ conversation.tenant, conversation.landlord ].reject { |user| user.UserID == actor.UserID }
    end
    event = completed ? "agreement_completed" : "agreement_signed"
    recipients.each do |recipient|
      MediationNotifications.agreement_notification(recipient, conversation.ConversationID, event, self.FileID, actor)
    end
  end
end
