class TenantMailer < ApplicationMailer
  def invitation_email(email, landlord)
    @landlord = landlord
    @email = email

    mail(
      to: email,
      subject: "You've been invited to start a mediation on Eviction Mediation"
    )
  end
end
