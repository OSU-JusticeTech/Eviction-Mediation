class LandlordIntakeQuestionsController < ApplicationController
  include MediationRequestSupport

  before_action :require_login
  before_action :set_user
  before_action :require_landlord

  def new
    @conversation_id = params[:conversation_id]
    @landlord_intake_question = LandlordIntakeQuestion.new

    if pre_request_mode?
      @show_unknown = false
      return
    end

    session.delete(:pending_mediation_request)
    mediation = landlord_intake_mediation

    if mediation.nil?
      redirect_to messages_path, alert: "We couldn't find a negotiation awaiting your intake."
      return
    end

    @show_unknown = mediation.requested_by == "Tenant"
  end

  def create
    @conversation_id = params[:conversation_id]
    accept_payment_plan = ActiveModel::Type::Boolean.new.cast(params[:landlord_intake_question][:AcceptPaymentPlan])

    @landlord_intake_question = LandlordIntakeQuestion.new(landlord_intake_question_params)
    @landlord_intake_question.UserID = @user.UserID
    @landlord_intake_question.AcceptPaymentPlan = accept_payment_plan
    @landlord_intake_question.reasons = params.dig(:landlord_intake_question, :Reason)

    if pre_request_mode?
      create_pre_request
      return
    end

    session.delete(:pending_mediation_request)

    if @landlord_intake_question.save
      conversation = landlord_intake_mediation

      if conversation
        conversation.update!(LandlordIntakeID: @landlord_intake_question.LandlordIntakeID)
        redirect_to messages_path, notice: "Intake questions completed successfully. You can now proceed to your negotiations."
      else
        @landlord_intake_question.destroy
        redirect_to messages_path, alert: "We couldn't find a negotiation awaiting your intake."
      end
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  # Whether this visit is the requester filling out their intake *before* the
  # request exists, versus the ordinary post-acceptance intake tied to a real
  # conversation_id. Session-mediated so `MediationsController#create` can hand
  # off the validated target email without a mediation record to key off yet.
  def pre_request_mode?
    session[:pending_mediation_request].present? && @conversation_id.blank?
  end

  def create_pre_request
    if @landlord_intake_question.reasons == [ "Unknown" ]
      @show_unknown = false
      flash.now[:alert] = "Please describe your situation before requesting a negotiation."
      render :new, status: :unprocessable_entity
      return
    end

    target_email = session[:pending_mediation_request]["target_email"]

    mediation = ActiveRecord::Base.transaction do
      @landlord_intake_question.save!
      tenant = find_existing_tenant(target_email)
      valid_target = tenant && tenant.Role == "Tenant" && tenant.Email != @user.Email
      raise ActiveRecord::Rollback unless valid_target

      create_mediation_for_landlord_requester(@user, tenant, @landlord_intake_question.LandlordIntakeID)
    end

    session.delete(:pending_mediation_request)

    if mediation
      tenant = mediation.tenant
      TenantMailer.invitation_email(tenant.Email, @user).deliver_later if tenant.notify_new_mediation_request?
      redirect_to messages_path, notice: "Negotiation request sent to #{tenant.Email}. If they have an account, they can accept your request. Otherwise, they'll be invited to join the site."
    else
      redirect_to new_mediation_path, alert: "No tenant account found with that email."
    end
  rescue ActiveRecord::RecordInvalid
    @show_unknown = false
    render :new, status: :unprocessable_entity
  end

  def require_login
    unless session[:user_id]
      redirect_to login_path, alert: "You must be logged in to access the dashboard."
    end
  end

  def set_user
    @user = User.find(session[:user_id])
  end

  def require_landlord
    unless @user.Role == "Landlord"
      redirect_to messages_path, alert: "Access denied."
    end
  end

  def landlord_intake_question_params
    params.require(:landlord_intake_question).permit(
      :LandlordDescribeCause, :DesiredOutcome, :AcceptPaymentPlan,
      :AmountClaimed, :MonthlyRent, :DateDue
    )
  end

  # The specific mediation this landlord is completing intake for. Scoping by the
  # conversation (rather than grabbing any intake-less mediation) ensures we read
  # the correct `requested_by` when the landlord has more than one pending intake.
  def landlord_intake_mediation
    scope = PrimaryMessageGroup.where(LandlordID: @user.UserID, deleted_at: nil, LandlordIntakeID: nil)
    scope = scope.where(ConversationID: @conversation_id) if @conversation_id.present?
    scope.first
  end
end
