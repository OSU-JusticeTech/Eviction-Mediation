class UsersController < ApplicationController
  def new
    @user = User.new
  end

  def create
    # Create a new user using strong parameters.
    @user = User.new(user_params)

    if @user.save
      # Automatically log the user in after signup
      session[:user_id] = @user.UserID

      # Send professional welcome email
      UserMailer.welcome_email(@user).deliver_later

      redirect_to dashboard_path, notice: "Account created successfully!"
    else
      # Historically the signup form is re-rendered on invalid input and
      # the test suite expects a 200 OK response. Return the default
      # successful render of the `new` template so the tests and the
      # browser behave consistently.
      render :new
    end
  end

  private

  # Adjust the permitted parameters to match your Users table column names.
  def user_params
    permitted = params.require(:user).permit(
      :Email, 
      :password, 
      :password_confirmation, 
      :FName, 
      :LName, 
      :Role, 
      :CompanyName, 
      :PhoneNumber, 
      :ProfileDisclaimer,
      :AddressLine1,
      :AddressLine2,
      :City,
      :State,
      :ZipCode
    )

    if permitted[:Role] == "Tenant"
      permitted[:AddressLine1] = permitted[:AddressLine1].to_s.strip.presence
      permitted[:AddressLine2] = permitted[:AddressLine2].to_s.strip.presence
      permitted[:City] = permitted[:City].to_s.strip.presence
      permitted[:State] = permitted[:State].to_s.strip.upcase.presence
      permitted[:ZipCode] = permitted[:ZipCode].to_s.strip.presence
    end

    permitted
  end
end
