class MediationsController < ApplicationController
  before_action :require_login
  before_action :set_user
  before_action :require_tenant_or_landlord_role, only: [ :create, :accept ]
  before_action :require_any_user_role, only: [ :end_conversation ]

  def index
    redirect_to messages_url
  end

  # lets a landlord or tenant accept a mediation request
  def accept
    mediation = PrimaryMessageGroup.find(params[:id])

    if @user.Role == "Landlord" && mediation.LandlordID == @user.UserID
      mediation.update!(accepted_by_landlord: true)
      mediation.reload
      redirect_to mediations_path, notice: "Negotiation accepted. You can now view and respond to the negotiation."
    elsif @user.Role == "Tenant" && mediation.TenantID == @user.UserID
      mediation.update!(accepted_by_tenant: true)
      mediation.reload
      redirect_to mediations_path, notice: "Negotiation accepted. You can now view and respond to the negotiation."
    else
      redirect_to mediations_path, alert: "You are not authorized to accept this negotiation."
    end
  end

  # lets a landlord or tenant reject a mediation request
  def reject
    mediation = PrimaryMessageGroup.find(params[:id])

    if (@user.Role == "Landlord" && mediation.LandlordID == @user.UserID) ||
       (@user.Role == "Tenant" && mediation.TenantID == @user.UserID)
      # Soft delete the mediation and message string
      mediation.update(deleted_at: Time.current, EndedBy: @user.UserID)
      mediation.linked_message_string&.update(deleted_at: Time.current)

      redirect_to messages_path, notice: "Negotiation request rejected."
    else
      redirect_to messages_path, alert: "You are not authorized to reject this negotiation."
    end
  end

  # Create a new mediation - tenants can select landlords, landlords can select tenants
  def create
    if @user.Role == "Tenant"
      landlord_email = params[:landlord_email].to_s.strip

      if params[:landlord_id].blank? && params[:landlord_email].to_s.strip.blank?
        redirect_to new_mediation_path, alert: "Please select a landlord or enter a landlord email."
        return
      end

      if params[:landlord_id].blank? && !valid_email_format?(landlord_email)
        redirect_to new_mediation_path, alert: "Please enter a valid landlord email."
        return
      end

      landlord = find_existing_landlord

      unless landlord
        send_landlord_invitation(params[:landlord_email])
        return
      end

      if landlord.persisted?
        Rails.logger.info "Landlord found: #{landlord.Email}, starting mediation and sending notification"
        start_mediation_with_existing_landlord(landlord)
        # Send notification email even if account exists
        LandlordMailer.mediation_request_notification(landlord.Email, @user).deliver_later
      else
        redirect_to messages_path, alert: "An unexpected error occurred. Please try again."
      end
    elsif @user.Role == "Landlord"
      tenant_email = params[:tenant_email].to_s.strip

      unless valid_email_format?(tenant_email)
        redirect_to new_mediation_path, alert: "Please enter a valid tenant email."
        return
      end

      tenant = find_existing_tenant

      if tenant&.persisted?
        Rails.logger.info "Tenant found: #{tenant.Email}, starting mediation and sending notification"
        start_mediation_with_existing_tenant(tenant)
        # Send notification email even if account exists
        TenantMailer.invitation_email(params[:tenant_email], @user).deliver_later
      else
        Rails.logger.info "No tenant found with email: #{params[:tenant_email]}, sending invitation"
        send_tenant_invitation(params[:tenant_email])
      end
    else
      redirect_to mediations_path, alert: "You are not authorized to start a negotiation."
    end
  end

  # Display the form to start a new mediation
  def new
    if @user.Role == "Tenant"
      # Load all landlords ordered by CompanyName
      @landlords = User.where(Role: "Landlord").order(:CompanyName)
    elsif @user.Role == "Landlord"
      # Landlords use email input only (no tenant list for privacy)
      # No need to load @tenants
    else
      redirect_to mediations_path, alert: "You are not authorized to start a negotiation."
    end
  end

  # end the negotiation/mediation
  def end_conversation
    @mediation = PrimaryMessageGroup.find(params[:id])
    if @mediation.deleted_at.nil?
      @mediation.update(deleted_at: Time.current, EndedBy: @user.UserID)
      @mediation.linked_message_string&.update(deleted_at: Time.current)

      # Decrement the mediator’s active mediation count if one is assigned
      if @mediation.MediatorID.present?
        mediator = Mediator.find_by(UserID: @mediation.MediatorID)
        if mediator && mediator.ActiveMediations > 0
          mediator.decrement!(:ActiveMediations)
        end
      end

    end
    if @user.Role == "Mediator"
      redirect_to third_party_mediations_path, notice: "Mediation terminated."
    else
      redirect_to mediation_survey_path(@mediation.ConversationID)
    end
  end

  # good faith questionaire
  def update_good_faith
    @mediation = PrimaryMessageGroup.find(params[:id])
    role = params[:role]
    good_faith = ActiveModel::Type::Boolean.new.cast(params[:good_faith])

    if role == "Tenant"
      @mediation.update!(EndOfConversationGoodFaithLandlord: good_faith)
      # Redirect tenant to survey
      redirect_to mediation_survey_path(@mediation.ConversationID)
    elsif role == "Landlord"
      @mediation.update!(EndOfConversationGoodFaithTenant: good_faith)
      # Redirect landlord to survey (same as tenant)
      redirect_to mediation_survey_path(@mediation.ConversationID)
    end
  end

  def good_faith_form
    @mediation = PrimaryMessageGroup.find_by(ConversationID: params[:id])
    if @mediation.nil? || @mediation.deleted_at.nil?
      redirect_to messages_path, alert: "Mediation not found or still ongoing."
      return
    end

    render "mediations/good_faith_feedback"
  end

  # Survey form for post-mediation feedback
  def survey_form
    @mediation = PrimaryMessageGroup.find_by(ConversationID: params[:id])

    if @mediation.nil? || @mediation.deleted_at.nil?
      redirect_to messages_path, alert: "Mediation not found or still ongoing."
      return
    end

    # Check if user already submitted survey
    existing_survey = SurveyResponse.find_by(conversation_id: @mediation.ConversationID, user_id: @user.UserID)
    if existing_survey
      redirect_to messages_path, notice: "You have already submitted a survey for this mediation."
      return
    end

    # Both tenants and landlords can access the survey
    is_tenant = @user.Role == "Tenant" && @mediation.TenantID == @user.UserID
    is_landlord = @user.Role == "Landlord" && @mediation.LandlordID == @user.UserID

    unless is_tenant || is_landlord
      redirect_to messages_path, alert: "You are not authorized to access this survey."
      return
    end

    @survey = SurveyResponse.new

    render "mediations/survey_form"
  end

  # Submit survey responses
  def submit_survey
    @mediation = PrimaryMessageGroup.find_by(ConversationID: params[:id])

    if @mediation.nil? || @mediation.deleted_at.nil?
      redirect_to messages_path, alert: "Mediation not found or still ongoing."
      return
    end

    # Both tenants and landlords can submit the survey
    is_tenant = @user.Role == "Tenant" && @mediation.TenantID == @user.UserID
    is_landlord = @user.Role == "Landlord" && @mediation.LandlordID == @user.UserID

    unless is_tenant || is_landlord
      redirect_to messages_path, alert: "You are not authorized to submit this survey."
      return
    end

    # Check if user already submitted survey
    existing_survey = SurveyResponse.find_by(conversation_id: @mediation.ConversationID, user_id: @user.UserID)
    if existing_survey
      redirect_to messages_path, notice: "You have already submitted a survey for this mediation."
      return
    end

    @survey = SurveyResponse.new(survey_params.merge(
      conversation_id: @mediation.ConversationID,
      user_id: @user.UserID,
      user_role: @user.Role
    ))

    if @survey.save
      redirect_to messages_path, notice: "Thank you for completing the survey!"
    else
      render "mediations/survey_form", alert: "Please complete all required fields."
    end
  end

  # Good Faith Screening prompt for edge case error handling
  def prompt_screen
    @mediation = PrimaryMessageGroup.find_by(ConversationID: params[:id])

    if @mediation.nil? || @mediation.deleted_at.nil?
      redirect_to messages_path, alert: "This mediation is still active or not found."
      return
    end

    render "mediations/prompt_screen" # We'll create this view next
  end

  private

  def find_existing_landlord
    email = params[:landlord_email].to_s.strip

    if params[:landlord_id].present?
      User.find_by(UserID: params[:landlord_id])
    elsif email.present?
      User.find_by(Email: email)
    else
      nil
    end
  end

  def find_existing_tenant
    email = params[:tenant_email].to_s.strip

    if email.present?
      User.find_by(Email: email)
    else
      nil
    end
  end

  def start_mediation_with_existing_landlord(landlord)
    ActiveRecord::Base.transaction do
      message_string = MessageString.create!(Role: "Primary")
      conversation_id = message_string.ConversationID

      mediation = PrimaryMessageGroup.create!(
        ConversationID: conversation_id,
        TenantID: @user.UserID,
        LandlordID: landlord.UserID,
        CreatedAt: Time.current,
        GoodFaith: false,
        MediatorRequested: false,
        MediatorAssigned: false,
        EndOfConversationGoodFaithLandlord: nil,
        EndOfConversationGoodFaithTenant: nil,
        accepted_by_landlord: false,
        accepted_by_tenant: true
      )

      redirect_to mediation_path(mediation), notice: "Negotiation requested with #{landlord.CompanyName || landlord.Email}."
    end
  end

  def start_mediation_with_existing_tenant(tenant)
    ActiveRecord::Base.transaction do
      message_string = MessageString.create!(Role: "Primary")
      conversation_id = message_string.ConversationID

      PrimaryMessageGroup.create!(
        ConversationID: conversation_id,
        TenantID: tenant.UserID,
        LandlordID: @user.UserID,
        CreatedAt: Time.current,
        GoodFaith: false,
        MediatorRequested: false,
        MediatorAssigned: false,
        EndOfConversationGoodFaithLandlord: nil,
        EndOfConversationGoodFaithTenant: nil,
        accepted_by_landlord: true,
        accepted_by_tenant: false
      )
    end

    redirect_to messages_path, notice: "Negotiation request sent to #{tenant.Email}. If they have an account, they can accept your request. Otherwise, they'll be invited to join the site."
  end

  def send_landlord_invitation(email)
    LandlordMailer.invitation_email(email, @user).deliver_now
    redirect_to messages_path, notice: "Invitation email sent to #{email}. If they have an account, they can accept your request. Otherwise, they'll be invited to join the site."
  rescue => e
    Rails.logger.error "Failed to send invitation email: #{e.message}"
    redirect_to messages_path, alert: "Failed to send invitation email. Please try again."
  end

  def send_tenant_invitation(email)
    Rails.logger.info "Attempting to send invitation email to: #{email}"
    TenantMailer.invitation_email(email, @user).deliver_now
    Rails.logger.info "Invitation email sent successfully to: #{email}"
    redirect_to messages_path, notice: "Invitation email sent to #{email}. They'll be invited to join the site."
  rescue => e
    Rails.logger.error "Failed to send invitation email: #{e.message}"
    redirect_to messages_path, alert: "Failed to send invitation email. Please try again."
  end

  def set_user
    @user = User.find(session[:user_id])
  end

  def require_login
    unless session[:user_id]
      redirect_to login_path, alert: "You must be logged in to access the mediations."
    end
  end

  def require_tenant_or_landlord_role
    unless [ "Tenant", "Landlord" ].include?(@user.Role)
      flash[:alert] = "You are not authorized to access this page."
      redirect_to root_path
    end
  end

  def require_any_user_role
    unless [ "Tenant", "Landlord", "Mediator" ].include?(@user.Role)
      flash[:alert] = "You are not authorized to access this page."
      redirect_to root_path
    end
  end

  def survey_params
    params.require(:survey_response).permit(
      :tool_ease,
      :info_clear,
      :understood_mediation,
      :other_participated,
      :good_faith,
      :helped_communicate,
      :would_recommend,
      :liked_most,
      :should_improve,
      :device_used
    )
  end

  def valid_email_format?(email)
    email.present? && URI::MailTo::EMAIL_REGEXP.match?(email)
  end
end
