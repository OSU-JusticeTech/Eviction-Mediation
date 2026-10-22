class SessionsController < ApplicationController
    def new
    end

    def create
        # Find user by email
        user = User.find_by(Email: params[:email])

        # Directly compare the plain text password
        if user && user.authenticate(params[:password]) # Match encrypted password
          
          if user.two_factor_enabled? && user.phone_verified?
            # Generate and send 2FA code
            twilio = TwilioService.new
            code = twilio.generate_code
            
            if user.update(two_factor_code: code.to_s, two_factor_code_sent_at: Time.current) &&
               twilio.send_verification_code(user.phone_number, code)
              
              session[:pending_user_id] = user.UserID
              redirect_to sms_two_factor_path, notice: "Verification code sent to your phone"
            else
              flash[:error] = "Failed to send verification code. Please try again."
              render :new, status: :unprocessable_entity, turbo: false
            end
          else
            
            session[:user_id] = user.UserID
            redirect_to dashboard_path, notice: "Logged in successfully!"
          end
        else
          flash[:error] = "Invalid email or password"
          render :new, status: :unprocessable_entity, turbo: false
        end
    end

    def destroy
      MediatorTimeEntry.current_for(session[:user_id])&.close! if session[:user_id]
      session[:user_id] = nil
      redirect_to root_path, notice: "Logged out successfully!"
    end
end
