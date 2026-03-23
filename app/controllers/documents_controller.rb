# app/controllers/documents_controller.rb
require "fileutils"
require "pathname"
require "securerandom"
require "prawn"
require "prawn/table"

class DocumentsController < ApplicationController
  before_action :require_login
  before_action :set_user
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
    template = params[:template] || "a"


    @landlord = params[:landlord_name].to_s
    @tenant = params[:tenant_name].to_s
    @address = params[:address].to_s
    @date = begin
      (params[:negotiation_date].presence || Date.today).to_date.strftime("%B %d, %Y")
    rescue StandardError
      Date.today.strftime("%B %d, %Y")
    end
    @reason = params[:reason].to_s
    @money_owed = params[:money_owed].to_s
    @monthly_rent = params[:monthly_rent].to_s
    @conversation_id = params[:conversation_id]
    @vacate_date = params[:vacate_date] if template == "a"

    # Pay and Stay specific fields
    if template == "b"
      @rent_owed = params[:rent_owed].to_s
      @late_fees = params[:late_fees].to_s
      @utilities = params[:utilities].to_s
      @other_charges = params[:other_charges].to_s
      @other_charges_description = params[:other_charges_description].to_s
      
      # Payment plan options
      @payment_lump_sum = params[:payment_lump_sum] == "1"
      @lump_sum_amount = params[:lump_sum_amount].to_s
      @lump_sum_date = params[:lump_sum_date].to_s
      
      @payment_monthly = params[:payment_monthly] == "1"
      @monthly_payment_amount = params[:monthly_payment_amount].to_s
      @monthly_payment_months = params[:monthly_payment_months].to_s
      @monthly_payment_day = params[:monthly_payment_day].to_s
      @monthly_payment_start = params[:monthly_payment_start].to_s
      
      @payment_final = params[:payment_final] == "1"
      @final_payment_amount = params[:final_payment_amount].to_s
      @final_payment_date = params[:final_payment_date].to_s
      
      # Payment method
      @payment_method = params[:payment_method].to_s
      @payment_method_other_description = params[:payment_method_other_description].to_s
      
      # Additional terms
      @additional_terms = params[:additional_terms].to_s
    end

    conversation = PrimaryMessageGroup.find_by(ConversationID: @conversation_id) if @conversation_id.present?

    # Build payment schedule
    @schedule = []
    params.to_unsafe_h.each do |key, value|
      next unless key.to_s =~ /\Aamount(\d+)\z/
      index = Regexp.last_match(1).to_i
      amount = value.to_s
      due_on = params["date#{index}"]
      @schedule << [ index, amount, due_on ] if amount.present?
    end
    @schedule.sort_by! { |i, _, _| i }


    template_file = case template
    when "a" then "documents/templates/agree_to_vacate"
    when "b" then "documents/templates/pay_and_stay"
    when "c" then "documents/templates/mediation_agreement"
    else "documents/templates/agree_to_vacate"
    end

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
      FileName: "Generated Agreement",
      FileTypes: "html",
      FileURLPath: "userFiles/#{file_id}#{ext}",
      CreatorID: @user[:UserID],
      TenantSignature: false,
      LandlordSignature: false
    }
    attrs[pk_name] = pk_value if pk_name && pk_value

    file_draft = FileDraft.create!(attrs)


    if conversation && @conversation_id.present?
      # Create a message in the conversation announcing the document
      message_body = "📄 A new agreement document (#{@template_name}) has been generated."

      message = Message.create!(
        ConversationID: @conversation_id,
        SenderID: @user[:UserID],
        Contents: message_body,
        MessageDate: Time.current,
        recipientID: nil
      )


      FileAttachment.create!(
        MessageID: message.MessageID,
        FileID: file_draft.FileID
      )

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
          message_date: message.MessageDate.strftime("%B %d, %Y %I:%M %p"),
          sender_role: @user[:Role],
          sender_name: sender_name,
          attachments: attachments_payload,
          broadcast: true
        }
      )

      redirect_to message_path(@conversation_id), notice: "Document generated and shared in the conversation."
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

    # Load conversation if document is linked to one
    file_attachment = FileAttachment.find_by(FileID: @file.FileID)
    if file_attachment
      message = Message.find_by(MessageID: file_attachment.MessageID)
      if message
        @conversation = PrimaryMessageGroup.find_by(ConversationID: message.ConversationID)
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
      end
    end
  end

  # Handle document signing
  def apply_signature
    @file = find_file_for_user(params[:id])
    return render plain: "File not found", status: :not_found unless @file

    # Load conversation to verify authorization
    file_attachment = FileAttachment.find_by(FileID: @file.FileID)
    unless file_attachment
      flash[:alert] = "This document is not linked to a conversation and cannot be signed."
      return redirect_to view_file_path(@file.FileID)
    end

    message = Message.find_by(MessageID: file_attachment.MessageID)
    unless message
      flash[:alert] = "Unable to locate conversation for this document."
      return redirect_to view_file_path(@file.FileID)
    end

    conversation = PrimaryMessageGroup.find_by(ConversationID: message.ConversationID)
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

    # Update signature fields based on user role
    if is_landlord
      if @file.LandlordSignature
        flash[:notice] = "You have already signed this document."
        return redirect_to view_file_path(@file.FileID)
      end

      @file.LandlordSignature = true
      @file.LandlordSignedAt = Time.current
      @file.LandlordSignatureName = signature_name
    elsif is_tenant
      if @file.TenantSignature
        flash[:notice] = "You have already signed this document."
        return redirect_to view_file_path(@file.FileID)
      end

      @file.TenantSignature = true
      @file.TenantSignedAt = Time.current
      @file.TenantSignatureName = signature_name
    end

    if @file.save
      # Update the HTML file with the signature
      update_document_with_signature(@file, is_landlord, signature_name)

      # Send notification to conversation
      landlord = User.find_by(UserID: conversation.LandlordID)
      tenant = User.find_by(UserID: conversation.TenantID)

      signer_role = is_landlord ? "Landlord" : "Tenant"
      message_content = "#{signer_role} #{signature_name} has signed the document: #{@file.FileName}"

      Message.create!(
        ConversationID: conversation.ConversationID,
        SenderID: @user.UserID,
        Contents: message_content,
        MessageDate: Time.current
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
          Contents: "✓ Document fully executed: #{@file.FileName} - All parties have signed.",
          MessageDate: Time.current
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
      FileName: "Generated Agreement",
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
