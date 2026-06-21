class MediatorMessagesController < ApplicationController
  before_action :require_login
  before_action :set_user
  before_action :set_side_conversation

  def create
    duplicate_exists = Message
      .where(
        SenderID: @user.UserID,
        ConversationID: @message_string.ConversationID,
        Contents: params[:Contents]
      )
      .where("MessageDate >= ?", 0.6.seconds.ago)
      .exists?

    if duplicate_exists
      respond_to do |format|
        format.json { render json: { duplicate: true }, status: :accepted }
        format.html { head :no_content }
      end
      return
    end

    @message = Message.new(
      ConversationID: @message_string.ConversationID,
      SenderID: @user.UserID,
      recipientID: @recipient_id,
      Contents: params[:Contents],
      MessageDate: Time.current
    )

    if @message.save
      if params[:file_id].present?
        file_draft = FileDraft.find_by(FileID: params[:file_id])

        if file_draft
          FileAttachment.create!(
            MessageID: @message.MessageID,
            FileID: file_draft.FileID
          )
        else
          Rails.logger.error "FileDraft not found with ID: #{params[:file_id]}"
        end
      end

      attachments_payload = @message
        .file_attachments
        .includes(:file_draft)
        .map do |attachment|
          file = attachment.file_draft
          next unless file

          extension = File.extname(file.FileURLPath.to_s).delete(".")
          is_html = file.FileTypes == "html" || extension == "html"
          {
            file_id: file.FileID,
            file_name: file.FileName,
            preview_url: view_file_path(file.FileID),
            download_url: download_file_path(file.FileID),
            view_url: view_file_path(file.FileID),
            sign_url: view_file_path(file.FileID),
            tenant_signature_required: is_html && file.respond_to?(:TenantSignature) ? !file.TenantSignature : false,
            landlord_signature_required: is_html && file.respond_to?(:LandlordSignature) ? !file.LandlordSignature : false,
            extension: extension.presence || file.FileTypes
          }
        end
        .compact

      sender_name = [ @user.FName, @user.LName ].compact.join(" ").squeeze(" ").strip
      sender_name = @user.CompanyName.presence || @user.Email if sender_name.blank?

      @message_string.update_column(:LastMessageSentDate, Time.current) if @message_string.respond_to?(:LastMessageSentDate)

      ActionCable.server.broadcast(
        "side_messages_#{@message_string.ConversationID}",
        {
          message_id: @message.id,
          contents: @message.Contents,
          sender_id: @message.SenderID,
          recipient_id: @message.recipientID,
          message_date: @message.MessageDate.strftime("%B %d, %Y %I:%M %p"),
          sender_role: @user.Role,
          sender_name: sender_name,
          attachments: attachments_payload
        }
      )

      respond_to do |format|
        format.json { render json: { success: true } }
        format.html { head :ok }
      end
    else
      respond_to do |format|
        format.json { render json: { error: @message.errors.full_messages }, status: :unprocessable_entity }
        format.html { head :unprocessable_entity }
      end
    end
  end

  private

  def set_user
    @user = User.find(session[:user_id])
  end

  def set_side_conversation
    @conversation_id = params[:conversation_id].to_i

    raise ActiveRecord::RecordNotFound, "Conversation id missing" if @conversation_id.zero?

    @message_string = MessageString.find_by!(ConversationID: @conversation_id)
    @side_group = SideMessageGroup.find_by!(ConversationID: @conversation_id, deleted_at: nil)

    if @user.Role == "Mediator"
      unless @side_group.MediatorID == @user.UserID
        raise ActiveRecord::RecordNotFound, "Mediator not assigned to this conversation"
      end
      @recipient_id = @side_group.UserID
    else
      unless @side_group.UserID == @user.UserID
        raise ActiveRecord::RecordNotFound, "User not part of this side conversation"
      end
      @recipient_id = @side_group.MediatorID
    end

    if params[:recipient_id].present?
      provided_recipient = params[:recipient_id].to_i
      unless provided_recipient.positive? && provided_recipient == @recipient_id
        raise ActiveRecord::RecordNotFound, "Recipient mismatch"
      end
    end
  end

  def require_login
    redirect_to login_path, alert: "Please log in to continue" unless session[:user_id]
  end
end
