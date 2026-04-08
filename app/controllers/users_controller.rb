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
      :TenantAddress, 
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
      permitted[:TenantAddress] = composed_tenant_address(permitted)
    end

    permitted
  end

  def composed_tenant_address(permitted)
    existing_tenant_address = permitted[:TenantAddress].to_s.strip
    address_line_1 = permitted[:AddressLine1].to_s.strip
    address_line_2 = permitted[:AddressLine2].to_s.strip
    city = permitted[:City].to_s.strip
    state = permitted[:State].to_s.strip.upcase
    zip_code = permitted[:ZipCode].to_s.strip

    if [ address_line_1, address_line_2, city, state, zip_code ].all?(&:blank?)
      return existing_tenant_address.presence
    end

    street = [ address_line_1, address_line_2.presence ].compact.join(", ")
    state_zip = [ state.presence, zip_code.presence ].compact.join(" ")
    city_state_zip = [ city.presence, state_zip.presence ].compact.join(", ")

    [ street.presence, city_state_zip.presence ].compact.join(", ").presence
  end
end
