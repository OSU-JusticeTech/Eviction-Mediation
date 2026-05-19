class AccountController < ApplicationController
  before_action :require_login
  before_action :set_user

  def show
  end
  
  def edit
  end

  def update
    updated = false

    # Password Update
    if params[:user][:password].present?
      if @user.update(password_params)
        flash[:notice] = "Password updated successfully."
        updated = true
      else
        flash.now[:alert] = "Password update failed."
        render :show and return
      end
    end

    # Mediator Availability Update
    if @user.Role == "Mediator" && params[:user][:mediator_attributes].present?
      if @user.update(mediator_params)
        flash[:notice] ||= "Availability updated."
        updated = true
      else
        flash.now[:alert] = "Failed to update availability."
        render :show and return
      end
    end

    # Address Update
    if @user.Role == "Tenant" && params[:commit] == "Update Address"
      address_update_params = address_params

      if address_update_params.values.all?(&:blank?)
      elsif @user.update(address_update_params)
        flash[:notice] ||= "Address updated successfully."
        updated = true
      else
        flash[:alert] = @user.errors.full_messages.to_sentence
        redirect_to account_path and return
      end
    end

    # Two-Factor Authentication Update
    if params[:commit] == "Enable 2FA" || params[:commit] == "Update Phone Number"
      if params[:user][:phone_number].blank?
        flash[:alert] = "Please enter a phone number."
        redirect_to account_path and return
      end

      
      unless @user.update(PhoneNumber: params[:user][:phone_number])
        flash[:alert] = "Invalid phone number format."
        redirect_to account_path and return
      end
      
      
      twilio = TwilioService.new
      code = twilio.generate_code
      
      if @user.update(two_factor_code: code.to_s, two_factor_code_sent_at: Time.current)
        result = twilio.send_verification_code(@user.phone_number, code)
        
        if result
          if ENV['TWILIO_VERIFY_SERVICE_SID'].present?
            flash[:notice] = "Verification code sent via SMS to #{@user.format_phone_for_display}"
          else
            flash[:notice] = "Verification code generated. Check your Rails console logs for the code."
          end
          redirect_to verify_phone_account_path and return
        else
          flash[:alert] = "Failed to send verification code. Please try again."
          redirect_to account_path and return
        end
      else
        flash[:alert] = "Failed to save verification code. Please try again."
        redirect_to account_path and return
      end
    elsif params[:commit] == "Disable 2FA"
      if @user.update(two_factor_enabled: false, phone_verified: false)
        flash[:notice] = "Two-factor authentication has been disabled."
        updated = true
      else
        flash.now[:alert] = "Failed to disable two-factor authentication."
        render :show and return
      end
    end

    flash[:alert] = "No changes detected." unless updated
    redirect_to account_path
  end

  def enable_two_factor
    if @user.phone_number.blank?
      flash[:alert] = "Please add a phone number first."
      redirect_to account_path and return
    end

    # Send verification code
    twilio = TwilioService.new
    code = twilio.generate_code
    
    if @user.update(two_factor_code: code.to_s, two_factor_code_sent_at: Time.current) &&
       twilio.send_verification_code(@user.phone_number, code)
      
      flash[:notice] = "Verification code sent to #{@user.format_phone_for_display}"
      redirect_to verify_phone_account_path
    else
      flash[:alert] = "Failed to send verification code. Please try again."
      redirect_to account_path
    end
  end

  def verify_phone
    
  end

  def confirm_phone
    twilio = TwilioService.new
    code_valid = false
    
    
    Rails.logger.info "Verifying code: #{params[:code]}"
    Rails.logger.info "Stored code: #{@user.two_factor_code}"
    Rails.logger.info "Code sent at: #{@user.two_factor_code_sent_at}"
    Rails.logger.info "Phone number: #{@user.phone_number}"
    
    
    if ENV['TWILIO_VERIFY_SERVICE_SID'].present?
      Rails.logger.info "Attempting Twilio Verify API verification"
      begin
        code_valid = twilio.verify_code(@user.phone_number, params[:code])
      rescue => e
        Rails.logger.warn "Twilio verification failed: #{e.message}, falling back to local code"
        code_valid = false
      end
      
      
      if !code_valid && Rails.env.development? && @user.two_factor_code.present?
        Rails.logger.info "Falling back to local code verification"
        code_valid = @user.two_factor_code == params[:code] && 
                     @user.two_factor_code_sent_at && 
                     @user.two_factor_code_sent_at > 10.minutes.ago
      end
    else
      
      Rails.logger.info "Using local code storage (no Twilio credentials)"
      code_valid = @user.two_factor_code == params[:code] && 
                   @user.two_factor_code_sent_at && 
                   @user.two_factor_code_sent_at > 10.minutes.ago
    end
    
    Rails.logger.info "Code valid: #{code_valid}"
    
    if code_valid
      @user.update(
        phone_verified: true, 
        two_factor_enabled: true,
        two_factor_code: nil, 
        two_factor_code_sent_at: nil
      )
      
      flash[:notice] = "Phone verified! Two-factor authentication is now enabled."
      redirect_to account_path
    else
      flash[:alert] = "Invalid or expired verification code."
      redirect_to verify_phone_account_path
    end
  end

  private

  def address_params
    permitted = params.require(:user).permit(:AddressLine1, :AddressLine2, :City, :State, :ZipCode).to_h

    permitted.transform_values! { |value| value.to_s.strip.presence }
    permitted[:State] = permitted[:State].to_s.upcase.presence
    permitted.symbolize_keys
  end

  def password_params
    params.require(:user).permit(:password, :password_confirmation)
  end

  def mediator_params
    params.require(:user).permit(mediator_attributes: [ :id, :Available ])
  end

  def two_factor_params
    params.require(:user).permit(:phone_number, :two_factor_enabled)
  end

  def require_login
    unless session[:user_id]
      redirect_to login_path, alert: "You must be logged in to access the dashboard."
    end
  end

  def set_user
    @user = User.find(session[:user_id])
  end
end
