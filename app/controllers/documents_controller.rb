# app/controllers/documents_controller.rb
require "fileutils"
require "pathname"
require "securerandom"
require "tempfile"
require "prawn"
require "prawn/table"

class DocumentsController < ApplicationController
  class LegacyAgreementFormatError < StandardError; end

  rescue_from LegacyAgreementFormatError, with: :render_legacy_agreement_format_error

  before_action :require_login
  before_action :set_user
  before_action :authorize_template_conversation, only: [ :template_intake, :intake_template_view ]
  before_action :block_admin_document_creation, only: [
    :new, :create, :template_intake, :generate_from_intake,
    :template_preview, :intake_template_view, :generate_filled_template,
    :apply_signature, :review, :update_review, :decide_suggestion, :counteroffer_suggestion
  ]
  before_action :authorize_mediation_template, only: [
    :template_intake, :template_preview, :generate_from_intake, :generate_filled_template
  ]
  before_action :set_conversation_context, only: [ :intake_template_view ]

  def generate
    @show_mediation_template = assigned_mediator_for_generation?
  end

  def intake_template_view
  end

  def template_intake
    @template = new_agreement_template(params[:template])
    @generation_fields = agreement_fields_for_template(@template) - ["additional_signature_parties"]
    @template_name = case @template
    when CustomResolutionTerms::TEMPLATE then "Custom Resolution Agreement"
    when MoveOutTerms::TEMPLATE then "Move-Out Agreement"
    when "b" then "Pay and Stay Agreement"
    when AgreementToMediateTerms::TEMPLATE then "Agreement to Mediate"
    else "Unknown Template"
    end

    # Set default resolution type based on template
    @default_resolution = case @template
    when "b" then "Payment Plan"
    else ""
    end


    @conversation_id = params[:conversation_id]
    if @conversation_id.present?
      @conversation = @template_conversation
      if @conversation
        @landlord = @conversation.landlord
        @tenant = @conversation.tenant
      end
    end

    @generation_values = {
      "landlord_name" => @landlord ? [@landlord.FName, @landlord.LName].compact.join(" ").strip : "",
      "tenant_name" => @tenant ? [@tenant.FName, @tenant.LName].compact.join(" ").strip : [@user.FName, @user.LName].compact.join(" ").strip,
      "address" => @tenant&.formatted_tenant_address || @user.formatted_tenant_address || "",
      "negotiation_date" => Date.today.iso8601,
      "best_option" => @default_resolution
    }
    if @template == AgreementToMediateTerms::TEMPLATE
      @generation_values["mediator_name"] = assigned_agreement_mediator_name(@conversation)
    end
    if @template == CustomResolutionTerms::TEMPLATE
      @generation_values["cr_action_#{SecureRandom.uuid}_present"] = "yes"
    end
  end

  def template_preview
    @template = new_agreement_template(params[:template])
    @agreement_editor_preview = true


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

    @template = MoveOutTerms::TEMPLATE unless ["b", AgreementToMediateTerms::TEMPLATE, CustomResolutionTerms::TEMPLATE].include?(@template)
    @move_out_terms = {} if @template == MoveOutTerms::TEMPLATE
    template_file = agreement_template_file(@template)

    render template: template_file, layout: false
  end

  def generate_from_intake
    template = new_agreement_template(params[:template])
    return head :not_found unless [MoveOutTerms::TEMPLATE, CustomResolutionTerms::TEMPLATE, AgreementToMediateTerms::TEMPLATE, "b"].include?(template)
    @conversation_id = params[:conversation_id]
    conversation = PrimaryMessageGroup.find_by(ConversationID: @conversation_id) if @conversation_id.present?

    if @conversation_id.present? && (!conversation || !agreement_creator?(conversation))
      return render plain: "Unauthorized", status: :forbidden
    end

    terms = agreement_terms_from_params(template)
    if template == CustomResolutionTerms::TEMPLATE
      @template_conversation = conversation
      submitted_terms = terms
      terms = CustomResolutionTerms.normalize(terms)
      error = CustomResolutionTerms.error(terms)
      if params[:custom_preview] == "1" || error
        template_intake
        @generation_values = submitted_terms
        @agreement_editor_error = error
        return render :template_intake, status: error ? :unprocessable_entity : :ok
      end
    elsif template == AgreementToMediateTerms::TEMPLATE
      mediator_name = assigned_agreement_mediator_name(conversation)
      terms["mediator_name"] = mediator_name if terms["mediator_name"].blank?
      error = if conversation && mediator_name.blank?
        "Assign a mediator with a name before generating this agreement."
      else
        AgreementToMediateTerms.error(terms.merge("additional_signature_parties" => params[:additional_signature_parties]))
      end
      if error
        @template_conversation = conversation
        template_intake
        @generation_values.merge!(terms)
        @agreement_editor_error = error
        return render :template_intake, status: :unprocessable_entity
      end
    elsif template == "b"
      normalize_pay_and_stay_terms!(terms)
      error = pay_and_stay_terms_error(terms, complete: true) || PayAndStayTerms.release_error(terms)
      if error
        template_intake
        @generation_values.merge!(terms)
        @agreement_editor_error = error
        @agreement_editor_preview = true
        assign_agreement_template_variables(template, terms.except("additional_signature_parties"))
        @agreement_retry_preview = render_to_string(template: agreement_template_file(template), layout: false)
        return render :template_intake, status: :unprocessable_entity
      end

      terms["pay_and_stay_draft_version"] = "1"
    elsif template == MoveOutTerms::TEMPLATE
      terms = MoveOutTerms.structured_schedule(terms)
      terms = terms.except(*MoveOutTerms.inactive_fields(terms))
    end

    if template == MoveOutTerms::TEMPLATE && (error = MoveOutTerms.error(terms))
      template_intake
      @generation_values.merge!(terms)
      @agreement_editor_error = error
      @agreement_editor_preview = true
      assign_agreement_template_variables(template, terms)
      @agreement_retry_preview = render_to_string(template: agreement_template_file(template), layout: false)
      return render :template_intake, status: :unprocessable_entity
    end

    assign_agreement_template_variables(template, terms)
    @template_name = agreement_template_name(template)
    template_file = agreement_template_file(template)

    file_id = SecureRandom.uuid
    writer = ->(path) { File.write(path, render_to_string(template: template_file, layout: false)) }

    # Create database record
    pk_name, pk_value = next_filedraft_pk_value
    attrs = {
      FileID: file_id,
      FileName: generated_document_name(template),
      FileTypes: "html",
      CreatorID: @user[:UserID],
      TenantSignature: false,
      LandlordSignature: false,
      AgreementTemplate: template,
      AgreementTerms: JSON.generate(terms),
      AgreementVersion: 1
    }
    attrs[pk_name] = pk_value if pk_name && pk_value

    # Save the document without automatically sharing it in a conversation
    DocumentCreation.new.call(extension: "html", writer: writer) do |locator|
      FileDraft.create!(attrs.merge(FileURLPath: locator))
    end

    # Return to the page where document generation started
    return_path = url_from(params[:return_to]) || documents_path
    redirect_to return_path, notice: "Document generated successfully."
  rescue DocumentCreation::Failure
    render plain: "Unable to create document. Please try again.", status: :service_unavailable
  end

  # delete files
  def destroy
    DocumentDeletion.new.call(id: params[:id], user: @user)
    redirect_to documents_path, notice: "Document deleted."
  rescue DocumentDeletion::NotFound
    render plain: "File not found", status: :not_found
  rescue DocumentDeletion::Unauthorized
    render plain: "Unauthorized", status: :forbidden
  rescue DocumentDeletion::Failure
    render plain: "Unable to delete document. Please try again.", status: :service_unavailable
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
    pk_name, pk_value = next_filedraft_pk_value

    sanitized_filename = File.basename(uploaded.original_filename)
    attrs = {
      FileID:       file_id,
      FileName:     File.basename(sanitized_filename, ".*"),
      FileTypes:    ext.delete("."),
      CreatorID:    @user[:UserID],
      TenantSignature: true,
      LandlordSignature: true
    }
    attrs[pk_name] = pk_value if pk_name && pk_value

    DocumentCreation.new.call(extension: ext, writer: ->(path) {
      File.open(path, "wb") { |destination| IO.copy_stream(uploaded.tempfile, destination) }
    }) do |locator|
      FileDraft.create!(attrs.merge(FileURLPath: locator))
    end

    redirect_to documents_path, notice: "File uploaded."
  rescue DocumentCreation::Failure
    render plain: "Unable to create document. Please try again.", status: :service_unavailable
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

      @mediator = @conversation.mediator if @file.agreement_to_mediate? && @conversation.MediatorAssigned?

      # Determine if current user can sign
      @user_role_in_conversation = @file.agreement_signer_role(@user, @conversation)&.downcase
    end
    if @agreement_proposal.present?
      offerer_ids = @file.agreement_suggestion_items.map { |item| item[:offered_by_id].to_i }.uniq
      @offer_authors = User.where(UserID: offerer_ids).index_by(&:UserID)
      @reviewer_id = active_agreement_reviewer_id(@file, @agreement_proposal, @conversation) if @conversation && @file.agreement_suggestions_pending?
    end
    @can_suggest_agreement = @file.agreement_document? &&
                         @conversation.present? &&
                         @file.agreement_conversation_id.to_s == @conversation.ConversationID.to_s &&
                         agreement_suggester?(@conversation)

    @editing_agreement = params[:edit] == "1" &&
                        @file.agreement_editable? &&
                        @can_suggest_agreement &&
                        !@file.agreement_suggestions_pending? &&
                        params[:view_mode] != "simple"
    @editable_agreement_fields = agreement_editable_fields(@file) if @editing_agreement
    if params[:edit].present? && !@editing_agreement
      return redirect_to view_file_path(@file.FileID), alert: "This agreement is not available for editing."
    end
  end

  def review
    @file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless @file

    @conversation = agreement_conversation(@file)
    return render plain: "Unauthorized", status: :forbidden unless agreement_suggester?(@conversation)
    return redirect_to view_file_path(@file.FileID), alert: "This agreement can no longer be changed." unless @file.agreement_editable?
    return redirect_to view_file_path(@file.FileID), alert: "Review the pending suggestions before proposing more changes." if @file.agreement_suggestions_pending?

    redirect_to view_file_path(@file.FileID, edit: 1)
  end

  def update_review
    file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless file

    conversation = agreement_conversation(file)
    return render plain: "Unauthorized", status: :forbidden unless agreement_suggester?(conversation)
    return redirect_to view_file_path(file.FileID), alert: "This agreement can no longer be changed." unless file.agreement_editable?

    terms = if file.custom_resolution?
      custom_resolution_params
    else
      params.permit(*agreement_editable_fields(file)).to_h
    end
    result = nil
    validation_error = nil
    submitted_custom_terms = nil
    file.with_lock do
      if !file.agreement_editable? || file.agreement_suggestions_pending? || params[:agreement_version].to_i != file.AgreementVersion
        result = :stale
      else
        current = file.agreement_terms
        if file.AgreementTemplate == "b"
          normalize_pay_and_stay_terms!(terms)
          terms = current.merge(terms)
        elsif file.custom_resolution?
          submitted_custom_terms = params[:custom_full_form] == "1" ? terms : current.merge(terms)
          terms = CustomResolutionTerms.normalize(submitted_custom_terms)
        elsif file.agreement_to_mediate?
          terms = current.merge(terms.transform_values { |value| value.to_s.strip })
          terms["additional_signature_parties"] = params[:additional_signature_parties] if params[:additional_signature_parties].present?
        elsif file.revised_move_out?
          terms = current.merge(terms.transform_values { |value| value.to_s.strip })
          terms = terms.except(*MoveOutTerms.inactive_fields(terms))
        end
        review_fields = if file.custom_resolution?
          CustomResolutionTerms.groups(current.keys | terms.keys).values.flatten
        else
          agreement_editable_fields(file)
        end
        changes = review_fields.each_with_object({}) do |field, list|
          old_value = current[field].to_s
          new_value = terms[field].to_s
          list[field] = { "from" => old_value, "to" => new_value, "decision" => "pending" } unless old_value == new_value
        end
        if file.revised_pay_and_stay? || file.revised_move_out? || file.custom_resolution?
          groups = if file.custom_resolution?
            CustomResolutionTerms.review_groups(current, terms)
          elsif file.revised_move_out?
            MoveOutTerms::GROUPS
          else
            PayAndStayTerms::REVIEW_GROUPS
          end
          groups.each do |group, fields|
            next if file.revised_pay_and_stay? && PayAndStayTerms::PAYMENT_REVIEW_GROUPS.include?(group)
            next unless fields.any? { |field| changes.key?(field) }

            if file.revised_move_out? && current["move_out_schedule"].blank? && terms["move_out_schedule"].blank?
              fields = fields - ["move_out_schedule"]
            end

            # A counteroffer can choose a different branch and enter its details.
            fields.each do |field|
              changes[field] ||= { "from" => current[field].to_s, "to" => terms[field].to_s, "decision" => "pending" }
              changes[field]["group_key"] = group
            end
          end
        else
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
        end
        if (validation_error = agreement_terms_error(terms, file: file))
          result = :invalid_payment
        elsif !file.revised_move_out? && (invalid = changes.find { |field, change| !valid_agreement_counteroffer?(field, change["to"], file: file) })
          validation_error = "Enter a valid #{helpers.agreement_field_label(invalid.first).downcase}."
          result = :invalid
        elsif changes.empty?
          result = :unchanged
        else
          reviewer_ids =
            if @user.mediator?
              [conversation.TenantID, conversation.LandlordID].uniq
            else
              [other_agreement_party_id(conversation, @user.UserID)]
            end

          proposal = {
            "base_version" => file.AgreementVersion,
            "proposer_id" => @user.UserID,
            "changes" => changes
          }

          if @user.mediator?
            proposal["mediator_proposal"] = true
            proposal["reviewer_ids"] = reviewer_ids

            changes.each_value do |change|
              change["party_decisions"] = {
                "tenant" => "pending",
                "landlord" => "pending"
              }
            end

            unless file.revised_pay_and_stay?
              # Keep amount and date changes together as one payment suggestion.
              (1..6).each do |number|
                amount_key = "amount#{number}"
                date_key = "date#{number}"

                if changes.key?(amount_key) && changes.key?(date_key)
                  changes[amount_key]["group_key"] = "payment#{number}"
                end
              end
            end
          else
            proposal["reviewer_id"] = reviewer_ids.first
          end

          file.update!(AgreementProposal: JSON.generate(proposal))
          result = :submitted
        end
      end
    end
    case result
    when :submitted
      notify_agreement_participants(conversation, file, "agreement_suggestions_pending")
      announce_agreement(conversation, "#{agreement_actor_name} suggested changes to the agreement. Review the document to see them.")
      ActionCable.server.broadcast("document_#{file.FileID}", { type: "agreement_proposal_update", actor_id: @user.UserID })
      redirect_to view_file_path(file.FileID), notice: "Suggested changes sent for review."
    when :unchanged
      redirect_to view_file_path(file.FileID), notice: "No terms were changed."
    when :invalid, :invalid_payment
      if file.AgreementTemplate == "b" || file.revised_move_out? || file.custom_resolution? || file.agreement_to_mediate?
        if file.AgreementTemplate == "b"
          terms = terms.merge("additional_signature_parties" => file.agreement_terms["additional_signature_parties"])
        end
        unless file.custom_resolution? || file.agreement_to_mediate?
          @agreement_editor_preview = true
          assign_agreement_template_variables(file.AgreementTemplate, terms)
          if file.AgreementTemplate == "b" && !file.revised_pay_and_stay? &&
             !valid_agreement_counteroffer?("forgiveness_deadline", @forgiveness_deadline)
            @forgiveness_deadline = ""
          end
          @agreement_retry_preview = render_to_string(template: stored_agreement_template(file), formats: [:html], layout: false)
        end

        params[:edit] = "1"
        show
        return if performed?

        @submitted_agreement_terms = file.custom_resolution? ? submitted_custom_terms : terms
        @agreement_editor_error = validation_error
        render :show, status: :unprocessable_entity
      else
        redirect_to view_file_path(file.FileID, edit: 1), alert: validation_error
      end
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

    proposal = file.agreement_proposal

    if mediator_agreement_proposal?(proposal)
      return decide_mediator_suggestion(file, conversation, decision)
    end

    result = nil
    completed_round = nil
    validation_error = nil
    accepted_changes = []
    # Keep access, reviewer eligibility, and proposal checks locked through publication.
    file.with_lock do
      conversation = agreement_conversation(file)
      conversation.lock! if conversation
      unless find_file_for_user(file.FileID) && conversation && agreement_party?(conversation)
        result = :unavailable
        next
      end
      proposal = file.agreement_proposal
      changes = proposal["changes"] || {}
      item = file.agreement_suggestion_items.find { |suggestion| suggestion[:key] == params[:field].to_s }
      if mediator_agreement_proposal?(proposal) || !file.agreement_editable? || !file.agreement_suggestions_pending? ||
         proposal["base_version"].to_i != file.AgreementVersion || item.nil? ||
         active_agreement_reviewer_id(file, proposal, conversation) != @user.UserID ||
         item[:offered_by_id].to_i == @user.UserID ||
         proposal.fetch("draft_counteroffers", {}).key?(item[:key]) ||
         item[:fields].any? { |field| changes[field]["decision"] != "pending" }
        result = :unavailable
      else
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
          accepted_terms = accepted_terms.except(*MoveOutTerms.inactive_fields(accepted_terms)) if file.revised_move_out?
          accepted_terms = CustomResolutionTerms.normalize(accepted_terms) if file.custom_resolution?
          if !(validation_error = agreement_terms_error(accepted_terms, file: file))
            accepted_changes = item[:fields].filter_map do |field|
              change = changes.fetch(field)
              next if change["from"] == change["to"]

              label = helpers.agreement_field_label(field)
              before = helpers.agreement_field_value(field, change["from"])
              after = helpers.agreement_field_value(field, change["to"])
              "#{label}: #{before} → #{after}"
            end
            item[:fields].each { |field| changes[field]["decision"] = decision }
            html = render_accepted_agreement(file, accepted_terms)
            DocumentRevision.new.call(
              file: file, extension: "html",
              writer: ->(_original, path, _locked) { File.write(path, html) }
            ) do
              file.AgreementTerms = JSON.generate(accepted_terms)
              file.AgreementVersion += 1
              file.clear_agreement_signatures
              proposal["base_version"] = file.AgreementVersion
              proposal["round_accepted"] = true
              file.AgreementProposal = JSON.generate(proposal)
              completed_round = finish_agreement_review_round(file, proposal, conversation)
            end
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
    if result == :updated
      notify_agreement_participants(conversation, file, "agreement_revised", changes: accepted_changes)
    end
    if completed_round
      notify_agreement_review_completed(conversation, file, completed_round) unless result == :updated
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
        render json: { error: validation_error }, status: :unprocessable_entity
      else
        redirect_to focus_path, alert: validation_error
      end
    else
      if request.format.json?
        render json: { error: "This suggestion is no longer available. Refresh the agreement." }, status: :conflict
      else
        redirect_to view_file_path(file.FileID), alert: "This suggestion is no longer available. Refresh the agreement."
      end
    end
  rescue DocumentRevision::Failure
    render_agreement_revision_failure
  end

  def counteroffer_suggestion
    file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless file

    conversation = agreement_conversation(file)
    return render plain: "Unauthorized", status: :forbidden unless conversation && agreement_party?(conversation)

    proposal = file.agreement_proposal

    if mediator_agreement_proposal?(proposal)
      return counteroffer_mediator_suggestion(file, conversation)
    end

    result = nil
    completed_round = nil
    validation_error = nil
    values = nil
    file.with_lock do
      proposal = file.agreement_proposal
      item = file.agreement_suggestion_items.find { |suggestion| suggestion[:key] == params[:field].to_s }
      if !file.agreement_editable? || !file.agreement_suggestions_pending? ||
         proposal["base_version"].to_i != file.AgreementVersion ||
         active_agreement_reviewer_id(file, proposal, conversation) != @user.UserID ||
         item.nil? || item[:fields].any? { |field| proposal["changes"][field]["decision"] != "pending" } ||
         proposal.fetch("draft_counteroffers", {}).key?(item[:key]) ||
         item[:offered_by_id].to_i == @user.UserID
        result = :unavailable
      else
        values = agreement_counteroffer_values(item, file)
        candidate_terms = file.agreement_terms.merge(values)
        if (validation_error = agreement_terms_error(candidate_terms, file: file))
          result = :invalid_payment
        elsif item[:fields].any? { |field| !values.key?(field) || (!file.revised_move_out? && !valid_agreement_counteroffer?(field, values[field], file: file)) } ||
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
      notify_agreement_review_completed(conversation, file, completed_round)
      announce_agreement(conversation, agreement_review_completion_message(completed_round, file))
      ActionCable.server.broadcast("document_#{file.FileID}", { type: "agreement_proposal_update", actor_id: @user.UserID })
    end
    message = case result
    when :countered then completed_round ? "Review sent with counteroffers." : "Counteroffer saved. Complete the remaining suggestions to send it."
    when :invalid then "Enter a different value for this counteroffer."
    when :invalid_payment then validation_error
    else "This suggestion is no longer available. Refresh the agreement."
    end
    if request.format.json?
      render json: result == :countered ? { status: "countered", field: params[:field], round_complete: completed_round.present? } : { error: message },
             status: result == :countered ? :ok : :unprocessable_entity
    elsif (file.AgreementTemplate == "b" || file.revised_move_out? || file.custom_resolution? || file.agreement_to_mediate?) && [:invalid, :invalid_payment].include?(result)
      render_counteroffer_error(values, message)
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

    signature_result = nil
    conversation = role = signature_name = nil
    @file.with_lock do
      unless find_file_for_user(@file.FileID)
        return render plain: "File not found", status: :not_found
      end
      unless @file.agreement_signable?
        message = if @file.custom_resolution? && @file.agreement_terms["cr_additional_signers"] != "no"
          CustomResolutionTerms::SIGNER_ERROR
        else
          "This agreement must be shared in a conversation before signing."
        end
        return redirect_to view_file_path(@file.FileID), alert: message
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

      conversation.lock! if @file.agreement_to_mediate?
      role = @file.agreement_signer_role(@user, conversation)
      unless role
        flash[:alert] = "You are not authorized to sign this document."
        return redirect_to view_file_path(@file.FileID)
      end

      signature_name = if @file.revised_move_out? || @file.custom_resolution? || @file.agreement_to_mediate?
        [@user.FName, @user.LName].filter_map(&:presence).join(" ").squish
      else
        params[:signature_name]&.strip
      end

      if signature_name.blank?
        flash[:alert] = "Please provide your name to sign the document."
        return redirect_to view_file_path(@file.FileID)
      end

      signature_fields = ["#{role}Signature", "#{role}SignatureName", "#{role}SignedAt"]
      signature_fields << "MediatorSignatureUserID" if role == "Mediator"
      unless (signature_fields - FileDraft.column_names).empty?
        raise DocumentRevision::Failure, "Missing signature columns for #{role}"
      end

      if @file.agreement_suggestions_pending?
        signature_result = :suggestions_pending
      elsif @file.agreement_document? && params[:agreement_version].to_i != @file.AgreementVersion
        signature_result = :stale
      elsif @file.public_send("#{role}Signature")
        signature_result = :already_signed
      elsif @file.agreement_to_mediate? && (error = @file.mediator_signing_error(conversation))
        return redirect_to view_file_path(@file.FileID), alert: error
      elsif (@file.revised_pay_and_stay? || @file.revised_move_out? || @file.custom_resolution? || @file.agreement_to_mediate?) && (error = agreement_terms_error(@file.agreement_terms, file: @file))
        return redirect_to view_file_path(@file.FileID), alert: "This agreement cannot be signed. #{error} Correct the agreement before signing."
      else
        signed_at = Time.current
        DocumentRevision.new.call(
          file: @file, extension: "html",
          writer: ->(original, path, locked) {
            html = AgreementSignature.new.call(original, file: locked, role: role,
                                              name: signature_name, signed_at: signed_at)
            path.binwrite(html)
          }
        ) do |locked|
          locked.public_send("#{role}Signature=", true)
          locked.public_send("#{role}SignedAt=", signed_at)
          locked.public_send("#{role}SignatureName=", signature_name)
          locked.MediatorSignatureUserID = @user.UserID if role == "Mediator"
        end

        # A successful save can omit attributes absent from the model's schema.
        # Verify the write while the document and its new locator can still roll back.
        stored_locator, stored_flag, stored_name, stored_time, stored_user_id =
          FileDraft.uncached { FileDraft.where(FileID: @file.FileID).pick(:FileURLPath, *signature_fields) }
        unless stored_locator == @file.FileURLPath && stored_flag && stored_name == signature_name &&
               stored_time&.in_time_zone&.to_date == signed_at.to_date &&
               (role != "Mediator" || stored_user_id == @user.UserID)
          raise DocumentRevision::Failure, "Signature fields were not persisted for #{role}"
        end
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

      message_content = "#{role} #{signature_name} has signed the document: #{@file.FileName}"

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
          mediator_signature: @file.agreement_to_mediate? && @file.MediatorSignature,
          mediator_signed_at: (@file.MediatorSignedAt&.strftime("%B %d, %Y at %I:%M %p") if @file.agreement_to_mediate?),
          both_signed: @file.agreement_fully_executed?
        }
      )

      if @file.agreement_fully_executed?
        flash[:success] = "Document signed successfully. All required signers have signed this agreement."

        # Send completion notification
        Message.create!(
          ConversationID: conversation.ConversationID,
          SenderID: @user.UserID,
          Contents: "Document fully executed: #{@file.FileName} - All parties have signed.",
          MessageDate: Time.current,
          is_system: true
        )
      elsif @file.agreement_to_mediate?
        flash[:success] = "Document signed successfully. Waiting for the remaining signatures."
      elsif @file.LandlordSignature && @file.TenantSignature
        flash[:success] = "Document signed successfully. #{PayAndStayTerms::ADDITIONAL_SIGNERS_NOTICE}"
      else
        flash[:success] = "Document signed successfully! Waiting for the other party to sign."
      end
    else
      flash[:alert] = "Failed to save signature. Please try again."
    end

    redirect_to view_file_path(@file.FileID)
  rescue DocumentRevision::Failure => error
    Rails.logger.error("Signing failed file_id=#{@file.FileID}: #{error.message}")
    redirect_to view_file_path(@file.FileID), alert: "Failed to save signature. Please try again."
  end

  # download of the stored file
  def download_or_view
    file = find_file_for_user(params[:id])
    return render plain: "File not found (record)", status: :not_found unless file

    deliver_document(file, disposition: "attachment")
  end


  def view_inline
    file = find_file_for_user(params[:id])
    return render plain: "File not found (record)", status: :not_found unless file

    if params[:editable_preview] == "1"
      conversation = agreement_conversation(file)
      return render plain: "Unauthorized", status: :forbidden unless agreement_suggester?(conversation) &&
        file.agreement_editable? && !file.agreement_suggestions_pending?

      @agreement_editor_preview = true
      assign_agreement_template_variables(file.AgreementTemplate, file.agreement_terms)
      return render template: stored_agreement_template(file), layout: false
    end

    deliver_document(file, disposition: "inline")
  end

  def generate_filled_template
    template = new_agreement_template(params[:template])
    if ["b", MoveOutTerms::TEMPLATE, CustomResolutionTerms::TEMPLATE, AgreementToMediateTerms::TEMPLATE].include?(template)
      return redirect_to template_intake_path(template: template, conversation_id: params[:conversation_id],
                                             return_to: url_from(params[:return_to])), status: :see_other
    end

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
    # Generate the PDF based on template type
    require "prawn"
    reason = params[:reason].to_s
    money_owed = params[:money_owed].to_s

    writer = ->(path) do
      Prawn::Document.generate(path.to_s, margin: 54, page_size: "LETTER") do |pdf|
        generate_generic_agreement(pdf, landlord, tenant, address, nego_date, reason, money_owed, schedule, best)

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
    end

    pk_name, pk_value = next_filedraft_pk_value

    attrs = {
      FileID: file_id,
      FileName: generated_document_name(template),
      FileTypes: "pdf",
      CreatorID: @user[:UserID],
      TenantSignature: tenant_sig.present?,
      LandlordSignature: land_sig.present?
    }
    attrs[pk_name] = pk_value if pk_name && pk_value

    DocumentCreation.new.call(extension: "pdf", writer: writer) do |locator|
      FileDraft.create!(attrs.merge(FileURLPath: locator))
    end

    redirect_to documents_path, notice: "Document generated."
  rescue DocumentCreation::Failure
    render plain: "Unable to create document. Please try again.", status: :service_unavailable
  end


  private

  def render_legacy_agreement_format_error(error)
    if request.format.json?
      render json: { error: error.message }, status: :unprocessable_entity
    else
      render plain: error.message, status: :unprocessable_entity
    end
  end

  def render_agreement_revision_failure
    message = "Unable to revise agreement. Please try again."
    if request.format.json?
      render json: { error: message }, status: :service_unavailable
    else
      render plain: message, status: :service_unavailable
    end
  end

  # Call only after the record has passed find_file_for_user authorization.
  def deliver_document(file, disposition:)
    response.headers["Cache-Control"] = "private, no-store"
    path = DocumentStorage.configured.resolve(file.FileURLPath)
    return render plain: "Generated file is empty", status: :unprocessable_entity if path.size.zero?

    mime_type = begin
      Marcel::MimeType.for(path.to_path, extension: File.extname(path))
    rescue StandardError
      nil
    end

    response.headers["X-Content-Type-Options"] = "nosniff"
    # Stored bytes are untrusted, including generated HTML. Keep parent access
    # for the agreement scroll check, but never allow document scripts to run.
    # Native PDF viewers must remain usable without sandbox restrictions.
    unless mime_type == "application/pdf"
      response.headers["Content-Security-Policy"] = "sandbox allow-same-origin"
    end

    if file.agreement_to_mediate? && mime_type == "text/html" && !file.agreement_fully_executed?
      original = path.binread
      html = AgreementSignature.new.clear_unrecorded_signatures(original, file: file)
      if html != original
        return send_data html, filename: "#{file.FileName}#{File.extname(path)}",
                               type: mime_type, disposition: disposition
      end
    end

    send_file path,
              filename: "#{file.FileName}#{File.extname(path)}",
              type: mime_type || "application/octet-stream",
              disposition: disposition
  rescue DocumentStorage::InvalidLocator, DocumentStorage::MissingFile
    render plain: "File not found", status: :not_found
  rescue DocumentStorage::Unavailable, DocumentStorageConfiguration::InvalidConfiguration, SystemCallError, IOError
    render plain: "Document storage is unavailable", status: :service_unavailable
  end

  AGREEMENT_FIELDS = %w[landlord_name tenant_name address negotiation_date reason money_owed monthly_rent
                        regular_rent_due_day regular_rent_arrangement regular_rent_change_details
                        best_option vacate_date rent_owed late_fees utilities other_charges
                        other_charges_description payment_lump_sum lump_sum_amount lump_sum_date
                        payment_monthly monthly_payment_amount monthly_payment_months monthly_payment_day landlord_representative tenant_representative
                        monthly_payment_start payment_final final_payment_amount final_payment_date payment_custom_schedule rent_period late_fees_description utilities_period
                        credits_description credits_amount reductions_description reductions_amount
                        conditional_reduction forgiveness_amount forgiveness_deadline
                        forgiveness_conditions forgiveness_remaining_amount forgiveness_failure_result
                        unresolved_payment_issues unresolved_payment_details payment_method payment_method_other_description payment_recipient_instructions payment_application payment_application_instructions
                        payment_portal_name].concat(PayAndStayTerms::FIELDS).freeze
  AGREEMENT_COMMON_FIELDS = %w[landlord_name tenant_name address negotiation_date reason money_owed
                               monthly_rent best_option].freeze
  ORIGINAL_PAY_AND_STAY_TEMPLATE = "documents/templates/pay_and_stay_original".freeze
  ORIGINAL_PAY_AND_STAY_FIELDS = ((AGREEMENT_COMMON_FIELDS - ["best_option"]) + %w[
    rent_owed late_fees utilities other_charges other_charges_description additional_terms
    payment_lump_sum lump_sum_amount lump_sum_date payment_monthly monthly_payment_amount
    monthly_payment_months monthly_payment_day monthly_payment_start payment_final
    final_payment_amount final_payment_date payment_method payment_method_other_description
  ]).freeze

  def decide_mediator_suggestion(file, conversation, decision)
    result = :unavailable
    validation_error = nil
    accepted_changes = []

    # Keep access, reviewer eligibility, and proposal checks locked through publication.
    file.with_lock do
      conversation = agreement_conversation(file)
      conversation.lock! if conversation
      unless find_file_for_user(file.FileID) && conversation && agreement_party?(conversation)
        result = :unavailable
        next
      end
      proposal = file.agreement_proposal
      role = agreement_review_party(conversation)

      item = file.agreement_suggestion_items.find do |suggestion|
        suggestion[:key] == params[:field].to_s
      end

      if mediator_agreement_reviewer?(proposal, conversation) &&
        role.present? &&
        file.agreement_editable? &&
        file.agreement_suggestions_pending? &&
        proposal["base_version"].to_i == file.AgreementVersion &&
        item.present?

        changes = proposal["changes"]
        fields = item[:fields]

        valid_item = fields.all? do |field|
          change = changes[field]
          change["decision"] == "pending" &&
            change.fetch("party_decisions", {})[role] == "pending"
        end

        if valid_item
          fields.each do |field|
            changes[field]["party_decisions"][role] = decision
          end

          statuses = fields.map do |field|
            mediator_suggestion_decision_status(changes[field])
          end

          status = if statuses.all? { |value| value == "accepted" }
                    "accepted"
                  elsif statuses.any? { |value| value == "rejected" }
                    "rejected"
                  else
                    "pending"
                  end

          if status == "accepted"
            accepted_terms = file.agreement_terms.dup

            fields.each do |field|
              change = changes[field]

              if change["to"].present?
                accepted_terms[field] = change["to"]
              else
                accepted_terms.delete(field)
              end
            end

            accepted_terms = accepted_terms.except(*MoveOutTerms.inactive_fields(accepted_terms)) if file.revised_move_out?
            accepted_terms = CustomResolutionTerms.normalize(accepted_terms) if file.custom_resolution?
            if !(validation_error = agreement_terms_error(accepted_terms, file: file))
              accepted_changes = fields.filter_map do |field|
                change = changes[field]
                next if change["from"] == change["to"]

                "#{helpers.agreement_field_label(field)}: " \
                  "#{helpers.agreement_field_value(field, change['from'])} → " \
                  "#{helpers.agreement_field_value(field, change['to'])}"
              end

              fields.each { |field| changes[field]["decision"] = "accepted" }

              html = render_accepted_agreement(file, accepted_terms)

              DocumentRevision.new.call(
                file: file, extension: "html",
                writer: ->(_original, path, _locked) { File.write(path, html) }
              ) do
                file.AgreementTerms = JSON.generate(accepted_terms)
                file.AgreementVersion += 1

                file.clear_agreement_signatures

                proposal["base_version"] = file.AgreementVersion
                file.AgreementProposal = JSON.generate(proposal)
              end
              result = :updated
            else
              fields.each do |field|
                changes[field]["party_decisions"][role] = "pending"
              end
              result = :invalid_payment
            end
          elsif status == "rejected"
            fields.each { |field| changes[field]["decision"] = "rejected" }
            file.update!(AgreementProposal: JSON.generate(proposal))
            result = :rejected
          else
            file.update!(AgreementProposal: JSON.generate(proposal))
            result = :pending
          end
        end
      end
    end

    if result == :updated
      notify_agreement_participants(
        conversation,
        file,
        "agreement_revised",
        changes: accepted_changes
      )

      announce_agreement(
        conversation,
        "Both the landlord and tenant have approved a suggested change. " \
        "The agreement has been updated."
      )
    end

    if %i[updated rejected pending].include?(result)
      ActionCable.server.broadcast(
        "document_#{file.FileID}",
        { type: "agreement_proposal_update", actor_id: @user.UserID }
      )
    end

    focus_path = view_file_path(
      file.FileID,
      anchor: "suggestion-#{params[:field]}"
    )

    message = case result
              when :updated then "Both parties accepted. The agreement has been updated."
              when :rejected then "Suggestion rejected."
              when :pending then "Decision saved. Waiting for the other party."
              when :invalid_payment then validation_error
              else "This suggestion is no longer available. Refresh the agreement."
              end

    if request.format.json?
      render json: (
        %i[updated rejected pending].include?(result) ?
          { status: result, field: params[:field], decision: decision } :
          { error: message }
      ), status: (
        result == :unavailable ? :conflict :
        result == :invalid_payment ? :unprocessable_entity : :ok
      )
    else
      redirect_to focus_path,
                  (result == :unavailable || result == :invalid_payment ?
                    { alert: message } : { notice: message })
    end
  rescue DocumentRevision::Failure
    render_agreement_revision_failure
  end

  def counteroffer_mediator_suggestion(file, conversation)
    result = :unavailable
    validation_error = nil
    values = nil

    file.with_lock do
      proposal = file.agreement_proposal

      item = file.agreement_suggestion_items.find do |suggestion|
        suggestion[:key] == params[:field].to_s
      end

      if file.agreement_editable? &&
        file.agreement_suggestions_pending? &&
        proposal["base_version"].to_i == file.AgreementVersion &&
        item.present? &&
        mediator_can_counteroffer?(item, proposal, conversation)

        values = agreement_counteroffer_values(item, file)

        candidate_terms = file.agreement_terms.merge(values)

        if (validation_error = agreement_terms_error(candidate_terms, file: file))
          result = :invalid_payment
        elsif item[:fields].any? { |field|
                !values.key?(field) ||
                  (!file.revised_move_out? && !valid_agreement_counteroffer?(field, values[field], file: file))
              } ||
              item[:fields].all? { |field|
                values[field].to_s.strip ==
                  proposal["changes"][field]["to"].to_s
              }
          result = :invalid
        else
          decisions = mediator_counteroffer_decisions(conversation)

          item[:fields].each do |field|
            change = proposal["changes"][field]

            change["to"] = values[field].to_s.strip
            change["offered_by_id"] = @user.UserID
            change["party_decisions"] = decisions.dup
            change["decision"] = "pending"
          end

          file.update!(AgreementProposal: JSON.generate(proposal))
          result = :countered
        end
      end
    end

    if result == :countered
      ActionCable.server.broadcast(
        "document_#{file.FileID}",
        {
          type: "agreement_proposal_update",
          actor_id: @user.UserID
        }
      )
    end

    focus_path = view_file_path(
      file.FileID,
      anchor: "suggestion-#{params[:field]}"
    )

    message = case result
              when :countered
                "Counteroffer submitted. Waiting for the other party."
              when :invalid_payment
                validation_error
              when :invalid
                "Enter a valid counteroffer that differs from the current offer."
              else
                "This suggestion is no longer available. Refresh the agreement."
              end

    if request.format.json?
      render json: (
        result == :countered ?
          { status: "countered", field: params[:field] } :
          { error: message }
      ), status: (
        result == :countered ? :ok :
        result == :unavailable ? :conflict : :unprocessable_entity
      )
    elsif (file.AgreementTemplate == "b" || file.revised_move_out? || file.custom_resolution? || file.agreement_to_mediate?) && [:invalid, :invalid_payment].include?(result)
      render_counteroffer_error(values, message)
    else
      redirect_to focus_path,
                  (result == :countered ?
                    { notice: message } : { alert: message })
    end
  end

  def render_counteroffer_error(values, message)
    show
    return if performed?

    @counteroffer_error_field = params[:field].to_s
    @submitted_counteroffer = values
    @agreement_editor_error = message
    render :show, status: :unprocessable_entity
  end

  def custom_resolution_params
    fields = CustomResolutionTerms.groups(params.keys).values.flatten
    params.permit(*fields).to_h
  end

  def agreement_terms_from_params(template)
    return custom_resolution_params if template == CustomResolutionTerms::TEMPLATE
    terms = params.permit(*agreement_fields_for_template(template)).to_h
    terms.transform_values! { |value| value.to_s.strip } if [MoveOutTerms::TEMPLATE, AgreementToMediateTerms::TEMPLATE].include?(template)
    terms
  end

  def agreement_editable_fields(file)
    if file.AgreementTemplate == "b" && !file.revised_pay_and_stay? &&
       stored_agreement_template(file) == ORIGINAL_PAY_AND_STAY_TEMPLATE
      return ORIGINAL_PAY_AND_STAY_FIELDS
    end

    agreement_fields_for_template(file.AgreementTemplate, legacy: !file.revised_pay_and_stay?)
  end

  def agreement_fields_for_template(template, legacy: false)
    payment_fields = (1..6).flat_map { |i| ["amount#{i}", "date#{i}"] }

    case template
    when AgreementToMediateTerms::TEMPLATE
      AgreementToMediateTerms::FIELDS
    when CustomResolutionTerms::TEMPLATE
      CustomResolutionTerms::FIELDS
    when MoveOutTerms::TEMPLATE
      MoveOutTerms::FIELDS
    when "a"
      AGREEMENT_COMMON_FIELDS + %w[vacate_date additional_terms] + payment_fields
    when "b"
      fields = (AGREEMENT_FIELDS - ["vacate_date"]) + PayAndStayTerms::CUSTOM_ROWS.flatten
      legacy ? fields - (PayAndStayTerms::FIELDS - (PayAndStayTerms::LEGACY_ASSISTANCE_FIELDS + ["additional_terms"])) - ["payment_portal_name"] : fields
    else
      AGREEMENT_COMMON_FIELDS + payment_fields
    end
  end

  def normalize_pay_and_stay_terms!(terms)
    terms.transform_values! { |value| value.to_s.strip }
    if terms.key?("payment_method")
      terms["payment_method"] = PayAndStayTerms.payment_methods(terms["payment_method"]).join(",")
    end
    terms
  end

  def agreement_counteroffer_values(item, file)
    submitted = params.fetch(:counteroffer, ActionController::Parameters.new)
    return {} unless submitted.is_a?(ActionController::Parameters)

    values = submitted.permit(*item[:fields]).to_h
    if file.revised_pay_and_stay? && item[:fields].include?("payment_method") && submitted[:payment_method].is_a?(Array)
      values["payment_method"] = submitted.permit(payment_method: [])[:payment_method].to_a.join(",")
    end
    normalize_pay_and_stay_terms!(values) if file.AgreementTemplate == "b"
    if file.custom_resolution? && item[:fields].all? { |field| values.key?(field) }
      normalized = CustomResolutionTerms.normalize(values)
      values = values.keys.index_with { |field| normalized.fetch(field, "") }
    end
    values.transform_values! { |value| value.to_s.strip } if file.revised_move_out?
    values
  end

  def stored_agreement_template(file)
    return agreement_template_file(file.AgreementTemplate) unless file.AgreementTemplate == "b" && !file.revised_pay_and_stay?

    headings = legacy_pay_and_stay_document(file).css("h3").map { |heading| heading.text.strip }
    if headings.include?("9. Signatures and Final Agreement")
      case headings.grep(/\A2\. /)
      when ["2. Amount Currently Owed"] then return ORIGINAL_PAY_AND_STAY_TEMPLATE
      when ["2. Agreed Payment Amount"] then return "documents/templates/pay_and_stay_legacy"
      end
    end
    raise LegacyAgreementFormatError, "This older Pay-and-Stay format could not be identified. Its saved agreement was preserved."
  end

  def legacy_pay_and_stay_document(file)
    @legacy_pay_and_stay_documents ||= {}
    @legacy_pay_and_stay_documents[file.FileURLPath] ||= begin
      path = DocumentStorage.configured.resolve(file.FileURLPath)
      Nokogiri::HTML(path.binread, nil, "UTF-8")
    end
  rescue DocumentStorage::InvalidLocator, DocumentStorage::MissingFile, DocumentStorage::Unavailable,
         DocumentStorageConfiguration::InvalidConfiguration, SystemCallError, IOError
    raise LegacyAgreementFormatError, "The saved Pay-and-Stay agreement could not be read for editing."
  end

  def render_accepted_agreement(file, terms)
    template = stored_agreement_template(file)
    if template == ORIGINAL_PAY_AND_STAY_TEMPLATE
      current = file.agreement_terms
      original = legacy_pay_and_stay_document(file)
      original_date = original.at_css('[data-agreement-field="negotiation_date"]')&.text
      assign_agreement_template_variables("b", current)
      @date = original_date
      baseline = render_to_string(template: template, formats: [:html], layout: false)
      unless legacy_agreement_without_signatures(original.dup) == legacy_agreement_without_signatures(Nokogiri::HTML(baseline, nil, "UTF-8"))
        raise LegacyAgreementFormatError, "This saved Pay-and-Stay agreement differs from its original template. The change could not be applied safely."
      end
    end

    assign_agreement_template_variables(file.AgreementTemplate, terms)
    @date = original_date if original_date && current["negotiation_date"] == terms["negotiation_date"]
    render_to_string(template: template, formats: [:html], layout: false)
  end

  def legacy_agreement_without_signatures(document)
    document.css(".signature-section .signature-line, .signature-section .date-line").each do |slot|
      slot.content = "___________"
    end
    document.to_html.lines.map(&:rstrip).join("\n")
  end

  def valid_pay_and_stay_unresolved_issues?(terms)
    selection = terms["unresolved_payment_issues"].to_s.strip

    return false unless %w[yes no].include?(selection)

    return false if selection == "yes" &&
                    terms["unresolved_payment_details"].to_s.strip.blank?

    true
  end

  def valid_pay_and_stay_regular_rent?(terms)
    due_day = terms["regular_rent_due_day"].to_s.strip
    arrangement = terms["regular_rent_arrangement"].to_s.strip

    return false unless valid_pay_and_stay_rent_due?(due_day)

    return false unless %w[unchanged modified].include?(arrangement)

    if arrangement == "modified"
      return false if terms["regular_rent_change_details"].to_s.strip.blank?
    end

    true
  end

  def valid_pay_and_stay_rent_due?(value)
    return (1..31).cover?(value.to_i) if value.match?(/\A\d{1,2}\z/)

    value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && Date.iso8601(value).present?
  rescue Date::Error
    false
  end

  def valid_pay_and_stay_payment_times?(terms)
    (1..6).all? do |i|
      value = terms["time#{i}"].to_s.strip

      value.blank? ||
        value.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
    end
  end

  def valid_pay_and_stay_assistance_status?(terms)
    %w[not_submitted pending approved].include?(terms["assistance_status"].to_s.strip)
  end

  def valid_pay_and_stay_rental_assistance?(terms)
    %w[none arrangement].include?(terms["rental_assistance"].to_s.strip)
  end

  def valid_pay_and_stay_conditional_reduction?(terms)
    selection = terms["conditional_reduction"].to_s.strip

    return false unless %w[none conditional].include?(selection)
    return true if selection == "none"

    required_fields = %w[
      forgiveness_amount
      forgiveness_deadline
      forgiveness_conditions
      forgiveness_remaining_amount
      forgiveness_failure_result
    ]

    return false unless required_fields.all? { |field| terms[field].to_s.strip.present? }

    amount_fields = %w[forgiveness_amount forgiveness_remaining_amount]

    return false unless amount_fields.all? do |field|
      terms[field].to_s.strip.match?(/\A\d+(?:\.\d{1,2})?\z/)
    end

    Date.iso8601(terms["forgiveness_deadline"].to_s.strip)
    true
  rescue Date::Error
    false
  end

  def valid_pay_and_stay_payment_application?(terms)
    application = terms["payment_application"].to_s
    instructions = terms["payment_application_instructions"].to_s.strip

    return false unless %w[standard different].include?(application)
    return false if application == "different" && instructions.blank?

    true
  end

  def agreement_terms_error(terms, file:)
    return CustomResolutionTerms.error(CustomResolutionTerms.normalize(terms)) if file.custom_resolution?
    return MoveOutTerms.error(terms) if file.revised_move_out?
    return AgreementToMediateTerms.error(terms) if file.agreement_to_mediate?

    if file.AgreementTemplate == "b"
      if !file.revised_pay_and_stay? && stored_agreement_template(file) == ORIGINAL_PAY_AND_STAY_TEMPLATE
        current = file.agreement_terms
        unsupported = ((current.keys | terms.keys) - ORIGINAL_PAY_AND_STAY_FIELDS).any? do |field|
          current[field].to_s != terms[field].to_s
        end
        return "This change cannot be displayed in the original Pay-and-Stay format." if unsupported
        if terms["payment_method"].to_s != current["payment_method"].to_s &&
           !["", "online_portal", "money_order", "cashiers_check", "other"].include?(terms["payment_method"].to_s)
          return "Select a payment method available in the original Pay-and-Stay agreement."
        end
      end
      revised = file.revised_pay_and_stay?
      return pay_and_stay_terms_error(terms, complete: revised) ||
        (PayAndStayTerms.release_error(terms, previous: file.agreement_terms) if revised)
    end

    if (1..6).any? { |number| terms["date#{number}"].present? && terms["amount#{number}"].blank? }
      "A payment date needs a payment amount."
    end
  end

  def pay_and_stay_terms_error(terms, complete:)
    checks = [
      [%w[unresolved_payment_issues], :valid_pay_and_stay_unresolved_issues?, "Select Yes or No for unresolved payment issues and enter details for Yes."],
      [%w[regular_rent_arrangement regular_rent_due_day], :valid_pay_and_stay_regular_rent?, "Enter a valid regular rent due day or date and complete the selected rent arrangement."],
      [%w[payment_application], :valid_pay_and_stay_payment_application?, "Select how payments will be applied and provide instructions if applied differently."],
      [%w[conditional_reduction], :valid_pay_and_stay_conditional_reduction?, "Select a conditional reduction option and complete its amounts, deadline, conditions, and result if selected."]
    ]
    checks.each do |fields, check, message|
      return message if (complete || fields.any? { |field| terms.key?(field) }) && !send(check, terms)
    end
    return "Enter valid payment due times." unless valid_pay_and_stay_payment_times?(terms)
    return "Select valid payment methods." unless PayAndStayTerms.valid_payment_methods?(terms["payment_method"])

    unless complete
      if (1..6).any? { |number| terms["date#{number}"].present? && terms["amount#{number}"].blank? }
        return "A payment date needs a payment amount."
      end
      if terms["rental_assistance"].present? && !valid_pay_and_stay_rental_assistance?(terms)
        return "Select a valid rental assistance option."
      end
      if terms["assistance_status"].present? && !valid_pay_and_stay_assistance_status?(terms)
        return "Select a valid rental assistance application status."
      end
      return
    end

    required = %w[landlord_name tenant_name address negotiation_date reason money_owed monthly_rent payment_recipient_instructions]
    missing = required.find { |field| terms[field].blank? }
    return "Enter the #{helpers.agreement_field_label(missing).downcase}." if missing

    methods = PayAndStayTerms.payment_methods(terms["payment_method"])
    return "Select at least one payment method." if methods.empty?
    return "Enter the online portal name or address." if methods.include?("online_portal") && terms["payment_portal_name"].blank?
    return "Describe the other payment method." if methods.include?("other") && terms["payment_method_other_description"].blank?

    invalid = agreement_fields_for_template("b").find do |field|
      terms[field].present? && !valid_agreement_counteroffer?(field, terms[field])
    end
    return "Enter a valid #{helpers.agreement_field_label(invalid).downcase}." if invalid

    PayAndStayTerms.payment_plan_error(terms) || PayAndStayTerms.breakdown_error(terms) ||
      PayAndStayTerms.payment_total_error(terms) ||
      PayAndStayTerms.validation_error(terms, complete: true)
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

  def notify_agreement_participants(conversation, file, event, changes: [])
    signing_status = if file.agreement_suggestions_pending?
      "Suggestions remain pending. Review them before signing."
    else
      "No suggestions remain pending. The agreement is ready for signing."
    end
    recipients = if file.agreement_to_mediate?
      conversation.notification_participants
    else
      [conversation.tenant, conversation.landlord].compact.uniq(&:UserID)
    end
    recipients.each do |recipient|
      next if recipient.UserID == @user.UserID

      MediationNotifications.agreement_notification(recipient, conversation.ConversationID, event, file.FileID,
                                                    @user, changes, signing_status)
    end
  end

  def notify_agreement_review_completed(conversation, file, completed_round)
    event = completed_round[:countered] ? "agreement_suggestions_pending" : "agreement_ready"
    notify_agreement_participants(conversation, file, event)
  end

  def valid_agreement_counteroffer?(field, raw_value, file: nil)
    value = raw_value.to_s.strip
    if file&.agreement_to_mediate?
      return AgreementToMediateTerms::FIELDS.include?(field) && value.length <= 255 &&
        (value.present? || !AgreementToMediateTerms::REQUIRED.include?(field))
    end
    if file&.custom_resolution?
      spec = CustomResolutionTerms.definition(field)
      return spec && (value.blank? || CustomResolutionTerms.valid_value?(value, spec[1]))
    end
    return MoveOutTerms.value_valid?(field, value) if file&.revised_move_out?

    if field.match?(/\Atime[1-6]\z/)
      return value.blank? || value.match?(/\A(?:[01]\d|2[0-3]):[0-5]\d\z/)
    end
    return %w[unchanged modified].include?(value) if field == "regular_rent_arrangement"
    return valid_pay_and_stay_rent_due?(value) if field == "regular_rent_due_day"
    return %w[yes no].include?(value) if field == "unresolved_payment_issues"
    return %w[standard different].include?(value) if field == "payment_application"
    return %w[none conditional].include?(value) if field == "conditional_reduction"
    return PayAndStayTerms.valid_value?(field, value) if PayAndStayTerms::FIELDS.include?(field)
    return false if value.length > (field == "additional_terms" ? 5000 : 255)
    return false if %w[landlord_name tenant_name address negotiation_date reason money_owed vacate_date].include?(field) && value.blank?
    return value.blank? || %w[1 0].include?(value) if PayAndStayTerms::PAYMENT_OPTIONS.key?(field)
    return PayAndStayTerms.valid_payment_methods?(value) if field == "payment_method"
    return value.blank? || value.match?(/\A\d+(?:\.\d{1,2})?\z/) if field.match?(/\Aamount[1-6]\z/) ||
      %w[money_owed monthly_rent rent_owed late_fees utilities other_charges lump_sum_amount monthly_payment_amount final_payment_amount forgiveness_amount forgiveness_remaining_amount credits_amount reductions_amount].include?(field)
    return value.blank? || (Date.iso8601(value) && true) if field.match?(/\Adate[1-6]\z/) ||
      %w[negotiation_date vacate_date lump_sum_date monthly_payment_start final_payment_date forgiveness_deadline].include?(field)
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

  def new_agreement_template(template)
    return MoveOutTerms::TEMPLATE if template.blank? || template == "a"
    return AgreementToMediateTerms::TEMPLATE if template == "c"

    template
  end

  def agreement_template_file(template)
    {
      AgreementToMediateTerms::TEMPLATE => "documents/templates/agreement_to_mediate_v1",
      CustomResolutionTerms::TEMPLATE => "documents/templates/custom_resolution_v1",
      MoveOutTerms::TEMPLATE => "documents/templates/move_out_v1",
      "a" => "documents/templates/agree_to_vacate",
      "b" => "documents/templates/pay_and_stay",
      "c" => "documents/templates/mediation_agreement"
    }.fetch(template.to_s) do
      raise ActionController::BadRequest, "Unknown agreement template"
    end
  end

  def agreement_template_name(template)
    {
      AgreementToMediateTerms::TEMPLATE => "Agreement to Mediate",
      CustomResolutionTerms::TEMPLATE => "Custom Resolution Agreement",
      MoveOutTerms::TEMPLATE => "Move-Out Agreement",
      "a" => "Move-Out Agreement",
      "b" => "Pay-and-Stay Agreement",
      "c" => "Agreement to Mediate"
    }.fetch(template.to_s, "Unknown Agreement")
  end

  def assign_agreement_template_variables(template, terms)
    return @agreement_to_mediate_terms = terms if template == AgreementToMediateTerms::TEMPLATE
    return @custom_resolution_terms = terms if template == CustomResolutionTerms::TEMPLATE
    return @move_out_terms = terms if template == MoveOutTerms::TEMPLATE

    @landlord_representative = terms["landlord_representative"].to_s
    @tenant_representative = terms["tenant_representative"].to_s
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
    @additional_terms = terms["additional_terms"].to_s
    @monthly_rent = terms["monthly_rent"].to_s
    @vacate_date = terms["vacate_date"] if template == "a"
    @schedule = (1..6).filter_map do |i|
      amount = terms["amount#{i}"].to_s
      if amount.present? || (template == "b" && @agreement_editor_preview &&
                             (terms["date#{i}"].present? || terms["time#{i}"].present?))
        [i, amount, terms["date#{i}"]]
      end
    end.sort_by do |index, _amount, due_date|
      parsed_date = begin
        Date.iso8601(due_date.to_s)
      rescue Date::Error
        Date.new(9999, 12, 31)
      end

      [parsed_date, index]
    end
    if template == "b"
      %w[rent_owed late_fees utilities other_charges other_charges_description lump_sum_amount
         lump_sum_date monthly_payment_amount monthly_payment_months monthly_payment_day
         monthly_payment_start final_payment_amount final_payment_date payment_method
         rent_period late_fees_description utilities_period
         credits_description credits_amount reductions_description reductions_amount
         regular_rent_due_day regular_rent_arrangement regular_rent_change_details
         unresolved_payment_issues unresolved_payment_details
         conditional_reduction forgiveness_amount forgiveness_deadline
         forgiveness_conditions forgiveness_remaining_amount forgiveness_failure_result
         payment_method_other_description payment_recipient_instructions payment_application payment_application_instructions payment_portal_name].concat(PayAndStayTerms::FIELDS).each do |field|
        instance_variable_set("@#{field}", terms[field].to_s)
      end
      if @additional_terms_selection.blank? && @additional_terms.present?
        @additional_terms_selection = "included"
        @other_additional_terms = "1"
      end
      %w[payment_lump_sum payment_monthly payment_final payment_custom_schedule].each do |field|
        instance_variable_set("@#{field}", terms[field] == "1")
      end
      (1..6).each do |i|
        instance_variable_set("@time#{i}", terms["time#{i}"].to_s)
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

  def assigned_agreement_mediator_name(conversation)
    mediator = conversation.mediator if conversation&.MediatorAssigned?
    AgreementToMediateTerms.account_name(mediator) if mediator&.mediator?
  end

  def assigned_mediator_for_generation?
    return false unless @user.mediator? && params[:conversation_id].present?

    conversation = @template_conversation || PrimaryMessageGroup.find_by(ConversationID: params[:conversation_id])
    conversation&.MediatorAssigned? && conversation.MediatorID == @user.UserID
  end

  def authorize_mediation_template
    return unless new_agreement_template(params[:template]) == AgreementToMediateTerms::TEMPLATE

    head :forbidden unless assigned_mediator_for_generation?
  end

  def agreement_suggester?(conversation)
    return false unless conversation

    agreement_party?(conversation) ||
      (
        @user.mediator? &&
        conversation.MediatorID == @user.UserID &&
        conversation.MediatorAssigned?
      )
  end

  def mediator_agreement_proposal?(proposal)
    proposal["mediator_proposal"] == true
  end

  def mediator_agreement_reviewer?(proposal, conversation)
    return false unless mediator_agreement_proposal?(proposal)
    return false unless agreement_party?(conversation)

    proposal.fetch("reviewer_ids", []).map(&:to_i).include?(@user.UserID)
  end

  def agreement_review_party(conversation)
    return "tenant" if @user.UserID == conversation.TenantID
    return "landlord" if @user.UserID == conversation.LandlordID

    nil
  end

  def mediator_suggestion_decision_status(change)
    decisions = change.fetch("party_decisions", {})

    return "rejected" if decisions.value?("rejected")
    return "accepted" if decisions["tenant"] == "accepted" &&
                        decisions["landlord"] == "accepted"

    "pending"
  end

  def mediator_counteroffer_decisions(conversation)
    role = agreement_review_party(conversation)
    return nil unless %w[tenant landlord].include?(role)

    other_role = role == "tenant" ? "landlord" : "tenant"

    {
      role => "accepted",
      other_role => "pending"
    }
  end

  def mediator_can_counteroffer?(item, proposal, conversation)
    role = agreement_review_party(conversation)
    return false unless role.present?
    return false unless mediator_agreement_reviewer?(proposal, conversation)

    item[:fields].all? do |field|
      change = proposal.fetch("changes", {})[field]

      change.is_a?(Hash) &&
        change["decision"] == "pending" &&
        change.fetch("party_decisions", {})[role] == "pending" &&
        item[:offered_by_id].to_i != @user.UserID
    end
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
    party_names = %i[landlord_name tenant_name].map do |field|
      params[field].to_s.gsub(/[^\w\- ]/, "").squeeze(" ").strip.presence
    end
    document_type = {
      AgreementToMediateTerms::TEMPLATE => "Agreement to Mediate",
      CustomResolutionTerms::TEMPLATE => "Custom Resolution Agreement",
      MoveOutTerms::TEMPLATE => "Move-Out Agreement",
      "b" => "Pay and Stay Agreement"
    }.fetch(template.to_s, "Agreement")

    [ *party_names, document_type ].compact.join(" - ")
  end

  def find_file_for_user(id)
    FileDraft.find_viewable_by(@user, id)
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

  def authorize_template_conversation
    conversation_id = params[:conversation_id].presence || params[:id].presence
    return unless conversation_id

    @template_conversation = PrimaryMessageGroup.find_by(ConversationID: conversation_id)
    head :not_found unless agreement_suggester?(@template_conversation)
  end

  def set_conversation_context
    conv_id = params[:conversation_id].presence || params[:id]
    return unless conv_id

    @conversation = ::MessageString.find_by(ConversationID: conv_id) rescue nil
    @pmg          = @template_conversation

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
