class LandlordIntakeQuestionsController < ApplicationController
  before_action :require_login
  before_action :set_user
  before_action :require_landlord

  def new
    @landlord_intake_question = LandlordIntakeQuestion.new
  end

  def create
    accept_payment_plan = ActiveModel::Type::Boolean.new.cast(params[:landlord_intake_question][:AcceptPaymentPlan])

    @landlord_intake_question = LandlordIntakeQuestion.new(landlord_intake_question_params)
    @landlord_intake_question.UserID = @user.UserID
    @landlord_intake_question.AcceptPaymentPlan = accept_payment_plan
    @landlord_intake_question.reasons = params.dig(:landlord_intake_question, :Reason)

    if @landlord_intake_question.save
      conversation = PrimaryMessageGroup.find_by(
        LandlordID: @user.UserID,
        deleted_at: nil
      )
      conversation.update!(LandlordIntakeID: @landlord_intake_question.LandlordIntakeID)
      redirect_to messages_path, notice: "Intake questions completed successfully. You can now proceed to your negotiations."
    else
      render plain: "ERROR: #{@landlord_intake_question.errors.full_messages.join(', ')}"
    end
  end

  private

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
end
