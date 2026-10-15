# app/controllers/documents_controller.rb
require "fileutils"
require "pathname"
require "securerandom"
require "tempfile"
require "prawn"
require "prawn/table"

class DocumentsController < ApplicationController
  before_action :require_login
  before_action :set_user
  before_action :block_admin_document_creation, only: [
    :new, :create, :template_intake, :generate_from_intake,
    :template_preview, :intake_template_view, :generate_filled_template,
    :apply_signature, :review, :update_review, :decide_suggestion, :counteroffer_suggestion
  ]
  before_action :set_conversation_context, only: [ :intake_template_view ]


  def intake_template_view
  end

  def template_intake
    @template = params[:template]
    @template_name = case @template
    when "a" then "Agree to Vacate"
    when "b" then "Pay and Stay Agreement"
    when "c" then "Mediation Agreement"
    else "Unknown Template"
    end

    # Set default resolution type based on template
    @default_resolution = case @template
    when "a" then "Move Out"
    when "b" then "Payment Plan"
    when "c" then "Payment Plan"
    else ""
    end


    @conversation_id = params[:conversation_id]
    if @conversation_id.present?
      @conversation = PrimaryMessageGroup.find_by(ConversationID: @conversation_id)
      if @conversation
        @landlord = @conversation.landlord
        @tenant = @conversation.tenant
      end
    end
  end

  def template_preview
    @template = params[:template]
    
    
    @landlord = ""
    @tenant = ""
    @address = ""
    @date = ""
    @reason = ""
    @money_owed = ""
    @monthly_rent = ""
    @best = ""
    @vacate_date = ""
    
    
    @schedule = []

    template_file = case @template
    when "a" then "documents/templates/agree_to_vacate"
    when "b" then "documents/templates/pay_and_stay"
    when "c" then "documents/templates/mediation_agreement"
    else "documents/templates/agree_to_vacate"
    end

    render template: template_file, layout: false
  end

  def generate_from_intake
    template = %w[a b c].include?(params[:template]) ? params[:template] : "a"
    @conversation_id = params[:conversation_id]
    conversation = PrimaryMessageGroup.find_by(ConversationID: @conversation_id) if @conversation_id.present?
    if @conversation_id.present? && (!conversation || !agreement_creator?(conversation))
      return render plain: "Unauthorized", status: :forbidden
    end

    terms = agreement_terms_from_params
    assign_agreement_template_variables(template, terms)
    @template_name = agreement_template_name(template)
    template_file = agreement_template_file(template)

    html_content = render_to_string(
      template: template_file,
      layout: false
    )

    # Save as HTML file
    file_id = SecureRandom.uuid
    ext = ".html"
    dir = Rails.root.join("public", "userFiles")
    FileUtils.mkdir_p(dir)
    dest = dir.join("#{file_id}#{ext}")

    File.write(dest, html_content)

    # Create database record
    pk_name, pk_value = next_filedraft_pk_value
    attrs = {
      FileID: file_id,
      FileName: generated_document_name(template),
      FileTypes: "html",
      FileURLPath: "userFiles/#{file_id}#{ext}",
      CreatorID: @user[:UserID],
      TenantSignature: false,
      LandlordSignature: false,
      AgreementTemplate: template,
      AgreementTerms: JSON.generate(terms),
      AgreementVersion: 1
    }
    if conversation
      attrs[:AgreementConversationID] = conversation.ConversationID
    end
    attrs[pk_name] = pk_value if pk_name && pk_value

    file_draft = nil
    message = nil
    FileDraft.transaction do
      file_draft = FileDraft.create!(attrs)
      if conversation
        message = Message.create!(ConversationID: conversation.ConversationID, SenderID: @user.UserID,
                                  Contents: "A new #{@template_name} agreement is ready to review and sign. Either party can suggest changes before signing.",
                                  MessageDate: Time.current, recipientID: nil, is_system: true)
        FileAttachment.create!(MessageID: message.MessageID, FileID: file_draft.FileID)
      end
    end

    if conversation

      # Broadcast to ActionCable
      extension = File.extname(file_draft.FileURLPath.to_s).delete(".")
      attachments_payload = [ {
        file_id: file_draft.FileID,
        file_name: file_draft.FileName,
        preview_url: view_file_path(file_draft.FileID),
        download_url: download_file_path(file_draft.FileID),
        view_url: view_file_path(file_draft.FileID),
        sign_url: view_file_path(file_draft.FileID),
        tenant_signature_required: !file_draft.TenantSignature,
        landlord_signature_required: !file_draft.LandlordSignature,
        agreement_document: file_draft.agreement_document?,
        extension: extension.presence || file_draft.FileTypes
      } ]

      sender_name = [ @user[:FName], @user[:LName] ].compact.join(" ").squeeze(" ").strip
      sender_name = @user[:CompanyName].presence || @user[:Email] if sender_name.blank?

      ActionCable.server.broadcast(
        "messages_#{@conversation_id}",
        {
          message_id: message.MessageID,
          contents: message.Contents,
          sender_id: message.SenderID,
          recipient_id: message.recipientID,
          message_date: message.MessageDate.strftime("%-I:%M %p"),
          message_timestamp: message.MessageDate.to_i,
          sender_role: @user[:Role],
          sender_name: sender_name,
          attachments: attachments_payload,
          broadcast: true,
          is_system: true
        }
      )

      redirect_to message_path(@conversation_id), notice: "Agreement draft shared for review."
    else
      redirect_to documents_path, notice: "Document generated successfully."
    end
  end

  # delete files
  def destroy
    file = FileDraft.find_by(FileID: params[:id])
    return render plain: "File not found", status: :not_found unless file

    # Check if user is creator OR part of the conversation
    can_delete = file.CreatorID == @user[:UserID]

    unless can_delete

      attachments = FileAttachment.where(FileID: file.FileID)
      if attachments.exists?
        message_ids = attachments.pluck(:MessageID)
        conversation_ids = Message.where(MessageID: message_ids).pluck(:ConversationID)
        can_delete = PrimaryMessageGroup.where(ConversationID: conversation_ids)
                                        .where("LandlordID = ? OR TenantID = ?", @user[:UserID], @user[:UserID])
                                        .exists?
      end
    end

    return render plain: "Unauthorized", status: :forbidden unless can_delete

    # Delete the physical file
    delete_physical_file(file)

    # Delete file attachments (removes from chat)
    FileAttachment.where(FileID: file.FileID).destroy_all

    if FileDraft.column_names.include?("UserDeletedAt")
      file.update!(UserDeletedAt: Time.current)
    else
      file.destroy!
    end

    redirect_to documents_path, notice: "Document deleted."
  end

  def index
    scope = FileDraft.where(CreatorID: @user[:UserID])


    user_conversations = PrimaryMessageGroup.where("LandlordID = ? OR TenantID = ?", @user[:UserID], @user[:UserID])
    conversation_ids = user_conversations.pluck(:ConversationID)

    if conversation_ids.any?

      message_ids = Message.where(ConversationID: conversation_ids).pluck(:MessageID)


      conversation_file_ids = FileAttachment.where(MessageID: message_ids).pluck(:FileID)


      scope = FileDraft.where("CreatorID = ? OR FileID IN (?)", @user[:UserID], conversation_file_ids)
    end

    scope = scope.where(UserDeletedAt: nil) if FileDraft.column_names.include?("UserDeletedAt")

    @files =
      if FileDraft.column_names.include?("created_at")
        scope.order(created_at: :desc)
      elsif FileDraft.column_names.include?("CreatedAt")
        scope.order(Arel.sql("[CreatedAt] DESC"))
      elsif FileDraft.column_names.include?("UpdatedAt")
        scope.order(Arel.sql("[UpdatedAt] DESC"))
      else
        scope.order(Arel.sql("[FileID] DESC"))
      end
  end

  def new; end

  # Upload handler
  def create
    uploaded = params[:file] || params.dig(:document, :file)
    unless uploaded
      redirect_to new_document_path, alert: "Please choose a file to upload." and return
    end

    ext = File.extname(uploaded.original_filename).downcase
    allowed = %w[
      .pdf .doc .docx .txt .csv .xlsx .xls .ppt .pptx .rtf
      .png .jpg .jpeg .gif .bmp .tiff .heic
      .zip .rar .7z .json .xml .md .mp3 .mp4 .wav .mov .avi
    ]
    unless allowed.include?(ext)
      redirect_to new_document_path, alert: "Unsupported file type (#{ext})." and return
    end
    if uploaded.size.to_i > 25.megabytes
      redirect_to new_document_path, alert: "File too large (max 25 MB)." and return
    end

    file_id = SecureRandom.uuid
    dir = Rails.root.join("public", "userFiles")
    FileUtils.mkdir_p(dir)
    dest = dir.join("#{file_id}#{ext}")
    File.open(dest, "wb") { |f| f.write(uploaded.read) }
    pk_name, pk_value = next_filedraft_pk_value

    sanitized_filename = File.basename(uploaded.original_filename)
    attrs = {
      FileID:       file_id,
      FileName:     File.basename(sanitized_filename, ".*"),
      FileTypes:    ext.delete("."),
      FileURLPath:  "userFiles/#{file_id}#{ext}",
      CreatorID:    @user[:UserID],
      TenantSignature: true,
      LandlordSignature: true
    }
    attrs[pk_name] = pk_value if pk_name && pk_value

    FileDraft.create!(attrs)

    redirect_to documents_path, notice: "File uploaded."
  end

  def show
    @file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless @file

    @agreement_proposal = @file.agreement_proposal if @file.agreement_document?
    @proposal_author = User.find_by(UserID: @agreement_proposal["proposer_id"]) if @agreement_proposal.present?

    # Load conversation if document is linked to one
    if @file.agreement_conversation_id.present?
      @conversation = agreement_conversation(@file)
    else
      file_attachment = FileAttachment.find_by(FileID: @file.FileID)
      message = Message.find_by(MessageID: file_attachment.MessageID) if file_attachment
      @conversation = PrimaryMessageGroup.find_by(ConversationID: message.ConversationID) if message
    end
    if @conversation
      @landlord = User.find_by(UserID: @conversation.LandlordID)
      @tenant = User.find_by(UserID: @conversation.TenantID)

      # Determine if current user can sign
      @user_role_in_conversation = if @user.UserID == @conversation.LandlordID
        "landlord"
      elsif @user.UserID == @conversation.TenantID
        "tenant"
      else
        nil
      end
    end
    if @agreement_proposal.present?
      offerer_ids = @file.agreement_suggestion_items.map { |item| item[:offered_by_id].to_i }.uniq
      @offer_authors = User.where(UserID: offerer_ids).index_by(&:UserID)
      @reviewer_id = active_agreement_reviewer_id(@file, @agreement_proposal, @conversation) if @conversation && @file.agreement_suggestions_pending?
    end

  end

  def review
    @file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless @file

    @conversation = agreement_conversation(@file)
    return render plain: "Unauthorized", status: :forbidden unless @conversation && agreement_party?(@conversation)
    return redirect_to view_file_path(@file.FileID), alert: "This agreement can no longer be changed." unless @file.agreement_editable?
    return redirect_to view_file_path(@file.FileID), alert: "Review the pending suggestions before proposing more changes." if @file.agreement_suggestions_pending?

    setup_agreement_intake(@file, @conversation)
    @review_file = @file
    render :template_intake
  end

  def update_review
    file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless file

    conversation = agreement_conversation(file)
    return render plain: "Unauthorized", status: :forbidden unless conversation && agreement_party?(conversation)
    return redirect_to view_file_path(file.FileID), alert: "This agreement can no longer be changed." unless file.agreement_editable?

    terms = agreement_terms_from_params
    result = nil
    file.with_lock do
      if !file.agreement_editable? || file.agreement_suggestions_pending? || params[:agreement_version].to_i != file.AgreementVersion
        result = :stale
      else
        current = file.agreement_terms
        changes = agreement_fields_for_template(file.AgreementTemplate).each_with_object({}) do |field, list|
          old_value = current[field].to_s
          new_value = terms[field].to_s
          list[field] = { "from" => old_value, "to" => new_value, "decision" => "pending" } unless old_value == new_value
        end
        (1..6).each do |number|
          amount = changes["amount#{number}"]
          date = changes["date#{number}"]
          next unless amount
          adding = amount["from"].blank? && amount["to"].present?
          removing = amount["from"].present? && amount["to"].blank? &&
                     (date ? date["to"] : current["date#{number}"]).blank?
          next unless adding || removing

          amount["group_key"] = "payment#{number}"
          date["group_key"] = "payment#{number}" if date
        end
        if !valid_agreement_payment_terms?(terms)
          result = :invalid_payment
        elsif changes.any? { |field, change| !valid_agreement_counteroffer?(field, change["to"]) }
          result = :invalid
        elsif changes.empty?
          result = :unchanged
        else
          file.update!(AgreementProposal: JSON.generate({ "base_version" => file.AgreementVersion,
                                                          "proposer_id" => @user.UserID,
                                                          "reviewer_id" => other_agreement_party_id(conversation, @user.UserID),
                                                          "changes" => changes }))
          result = :submitted
        end
      end
    end
    case result
    when :submitted
      announce_agreement(conversation, "#{agreement_actor_name} suggested changes to the agreement. Review the document to see them.")
      ActionCable.server.broadcast("document_#{file.FileID}", { type: "agreement_proposal_update", actor_id: @user.UserID })
      redirect_to view_file_path(file.FileID), notice: "Suggested changes sent for review."
    when :unchanged
      redirect_to view_file_path(file.FileID), notice: "No terms were changed."
    when :invalid
      redirect_to review_document_path(file.FileID), alert: "One or more edited values are invalid. Review the document and try again."
    when :invalid_payment
      redirect_to review_document_path(file.FileID), alert: "A payment date needs a payment amount. Add an amount or remove the date."
    else
      redirect_to view_file_path(file.FileID), alert: "This agreement changed while you were editing. Review the latest version."
    end
  end

  def decide_suggestion
    file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless file

    conversation = agreement_conversation(file)
    return render plain: "Unauthorized", status: :forbidden unless conversation && agreement_party?(conversation)

    decision = params[:decision].to_s
    return render plain: "Invalid decision", status: :unprocessable_entity unless %w[accepted rejected].include?(decision)

    result = nil
    completed_round = nil
    file.with_lock do
      proposal = file.agreement_proposal
      changes = proposal["changes"] || {}
      item = file.agreement_suggestion_items.find { |suggestion| suggestion[:key] == params[:field].to_s }
      if !file.agreement_editable? || !file.agreement_suggestions_pending? ||
         proposal["base_version"].to_i != file.AgreementVersion || item.nil? ||
         active_agreement_reviewer_id(file, proposal, conversation) != @user.UserID ||
         item[:offered_by_id].to_i == @user.UserID ||
         item[:fields].any? { |field| changes[field]["decision"] != "pending" }
        result = :unavailable
      else
        proposal.fetch("draft_counteroffers", {}).delete(item[:key])
        if decision == "accepted"
          accepted_terms = file.agreement_terms.dup
          item[:fields].each do |field|
            change = changes[field]
            if change["to"].present?
              accepted_terms[field] = change["to"]
            else
              accepted_terms.delete(field)
            end
          end
          if valid_agreement_payment_terms?(accepted_terms)
            item[:fields].each { |field| changes[field]["decision"] = decision }
            assign_agreement_template_variables(file.AgreementTemplate, accepted_terms)
            html = render_to_string(template: agreement_template_file(file.AgreementTemplate), formats: [:html], layout: false)
            file.AgreementTerms = JSON.generate(accepted_terms)
            file.AgreementVersion += 1
            file.TenantSignature = false
            file.LandlordSignature = false
            file.TenantSignedAt = nil
            file.LandlordSignedAt = nil
            file.TenantSignatureName = nil
            file.LandlordSignatureName = nil
            proposal["base_version"] = file.AgreementVersion
            proposal["round_accepted"] = true
            file.AgreementProposal = JSON.generate(proposal)
            replace_agreement_html(file, html)
            completed_round = finish_agreement_review_round(file, proposal, conversation)
            result = :updated
          else
            result = :invalid_payment
          end
        else
          item[:fields].each { |field| changes[field]["decision"] = decision }
          file.update!(AgreementProposal: JSON.generate(proposal))
          completed_round = finish_agreement_review_round(file, proposal, conversation)
          result = completed_round ? :rejected : :pending
        end
      end
    end

    focus_path = view_file_path(file.FileID, anchor: "suggestion-#{params[:field]}")
    if completed_round
      announce_agreement(conversation, agreement_review_completion_message(completed_round, file))
    end
    case result
    when :updated
      ActionCable.server.broadcast("document_#{file.FileID}", { type: "agreement_proposal_update", actor_id: @user.UserID })
      if request.format.json?
        render json: { status: "updated", field: params[:field], decision: decision }
      else
        redirect_to focus_path, notice: "Suggestions reviewed and the agreement updated."
      end
    when :rejected
      ActionCable.server.broadcast("document_#{file.FileID}", { type: "agreement_proposal_update", actor_id: @user.UserID })
      if request.format.json?
        render json: { status: "rejected", field: params[:field], decision: decision }
      else
        redirect_to focus_path, notice: "Suggestions reviewed. No further changes are pending."
      end
    when :pending
      ActionCable.server.broadcast("document_#{file.FileID}", { type: "agreement_proposal_update", actor_id: @user.UserID })
      if request.format.json?
        render json: { status: "pending", field: params[:field], decision: decision }
      else
        redirect_to focus_path, notice: "Decision saved. Review the remaining suggestions."
      end
    when :invalid_payment
      if request.format.json?
        render json: { error: "A payment date needs a payment amount. Review the payment as a whole." }, status: :unprocessable_entity
      else
        redirect_to focus_path, alert: "A payment date needs a payment amount. Review the payment as a whole."
      end
    else
      if request.format.json?
        render json: { error: "This suggestion is no longer available. Refresh the agreement." }, status: :conflict
      else
        redirect_to view_file_path(file.FileID), alert: "This suggestion is no longer available. Refresh the agreement."
      end
    end
  end

  def counteroffer_suggestion
    file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless file

    conversation = agreement_conversation(file)
    return render plain: "Unauthorized", status: :forbidden unless conversation && agreement_party?(conversation)

    result = nil
    completed_round = nil
    file.with_lock do
      proposal = file.agreement_proposal
      item = file.agreement_suggestion_items.find { |suggestion| suggestion[:key] == params[:field].to_s }
      if !file.agreement_editable? || !file.agreement_suggestions_pending? ||
         proposal["base_version"].to_i != file.AgreementVersion ||
         active_agreement_reviewer_id(file, proposal, conversation) != @user.UserID ||
         item.nil? || item[:fields].any? { |field| proposal["changes"][field]["decision"] != "pending" } ||
         item[:offered_by_id].to_i == @user.UserID
        result = :unavailable
      else
        values = params.fetch(:counteroffer, ActionController::Parameters.new).permit(*item[:fields]).to_h
        candidate_terms = file.agreement_terms.merge(values)
        if !valid_agreement_payment_terms?(candidate_terms)
          result = :invalid_payment
        elsif item[:fields].any? { |field| !values.key?(field) || !valid_agreement_counteroffer?(field, values[field]) } ||
              item[:fields].all? { |field| values[field].to_s.strip == proposal["changes"][field]["to"].to_s }
          result = :invalid
        else
          proposal["draft_counteroffers"] ||= {}
          proposal["draft_counteroffers"][item[:key]] = values.transform_values { |value| value.to_s.strip }
          file.update!(AgreementProposal: JSON.generate(proposal))
          completed_round = finish_agreement_review_round(file, proposal, conversation)
          result = :countered
        end
      end
    end

    if completed_round
      announce_agreement(conversation, agreement_review_completion_message(completed_round, file))
      ActionCable.server.broadcast("document_#{file.FileID}", { type: "agreement_proposal_update", actor_id: @user.UserID })
    end
    message = case result
    when :countered then completed_round ? "Review sent with counteroffers." : "Counteroffer saved. Complete the remaining suggestions to send it."
    when :invalid then "Enter a different value for this counteroffer."
    when :invalid_payment then "A payment date needs a payment amount."
    else "This suggestion is no longer available. Refresh the agreement."
    end
    if request.format.json?
      render json: result == :countered ? { status: "countered", field: params[:field], round_complete: completed_round.present? } : { error: message },
             status: result == :countered ? :ok : :unprocessable_entity
    elsif [:invalid, :invalid_payment].include?(result)
      redirect_to view_file_path(file.FileID, counteroffer_error: params[:field],
                                 counteroffer_reason: ("payment" if result == :invalid_payment),
                                 anchor: "suggestion-#{params[:field]}")
    else
      redirect_to view_file_path(file.FileID, anchor: "suggestion-#{params[:field]}"),
                  (result == :countered ? { notice: message } : { alert: message })
    end
  end

  # Handle document signing
  def apply_signature
    @file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless @file

    unless @file.agreement_signable?
      return redirect_to view_file_path(@file.FileID), alert: "This agreement must be shared in a conversation before signing."
    end

    # Load conversation to verify authorization
    file_attachment = FileAttachment.find_by(FileID: @file.FileID)
    unless file_attachment || @file.agreement_conversation_id.present?
      flash[:alert] = "This document is not linked to a conversation and cannot be signed."
      return redirect_to view_file_path(@file.FileID)
    end

    message = Message.find_by(MessageID: file_attachment.MessageID) if file_attachment && @file.agreement_conversation_id.blank?
    unless message || @file.agreement_conversation_id.present?
      flash[:alert] = "Unable to locate conversation for this document."
      return redirect_to view_file_path(@file.FileID)
    end

    conversation = @file.agreement_conversation_id.present? ? agreement_conversation(@file) : PrimaryMessageGroup.find_by(ConversationID: message.ConversationID)
    unless conversation
      flash[:alert] = "Unable to locate conversation for this document."
      return redirect_to view_file_path(@file.FileID)
    end

    # Verify user is either landlord or tenant
    is_landlord = @user.UserID == conversation.LandlordID
    is_tenant = @user.UserID == conversation.TenantID

    unless is_landlord || is_tenant
      flash[:alert] = "You are not authorized to sign this document."
      return redirect_to view_file_path(@file.FileID)
    end

    signature_name = params[:signature_name]&.strip

    if signature_name.blank?
      flash[:alert] = "Please provide your name to sign the document."
      return redirect_to view_file_path(@file.FileID)
    end

    signature_result = nil
    @file.with_lock do
      if @file.agreement_suggestions_pending?
        signature_result = :suggestions_pending
      elsif @file.agreement_document? && params[:agreement_version].to_i != @file.AgreementVersion
        signature_result = :stale
      elsif (is_landlord && @file.LandlordSignature) || (is_tenant && @file.TenantSignature)
        signature_result = :already_signed
      else
        if is_landlord
          @file.LandlordSignature = true
          @file.LandlordSignedAt = Time.current
          @file.LandlordSignatureName = signature_name
        else
          @file.TenantSignature = true
          @file.TenantSignedAt = Time.current
          @file.TenantSignatureName = signature_name
        end
        @file.save!
        update_document_with_signature(@file, is_landlord, signature_name)
        signature_result = :signed
      end
    end
    if signature_result == :stale
      return redirect_to view_file_path(@file.FileID), alert: "The agreement changed before you signed. Review the latest version."
    end
    if signature_result == :suggestions_pending
      return redirect_to view_file_path(@file.FileID), alert: "Suggested changes must be accepted or rejected before signing."
    end
    if signature_result == :already_signed
      return redirect_to view_file_path(@file.FileID), notice: "You have already signed this document."
    end

    if signature_result == :signed

      # Send notification to conversation
      landlord = User.find_by(UserID: conversation.LandlordID)
      tenant = User.find_by(UserID: conversation.TenantID)

      signer_role = is_landlord ? "Landlord" : "Tenant"
      message_content = "#{signer_role} #{signature_name} has signed the document: #{@file.FileName}"

      Message.create!(
        ConversationID: conversation.ConversationID,
        SenderID: @user.UserID,
        Contents: message_content,
        MessageDate: Time.current,
        is_system: true
      )

      # Broadcast signature update via Action Cable
      ActionCable.server.broadcast(
        "document_#{@file.FileID}",
        {
          type: "signature_update",
          file_id: @file.FileID,
          landlord_signature: @file.LandlordSignature,
          landlord_signed_at: @file.LandlordSignedAt&.strftime("%B %d, %Y at %I:%M %p"),
          landlord_name: "#{landlord.FName} #{landlord.LName}",
          tenant_signature: @file.TenantSignature,
          tenant_signed_at: @file.TenantSignedAt&.strftime("%B %d, %Y at %I:%M %p"),
          tenant_name: "#{tenant.FName} #{tenant.LName}",
          both_signed: @file.LandlordSignature && @file.TenantSignature
        }
      )

      # Check if both parties have signed
      if @file.LandlordSignature && @file.TenantSignature
        flash[:success] = "Document signed successfully! Both parties have now signed this agreement."

        # Send completion notification
        Message.create!(
          ConversationID: conversation.ConversationID,
          SenderID: @user.UserID,
          Contents: "Document fully executed: #{@file.FileName} - All parties have signed.",
          MessageDate: Time.current,
          is_system: true
        )
      else
        flash[:success] = "Document signed successfully! Waiting for the other party to sign."
      end
    else
      flash[:alert] = "Failed to save signature. Please try again."
    end

    redirect_to view_file_path(@file.FileID)
  end

  # download of the stored file
  def download_or_view
    file = find_file_for_user(params[:id])
    return render plain: "File not found (record)", status: :not_found unless file

    base_path = Rails.root.join("public")
    rel_path  = Pathname.new(file.FileURLPath).cleanpath
    path      = base_path.join(rel_path)

    size = File.exist?(path) ? File.size(path) : -1
    Rails.logger.info "[DL] path=#{path} exists=#{File.exist?(path)} size=#{size}"


    unless path.to_s.start_with?(base_path.to_s) && File.exist?(path)
      return render plain: "File not found (#{path})", status: :not_found
    end
    if size <= 0
      return render plain: "Generated file is empty (#{path})", status: :unprocessable_entity
    end

    mime_type = begin
      Marcel::MimeType.for(path.to_path, extension: File.extname(path))
    rescue StandardError
      nil
    end


    disposition = "attachment"

    send_file path,
              filename: "#{file.FileName}#{File.extname(path)}",
              type: mime_type || "application/octet-stream",
              disposition: disposition
  end


  def view_inline
    file = find_file_for_user(params[:id])
    return render plain: "File not found (record)", status: :not_found unless file

    base_path = Rails.root.join("public")
    rel_path  = Pathname.new(file.FileURLPath).cleanpath
    path      = base_path.join(rel_path)

    size = File.exist?(path) ? File.size(path) : -1
    Rails.logger.info "[VIEW] path=#{path} exists=#{File.exist?(path)} size=#{size}"


    unless path.to_s.start_with?(base_path.to_s) && File.exist?(path)
      return render plain: "File not found (#{path})", status: :not_found
    end
    if size <= 0
      return render plain: "Generated file is empty (#{path})", status: :unprocessable_entity
    end

    mime_type = begin
      Marcel::MimeType.for(path.to_path, extension: File.extname(path))
    rescue StandardError
      nil
    end


    disposition = "inline"

    send_file path,
              filename: "#{file.FileName}#{File.extname(path)}",
              type: mime_type || "application/octet-stream",
              disposition: disposition
  end

  def generate_filled_template
    conv_id   = params[:conversation_id]
    landlord  = params[:landlord_name].to_s
    tenant    = params[:tenant_name].to_s
    address   = params[:address].to_s
    nego_date = begin
      (params[:negotiation_date].presence || Date.today).to_date
    rescue StandardError
      Date.today
    end
    best      = (@intake&.BestOption || params[:best_option]).to_s

    # payment schedule
    schedule = []
    params.to_unsafe_h.each do |key, value|
      next unless key.to_s =~ /\Aamount(\d+)\z/

      index = Regexp.last_match(1).to_i
      amount = value.to_s
      due_on = params["date#{index}"]
      schedule << [ index, amount, due_on ]
    end
    schedule.sort_by! { |i, _, _| i }

    additional = params[:additional_provisions].presence || "None"
    tenant_sig = params[:tenant_signature].to_s
    land_sig   = params[:landlord_signature].to_s

    file_id = SecureRandom.uuid
    ext     = ".pdf"
    dir     = Rails.root.join("public", "userFiles")
    FileUtils.mkdir_p(dir)
    dest    = dir.join("#{file_id}#{ext}")

    # Generate the PDF based on template type
    require "prawn"
    template = params[:template] || "a"
    reason = params[:reason].to_s
    money_owed = params[:money_owed].to_s
    monthly_rent = params[:monthly_rent].to_s

    Prawn::Document.generate(dest.to_s, margin: 54, page_size: "LETTER") do |pdf|
      case template
      when "a" # Agree to Vacate
        generate_vacate_agreement(pdf, landlord, tenant, address, nego_date, reason, money_owed, schedule, best)
      when "b" # Pay and Stay Agreement
        generate_pay_stay_agreement(pdf, landlord, tenant, address, nego_date, reason, money_owed, monthly_rent, schedule, best)
      when "c" # Mediation Agreement
        generate_mediation_agreement(pdf, landlord, tenant, address, nego_date, reason, money_owed, monthly_rent, schedule, best)
      else
        # Fallback to generic
        generate_generic_agreement(pdf, landlord, tenant, address, nego_date, reason, money_owed, schedule, best)
      end

      # Footer
      pdf.move_down 20
      pdf.stroke_horizontal_rule
      pdf.move_down 10

      pdf.text "Tenant Signature: ____________________________  Date: ____________", size: 10
      pdf.move_down 15
      pdf.text "Landlord Signature: ____________________________  Date: ____________", size: 10

      if conv_id.present?
        pdf.move_down 15
        pdf.text "Conversation ID: #{conv_id}", size: 8, color: "888888"
      end
    end

    pk_name, pk_value = next_filedraft_pk_value

    attrs = {
      FileID: file_id,
      FileName: generated_document_name(template),
      FileTypes: "pdf",
      FileURLPath: "userFiles/#{file_id}#{ext}",
      CreatorID: @user[:UserID],
      TenantSignature: tenant_sig.present?,
      LandlordSignature: land_sig.present?
    }
    attrs[pk_name] = pk_value if pk_name && pk_value

    FileDraft.create!(attrs)

    redirect_to documents_path, notice: "Document generated."
  end


  private

  AGREEMENT_FIELDS = %w[landlord_name tenant_name address negotiation_date reason money_owed monthly_rent
                        best_option vacate_date rent_owed late_fees utilities other_charges
                        other_charges_description payment_lump_sum lump_sum_amount lump_sum_date
                        payment_monthly monthly_payment_amount monthly_payment_months monthly_payment_day
                        monthly_payment_start payment_final final_payment_amount final_payment_date
                        payment_method payment_method_other_description additional_terms].freeze
  AGREEMENT_COMMON_FIELDS = %w[landlord_name tenant_name address negotiation_date reason money_owed
                               monthly_rent best_option].freeze

  def setup_agreement_intake(file, conversation)
    @template = file.AgreementTemplate
    @template_name = agreement_template_name(@template)
    @review_terms = file.agreement_terms
    @default_resolution = @review_terms["best_option"].presence || (@template == "a" ? "Move Out" : "Payment Plan")
    @landlord = conversation.landlord
    @tenant = conversation.tenant
  end

  def agreement_terms_from_params
    keys = AGREEMENT_FIELDS + (1..6).flat_map { |i| ["amount#{i}", "date#{i}"] }
    params.permit(*keys).to_h
  end

  def agreement_fields_for_template(template)
    case template
    when "a" then AGREEMENT_COMMON_FIELDS + ["vacate_date"] + (1..6).flat_map { |i| ["amount#{i}", "date#{i}"] }
    when "b" then AGREEMENT_COMMON_FIELDS + (AGREEMENT_FIELDS - AGREEMENT_COMMON_FIELDS - ["vacate_date"])
    else AGREEMENT_COMMON_FIELDS
    end
  end

  def valid_agreement_payment_terms?(terms)
    (1..6).all? { |number| terms["date#{number}"].blank? || terms["amount#{number}"].present? }
  end

  def other_agreement_party_id(conversation, user_id)
    conversation.TenantID == user_id ? conversation.LandlordID : conversation.TenantID
  end

  def active_agreement_reviewer_id(file, proposal, conversation)
    return proposal["reviewer_id"].to_i if proposal["reviewer_id"].present?

    first_pending = file.agreement_suggestion_items.find { |item| item[:change]["decision"] == "pending" }
    other_agreement_party_id(conversation, first_pending[:offered_by_id].to_i) if first_pending
  end

  def finish_agreement_review_round(file, proposal, conversation)
    pending = file.agreement_suggestion_items.select { |item| item[:change]["decision"] == "pending" }
    drafts = proposal.fetch("draft_counteroffers", {})
    return nil if pending.any? { |item| item[:offered_by_id].to_i != @user.UserID && !drafts.key?(item[:key]) }

    drafts.each do |key, values|
      item = pending.find { |candidate| candidate[:key] == key }
      next unless item

      item[:fields].each do |field|
        proposal["changes"][field]["to"] = values.fetch(field)
        proposal["changes"][field]["offered_by_id"] = @user.UserID
      end
    end
    accepted = proposal.delete("round_accepted") == true
    proposal.delete("draft_counteroffers")
    if proposal["changes"].values.any? { |change| change["decision"] == "pending" }
      proposal["reviewer_id"] = other_agreement_party_id(conversation, @user.UserID)
    else
      proposal.delete("reviewer_id")
    end
    file.update!(AgreementProposal: JSON.generate(proposal))
    { accepted: accepted, countered: drafts.any? }
  end

  def agreement_review_completion_message(completed_round, file)
    if completed_round[:countered]
      detail = completed_round[:accepted] ? "Agreement version #{file.AgreementVersion} includes the accepted changes. " : ""
      "#{agreement_actor_name} completed their review and sent counteroffers. #{detail}Review the document to see them."
    elsif completed_round[:accepted]
      "Agreement revised to version #{file.AgreementVersion} by #{agreement_actor_name}. Please review the new terms."
    else
      "#{agreement_actor_name} reviewed the suggested changes. No further changes are pending."
    end
  end

  def valid_agreement_counteroffer?(field, raw_value)
    value = raw_value.to_s.strip
    return false if value.length > (field == "additional_terms" ? 5000 : 255)
    return false if %w[landlord_name tenant_name address negotiation_date reason money_owed vacate_date].include?(field) && value.blank?
    return %w[1 0].include?(value) if %w[payment_lump_sum payment_monthly payment_final].include?(field)
    return value.blank? || %w[online_portal money_order cashiers_check other].include?(value) if field == "payment_method"
    return value.blank? || value.match?(/\A\d+(?:\.\d{1,2})?\z/) if field.match?(/\Aamount[1-6]\z/) ||
      %w[money_owed monthly_rent rent_owed late_fees utilities other_charges lump_sum_amount monthly_payment_amount final_payment_amount].include?(field)
    return value.blank? || (Date.iso8601(value) && true) if field.match?(/\Adate[1-6]\z/) ||
      %w[negotiation_date vacate_date lump_sum_date monthly_payment_start final_payment_date].include?(field)
    return value.blank? || (value.match?(/\A\d{1,2}\z/) && (1..31).cover?(value.to_i)) if field == "monthly_payment_day"
    return value.blank? || value.match?(/\A\d+\z/) if field == "monthly_payment_months"

    true
  rescue Date::Error
    false
  end

  def agreement_actor_name
    name = [ @user.FName, @user.LName ].compact.join(" ").squeeze(" ").strip
    name = @user.CompanyName.presence || @user.Email if name.blank?
    "#{@user.Role} #{name}"
  end

  def replace_agreement_html(file, html)
    path = Rails.root.join("public", file.FileURLPath)
    Tempfile.create(["agreement-", ".html"], path.dirname) do |temp|
      temp.write(html)
      temp.flush
      temp.chmod(File.stat(path).mode & 0o777)
      file.save!
      File.rename(temp.path, path)
    end
  end

  def agreement_template_file(template)
    { "a" => "documents/templates/agree_to_vacate",
      "b" => "documents/templates/pay_and_stay",
      "c" => "documents/templates/mediation_agreement" }.fetch(template.to_s, "documents/templates/agree_to_vacate")
  end

  def agreement_template_name(template)
    { "a" => "Agree to Vacate", "b" => "Pay and Stay Agreement",
      "c" => "Mediation Agreement" }.fetch(template.to_s, "Agreement")
  end

  def assign_agreement_template_variables(template, terms)
    @landlord = terms["landlord_name"].to_s
    @tenant = terms["tenant_name"].to_s
    @address = terms["address"].to_s
    @date = begin
      (terms["negotiation_date"].presence || Date.today).to_date.strftime("%B %d, %Y")
    rescue StandardError
      Date.today.strftime("%B %d, %Y")
    end
    @reason = terms["reason"].to_s
    @money_owed = terms["money_owed"].to_s
    @monthly_rent = terms["monthly_rent"].to_s
    @vacate_date = terms["vacate_date"] if template == "a"
    @schedule = (1..6).filter_map do |i|
      amount = terms["amount#{i}"].to_s
      [ i, amount, terms["date#{i}"] ] if amount.present?
    end
    if template == "b"
      %w[rent_owed late_fees utilities other_charges other_charges_description lump_sum_amount
         lump_sum_date monthly_payment_amount monthly_payment_months monthly_payment_day
         monthly_payment_start final_payment_amount final_payment_date payment_method
         payment_method_other_description additional_terms].each do |field|
        instance_variable_set("@#{field}", terms[field].to_s)
      end
      %w[payment_lump_sum payment_monthly payment_final].each do |field|
        instance_variable_set("@#{field}", terms[field] == "1")
      end
    end
  end

  def agreement_conversation(file)
    PrimaryMessageGroup.find_by(ConversationID: file.agreement_conversation_id) if file.agreement_conversation_id.present?
  end

  def agreement_party?(conversation)
    [ conversation.TenantID, conversation.LandlordID ].include?(@user.UserID)
  end

  def agreement_creator?(conversation)
    agreement_party?(conversation) || conversation.MediatorID == @user.UserID
  end

  def announce_agreement(conversation, contents)
    message = Message.create!(ConversationID: conversation.ConversationID, SenderID: @user.UserID,
                              Contents: contents, MessageDate: Time.current, is_system: true)
    sender_name = [ @user.FName, @user.LName ].compact.join(" ").squeeze(" ").strip
    ActionCable.server.broadcast("messages_#{conversation.ConversationID}", {
      message_id: message.MessageID, contents: message.Contents, sender_id: message.SenderID,
      recipient_id: nil, message_date: message.MessageDate.strftime("%-I:%M %p"),
      message_timestamp: message.MessageDate.to_i, sender_role: @user.Role,
      sender_name: sender_name, attachments: [], broadcast: true, is_system: true
    })
  end

  def generated_document_name(template)
    creator_name = [ @user[:FName], @user[:LName] ].compact.join(" ").squeeze(" ").strip
    creator_name = @user[:CompanyName].presence || "Creator" if creator_name.blank?
    safe_creator_name = creator_name.gsub(/[^\w\- ]/, "").squeeze(" ").strip
    document_type = {
      "a" => "Agree to Vacate",
      "b" => "Pay and Stay Agreement",
      "c" => "Mediation Agreement"
    }.fetch(template.to_s, "Agreement")

    [ safe_creator_name.presence, document_type ].join(" - ")
  end

  def delete_physical_file(file)
    rel = Pathname.new(file.FileURLPath.to_s).cleanpath
    base = Rails.root.join("public")
    path = base.join(rel)
    if path.to_s.start_with?(base.to_s) && File.exist?(path)
      File.delete(path) rescue nil
    end
  end

  def find_file_for_user(id)
    scope = FileDraft.where(FileID: id)
    scope = scope.where(UserDeletedAt: nil) if FileDraft.column_names.include?("UserDeletedAt")

    file = scope.first
    return unless file
    return file if file.CreatorID == @user[:UserID]

    attachments = FileAttachment.where(FileID: file.FileID)
    return unless attachments.exists?

    message_ids = attachments.select(:MessageID)
    messages = Message.where(MessageID: message_ids)

    # Check if user is a direct participant (sender or recipient)
    message_table = Message.arel_table
    participant_condition = message_table[:SenderID].eq(@user[:UserID])
                             .or(message_table[:recipientID].eq(@user[:UserID]))

    return file if messages.where(participant_condition).exists?

    # Check if user is a mediator or other party in the conversation
    conversation_ids = messages.pluck(:ConversationID).uniq
    conversation_ids.each do |conv_id|
      # Check PrimaryMessageGroup (landlord, tenant, mediator)
      pmg = PrimaryMessageGroup.find_by(ConversationID: conv_id)
      if pmg
        return file if pmg.LandlordID == @user[:UserID]
        return file if pmg.TenantID == @user[:UserID]
        return file if pmg.MediatorID == @user[:UserID]
      end

      # Check SideMessageGroup (mediator side conversations)
      smg = SideMessageGroup.find_by(ConversationID: conv_id)
      if smg
        return file if smg.UserID == @user[:UserID]
        return file if smg.MediatorID == @user[:UserID]
      end
    end

    nil
  end

  def update_document_with_signature(file, is_landlord, signature_name)
    file_path = Rails.root.join("public", file.FileURLPath)
    return unless File.exist?(file_path)

    html_content = File.read(file_path)
    signed_date = Time.current.strftime("%B %d, %Y")

    if is_landlord
      # Try new Pay and Stay format first
      if html_content =~ /<strong>Landlord:<\/strong>\s*<span class="signature-line">/
        html_content.gsub!(
          /(<strong>Landlord:<\/strong>\s*<span class="signature-line">)___________(<\/span>)/m,
          "\\1/s/ #{signature_name}\\2"
        )
        html_content.gsub!(
          /(<strong>Landlord:<\/strong>\s*<span class="signature-line">.*?<\/span>\s*<span style="margin-left: 50px;"><strong>Date:<\/strong> <span class="date-line">)___________(<\/span>)/m,
          "\\1#{signed_date}\\2"
        )
      else
        # Fall back to old format
        html_content.gsub!(
          /<span class="sig-underline"><\/span>\s*<div class="sig-label">\s*<span>Landlord<\/span>/m,
          "<span class=\"sig-underline\">/s/ #{signature_name}</span>\n      <div class=\"sig-label\">\n        <span>Landlord</span>"
        )
        html_content.gsub!(
          /(<span>Landlord<\/span>\s*<span style="float: right;">)Date(<\/span>)/m,
          "\\1#{signed_date}\\2"
        )
      end
    else
      # Try new Pay and Stay format first
      if html_content =~ /<strong>Tenant:<\/strong>\s*<span class="signature-line">/
        html_content.gsub!(
          /(<strong>Tenant:<\/strong>\s*<span class="signature-line">)___________(<\/span>)/m,
          "\\1/s/ #{signature_name}\\2"
        )
        html_content.gsub!(
          /(<strong>Tenant:<\/strong>\s*<span class="signature-line">.*?<\/span>\s*<span style="margin-left: 50px;"><strong>Date:<\/strong> <span class="date-line">)___________(<\/span>)/m,
          "\\1#{signed_date}\\2"
        )
      else
        # Fall back to old format
        html_content.gsub!(
          /<span class="sig-underline"><\/span>\s*<div class="sig-label">\s*<span>Tenant<\/span>/m,
          "<span class=\"sig-underline\">/s/ #{signature_name}</span>\n      <div class=\"sig-label\">\n        <span>Tenant</span>"
        )
        html_content.gsub!(
          /(<span>Tenant<\/span>\s*<span style="float: right;">)Date(<\/span>)/m,
          "\\1#{signed_date}\\2"
        )
      end
    end

    File.write(file_path, html_content)
  end

  def next_filedraft_pk_value
    pk = FileDraft.primary_key
    return [ nil, nil ] if pk.blank?

    col = FileDraft.columns_hash[pk]
    if col && [ :integer, :bigint ].include?(col.type)
      next_val = (FileDraft.maximum(pk) || 0) + 1
      [ pk, next_val ]
    else
      [ nil, nil ]
    end
  end

  def next_file_draft_id
    (FileDraft.maximum("ID") || 0) + 1
  end

  def set_conversation_context
    conv_id = params[:conversation_id].presence || params[:id]
    return unless conv_id

    @conversation = ::MessageString.find_by(ConversationID: conv_id) rescue nil
    @pmg          = ::PrimaryMessageGroup.find_by(ConversationID: conv_id) rescue nil

    @landlord = ::User.find_by(UserID: @pmg&.LandlordID)
    @tenant   = ::User.find_by(UserID: @pmg&.TenantID)
    @intake   = ::IntakeQuestion.find_by(IntakeID: @pmg&.IntakeID)
  end

  def require_login
    redirect_to login_path, alert: "You must be logged in." unless session[:user_id]
  end

  def set_user
    @user = ::User.find_by(UserID: session[:user_id])
    redirect_to login_path, alert: "Please log in." unless @user
  end

  # Admins have read-only visibility into conversations. They may view and
  # download existing documents, but must not create or generate new ones.
  def block_admin_document_creation
    if @user&.Role == "Admin"
      redirect_to admin_mediations_path, alert: "Administrators have read-only access and cannot generate documents."
    end
  end

  # PDF Template Generators
  def generate_vacate_agreement(pdf, landlord, tenant, address, date, reason, money_owed, schedule, best)
    pdf.text "AGREEMENT TO VACATE PREMISES", size: 18, style: :bold, align: :center
    pdf.move_down 20

    pdf.text "This Agreement to Vacate is made on #{date.strftime('%B %d, %Y')} between:", size: 11
    pdf.move_down 10

    pdf.text "LANDLORD: #{landlord}", size: 11, style: :bold
    pdf.text "TENANT: #{tenant}", size: 11, style: :bold
    pdf.text "PROPERTY ADDRESS: #{address}", size: 11, style: :bold
    pdf.move_down 15

    pdf.text "WHEREAS:", size: 12, style: :bold
    pdf.move_down 8
    pdf.text "• The Tenant currently resides at the above-mentioned property", size: 10, indent_paragraphs: 20
    pdf.text "• Reason for agreement: #{reason}", size: 10, indent_paragraphs: 20
    pdf.text "• Outstanding rent owed: $#{money_owed}", size: 10, indent_paragraphs: 20
    pdf.move_down 15

    pdf.text "TERMS OF AGREEMENT:", size: 12, style: :bold
    pdf.move_down 8

    vacate_date = schedule.first&.last if schedule.any?
    vacate_date_str = vacate_date.present? ? (Date.parse(vacate_date) rescue vacate_date) : "To be determined"

    pdf.text "1. The Tenant agrees to vacate the premises on or before: #{vacate_date_str}", size: 10, indent_paragraphs: 20
    pdf.move_down 8
    pdf.text "2. The Tenant will leave the property in clean and acceptable condition", size: 10, indent_paragraphs: 20
    pdf.move_down 8
    pdf.text "3. All keys and access devices will be returned to the Landlord", size: 10, indent_paragraphs: 20
    pdf.move_down 8

    if schedule.any?
      pdf.text "4. Payment Schedule for Outstanding Rent ($#{money_owed}):", size: 10, indent_paragraphs: 20, style: :bold
      pdf.move_down 5
      schedule.each_with_index do |(i, amt, due), idx|
        due_str = due.present? ? (Date.parse(due).strftime("%B %d, %Y") rescue due) : "TBD"
        pdf.text "   Payment #{idx + 1}: $#{amt} due on #{due_str}", size: 9, indent_paragraphs: 40
      end
    end

    pdf.move_down 15
    pdf.text "Both parties agree to the terms outlined above.", size: 10
  end

  def generate_pay_stay_agreement(pdf, landlord, tenant, address, date, reason, money_owed, monthly_rent, schedule, best)
    pdf.text "PAY AND STAY NEGOTIATED AGREEMENT", size: 18, style: :bold, align: :center
    pdf.move_down 20

    pdf.text "This Pay and Stay Agreement is entered into on #{date.strftime('%B %d, %Y')} by and between:", size: 11
    pdf.move_down 10

    pdf.text "LANDLORD: #{landlord}", size: 11, style: :bold
    pdf.text "TENANT: #{tenant}", size: 11, style: :bold
    pdf.text "PROPERTY ADDRESS: #{address}", size: 11, style: :bold
    pdf.move_down 15

    pdf.text "RECITALS:", size: 12, style: :bold
    pdf.move_down 8
    pdf.text "• Tenant is currently residing at the property", size: 10, indent_paragraphs: 20
    pdf.text "• Reason for negotiation: #{reason}", size: 10, indent_paragraphs: 20
    pdf.text "• Total amount owed: $#{money_owed}", size: 10, indent_paragraphs: 20
    pdf.text "• Monthly rent: $#{monthly_rent}", size: 10, indent_paragraphs: 20
    pdf.move_down 15

    pdf.text "AGREEMENT TERMS:", size: 12, style: :bold
    pdf.move_down 8

    pdf.text "1. The Tenant will remain in the property and continue tenancy", size: 10, indent_paragraphs: 20
    pdf.move_down 8
    pdf.text "2. The Tenant agrees to pay the outstanding balance according to the following schedule:", size: 10, indent_paragraphs: 20
    pdf.move_down 10

    if schedule.any?
      data = [ [ "Payment #", "Amount", "Due Date" ] ]
      schedule.each_with_index do |(i, amt, due), idx|
        due_str = due.present? ? (Date.parse(due).strftime("%m/%d/%Y") rescue due) : "TBD"
        data << [ (idx + 1).to_s, "$#{amt}", due_str ]
      end

      pdf.table(data, header: true, width: pdf.bounds.width - 40, position: 20,
                cell_style: { size: 10, padding: 8 }) do
        row(0).font_style = :bold
        row(0).background_color = "E8F4F8"
      end
      pdf.move_down 15
    end

    pdf.text "3. Tenant must continue paying monthly rent of $#{monthly_rent} on time", size: 10, indent_paragraphs: 20
    pdf.move_down 8
    pdf.text "4. Failure to comply with this agreement may result in eviction proceedings", size: 10, indent_paragraphs: 20
    pdf.move_down 15

    pdf.text "This agreement is binding upon execution by both parties.", size: 10
  end

  def generate_mediation_agreement(pdf, landlord, tenant, address, date, reason, money_owed, monthly_rent, schedule, best)
    pdf.text "MEDIATION AGREEMENT", size: 18, style: :bold, align: :center
    pdf.move_down 20

    pdf.text "This Mediation Agreement is executed on #{date.strftime('%B %d, %Y')} between:", size: 11
    pdf.move_down 10

    pdf.text "PARTY A (Landlord): #{landlord}", size: 11, style: :bold
    pdf.text "PARTY B (Tenant): #{tenant}", size: 11, style: :bold
    pdf.text "CONCERNING PROPERTY: #{address}", size: 11, style: :bold
    pdf.move_down 15

    pdf.text "BACKGROUND:", size: 12, style: :bold
    pdf.move_down 8
    pdf.text "The parties have entered into mediation to resolve the following dispute:", size: 10
    pdf.move_down 5
    pdf.text "• Nature of dispute: #{reason}", size: 10, indent_paragraphs: 20
    pdf.text "• Amount in question: $#{money_owed}", size: 10, indent_paragraphs: 20
    pdf.text "• Current monthly rent: $#{monthly_rent}", size: 10, indent_paragraphs: 20
    pdf.move_down 15

    pdf.text "MEDIATED RESOLUTION:", size: 12, style: :bold
    pdf.move_down 8

    pdf.text "The parties agree to the following terms to resolve this dispute:", size: 10
    pdf.move_down 10

    pdf.text "1. PAYMENT ARRANGEMENT:", size: 10, style: :bold, indent_paragraphs: 20
    pdf.move_down 5

    if schedule.any?
      pdf.text "   The Tenant agrees to pay the outstanding balance as follows:", size: 10, indent_paragraphs: 20
      pdf.move_down 8

      data = [ [ "Installment", "Amount", "Due Date" ] ]
      schedule.each_with_index do |(i, amt, due), idx|
        due_str = due.present? ? (Date.parse(due).strftime("%B %d, %Y") rescue due) : "TBD"
        data << [ (idx + 1).to_s, "$#{amt}", due_str ]
      end

      pdf.table(data, header: true, width: pdf.bounds.width - 40, position: 20,
                cell_style: { size: 9, padding: 6 }) do
        row(0).font_style = :bold
        row(0).background_color = "F0F0F0"
      end
      pdf.move_down 12
    end

    pdf.text "2. ONGOING OBLIGATIONS:", size: 10, style: :bold, indent_paragraphs: 20
    pdf.move_down 5
    pdf.text "   • Tenant will continue paying regular monthly rent of $#{monthly_rent}", size: 9, indent_paragraphs: 25
    pdf.text "   • Tenant will maintain the property in good condition", size: 9, indent_paragraphs: 25
    pdf.text "   • Landlord will not pursue eviction while this agreement is honored", size: 9, indent_paragraphs: 25
    pdf.move_down 12

    pdf.text "3. DEFAULT PROVISION:", size: 10, style: :bold, indent_paragraphs: 20
    pdf.move_down 5
    pdf.text "   If Tenant fails to make any payment, Landlord may proceed with eviction", size: 9, indent_paragraphs: 25
    pdf.move_down 15

    pdf.text "This agreement represents the full understanding between the parties.", size: 10
  end

  def generate_generic_agreement(pdf, landlord, tenant, address, date, reason, money_owed, schedule, best)
    pdf.text "RENTAL AGREEMENT", size: 18, style: :bold, align: :center
    pdf.move_down 20

    pdf.text "Date: #{date.strftime('%B %d, %Y')}", size: 11
    pdf.move_down 10

    pdf.text "Landlord: #{landlord}", size: 11
    pdf.text "Tenant: #{tenant}", size: 11
    pdf.text "Address: #{address}", size: 11
    pdf.move_down 15

    pdf.text "Reason: #{reason}", size: 10
    pdf.text "Amount Owed: $#{money_owed}", size: 10
    pdf.text "Resolution Type: #{best}", size: 10
    pdf.move_down 15

    if schedule.any?
      pdf.text "Payment Schedule:", style: :bold
      pdf.move_down 6
      schedule.each_with_index do |(i, amt, due), idx|
        pdf.text "Payment #{idx + 1}: $#{amt} due on #{due}"
      end
    end
  end
end
