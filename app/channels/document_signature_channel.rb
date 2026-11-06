class DocumentSignatureChannel < ApplicationCable::Channel
  def subscribed
    @file_id = params[:file_id]
    return reject unless authorized?

    stream_with_authorization("document_#{@file_id}") { authorized? }
  end

  def unsubscribed
    
  end

  private

  def authorized?
    file = FileDraft.find_viewable_by(subscription_user, @file_id)
    return false unless file

    @file_id = file.FileID
    true
  end
end
