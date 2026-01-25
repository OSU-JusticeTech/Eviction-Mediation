require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Replace the default in-process memory cache store with Redis for production.
  config.cache_store = :redis_cache_store, {
    url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"),
    namespace: "eviction_mediation_cache"
  }

  # Replace the default in-process and non-durable queuing backend with Sidekiq.
  config.active_job.queue_adapter = :sidekiq

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { 
    host: ENV.fetch("APP_URL", "eviction-mediation.novelminds.io"), 
    protocol: ENV.fetch("APP_PROTOCOL", "https") 
  }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # START EMAIL STUFF
  config.action_mailer.delivery_method = :smtp

  # Flexible SMTP configuration using environment variables
  # Works with any SMTP service (Gmail, SendGrid, Mailgun, SES, etc.) or testing tools
  config.action_mailer.smtp_settings = {
    address: ENV.fetch("SMTP_ADDRESS", "smtp.gmail.com"),
    port: ENV.fetch("SMTP_PORT", 587).to_i,
    domain: ENV.fetch("SMTP_DOMAIN", "gmail.com"),
    authentication: ENV.fetch("SMTP_AUTHENTICATION", "plain").to_sym,
    enable_starttls_auto: ENV.fetch("SMTP_ENABLE_STARTTLS_AUTO", "true") == "true",
    user_name: ENV["SMTP_USERNAME"], # Can be nil for testing tools that don't require auth
    password: ENV["SMTP_PASSWORD"],  # Can be nil for testing tools that don't require auth
    open_timeout: ENV.fetch("SMTP_OPEN_TIMEOUT", 5).to_i,
    read_timeout: ENV.fetch("SMTP_READ_TIMEOUT", 5).to_i
  }

  # Show error if mailer can't send
  config.action_mailer.raise_delivery_errors = ENV.fetch("SMTP_RAISE_DELIVERY_ERRORS", "true") == "true"

  # Make template changes take effect immediately.
  config.action_mailer.perform_caching = false

  # Mailer performs deliveries
  config.action_mailer.perform_deliveries = ENV.fetch("SMTP_PERFORM_DELIVERIES", "true") == "true"

  # Set production host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { 
    host: ENV.fetch("APP_URL", "eviction-mediation.novelminds.io"), 
    protocol: ENV.fetch("APP_PROTOCOL", "https") 
  }

  # END EMAIL STUFF


  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  config.hosts = [
    ENV.fetch("APP_URL", "eviction-mediation.novelminds.io"),    # Allow requests from configured domain
    "site"                                                       # Allow requests from 'site' alias
  ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }

  # ActionCable for real-time messaging
  config.action_cable.mount_path = "/cable"
  config.action_cable.allowed_request_origins = [
    "#{ENV.fetch('APP_PROTOCOL', 'https')}://#{ENV.fetch('APP_URL', 'eviction-mediation.novelminds.io')}"
  ]
end
