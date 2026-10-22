class FileDraft < ApplicationRecord
  self.table_name  = "FileDrafts"
  self.primary_key = 'FileID'

  has_many :file_attachments, foreign_key: :FileID
  has_many :messages, through: :file_attachments

  after_create_commit :notify_agreement_shared
  after_update_commit :notify_agreement_update

  def agreement_terms
    return {} unless has_attribute?(:AgreementTerms)
    JSON.parse(self[:AgreementTerms].presence || "{}")
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
    (1..6).each do |number|
      amount_key = "amount#{number}"
      date_key = "date#{number}"
      amount = changes[amount_key]
      date = changes[date_key]
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

  def agreement_signable?
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

  def notify_agreement_participants(conversation, event)
    conversation.notification_participants.each do |recipient|
      MediationMailer.agreement_notification(recipient, conversation.ConversationID, event, self.FileID).deliver_later
    end
  end

  def notify_agreement_shared
    return unless agreement_document?

    conversation = PrimaryMessageGroup.find_by(ConversationID: agreement_conversation_id)
    return unless conversation && !conversation.past?

    notify_agreement_participants(conversation, "agreement_created")
    notify_agreement_participants(conversation, "agreement_ready") unless agreement_suggestions_pending?
  end

  def notify_agreement_update
    if saved_change_to_AgreementConversationID? && agreement_conversation_id.present?
      notify_agreement_shared
      return
    end
    return unless agreement_document?

    newly_signed = (saved_change_to_TenantSignature? && self.TenantSignature) ||
                   (saved_change_to_LandlordSignature? && self.LandlordSignature)
    return unless newly_signed

    conversation = PrimaryMessageGroup.find_by(ConversationID: agreement_conversation_id)
    return unless conversation && !conversation.past?

    notify_agreement_participants(conversation, "agreement_signed")
    if self.TenantSignature && self.LandlordSignature
      notify_agreement_participants(conversation, "agreement_completed")
    end
  end
end
