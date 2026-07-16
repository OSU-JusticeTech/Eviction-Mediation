class IntakeQuestionsController < ApplicationController
    include MediationRequestSupport

    before_action :require_login
    before_action :set_user
    before_action :set_conversation_ID

    def new
      @intake_question = IntakeQuestion.new

      if pre_request_mode?
        @show_unknown = false
        return
      end

      session.delete(:pending_mediation_request)
      mediation = tenant_intake_mediation

      if mediation.nil?
        redirect_to messages_path, alert: "We couldn't find a negotiation awaiting your intake."
        return
      end

      @show_unknown = mediation.requested_by == "Landlord"
    end

    def create
      section8 = ActiveModel::Type::Boolean.new.cast(params[:intake_question][:Section8])
      total_cost_or_monthly = ActiveModel::Type::Boolean.new.cast(params[:intake_question][:TotalCostOrMonthly])

      @intake_question = IntakeQuestion.new(intake_question_params)
      @intake_question.UserID = @user.UserID
      @intake_question.Section8 = section8
      @intake_question.TotalCostOrMonthly = total_cost_or_monthly
      @intake_question.reasons = params.dig(:intake_question, :Reason)
      Rails.logger.debug params[:intake_question]

      if pre_request_mode?
        create_pre_request
        return
      end

      session.delete(:pending_mediation_request)

      if @intake_question.save
        conversation = tenant_intake_mediation

        if conversation
          conversation.update!(IntakeID: @intake_question.IntakeID)
          redirect_to messages_path, notice: "Intake questions completed successfully. You can now proceed to your negotiations."
        else
          @intake_question.destroy
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
      if @intake_question.reasons == [ "Unknown" ]
        @show_unknown = false
        flash.now[:alert] = "Please describe your situation before requesting a negotiation."
        render :new, status: :unprocessable_entity
        return
      end

      target_email = session[:pending_mediation_request]["target_email"]

      mediation = ActiveRecord::Base.transaction do
        @intake_question.save!
        landlord = find_existing_landlord(target_email)
        valid_target = landlord && landlord.Role == "Landlord" && landlord.Email != @user.Email
        raise ActiveRecord::Rollback unless valid_target

        create_mediation_for_tenant_requester(@user, landlord, @intake_question.IntakeID)
      end

      session.delete(:pending_mediation_request)

      if mediation
        landlord = mediation.landlord
        LandlordMailer.mediation_request_notification(landlord.Email, @user).deliver_later if landlord.notify_new_mediation_request?
        redirect_to messages_path, notice: "Negotiation requested with #{landlord.CompanyName || landlord.Email}."
      else
        redirect_to new_mediation_path, alert: "No landlord account found with that email."
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

    def set_conversation_ID
        @conversation_id = params[:conversation_id]
    end

    # The specific mediation this tenant is completing intake for. Scoping by the
    # conversation (rather than grabbing any intake-less mediation) ensures we read
    # the correct `requested_by` when the tenant has more than one pending intake.
    def tenant_intake_mediation
        scope = PrimaryMessageGroup.where(TenantID: @user.UserID, deleted_at: nil, IntakeID: nil)
        scope = scope.where(ConversationID: @conversation_id) if @conversation_id.present?
        scope.first
    end

    def intake_question_params
      # :Reason is handled separately via the #reasons= setter (it arrives as an
      # array of selected reasons), so it is intentionally not permitted here.
      params.require(:intake_question).permit(
        :DescribeCause, :BestOption, :Section8,
        :MoneyOwed, :TotalCostOrMonthly, :MonthlyRent,
        :DateDue, :PayableToday, :conversation_id
      )
    end
end
