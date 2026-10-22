class ApplicationMailer < ActionMailer::Base
  default from: ENV["MAIL_FROM"].presence || Rails.application.credentials.dig(:smtp, :from) || "Eviction Mediation <no-reply@example.com>"
  layout "mailer"
end
