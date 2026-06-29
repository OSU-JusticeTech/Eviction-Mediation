source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.0.1"
# Use Sprockets for better CSS asset management
gem "sprockets-rails"
# Use sql server as the database for Active Record
gem "tiny_tds", ">= 3.1.0"
gem "activerecord-sqlserver-adapter", ">= 8.0"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

# Twilio for SMS-based 2FA
gem "twilio-ruby", "~> 7.3"

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Redis for caching and job queue in production
gem "redis", ">= 5.0"
gem "sidekiq", "~> 7.2"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
# gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "simplecov", require: false
  gem "capybara"
  gem "selenium-webdriver"
  gem "rails-controller-testing"
end

# Performance-booster for watching directories on Windows
# gem "wdm", "~> 0.1", :platforms => [:mingw, :x64_mingw, :mswin]

# Lock `http_parser.rb` gem to `v0.6.x` on JRuby builds since newer versions of the gem
# do not have a Java counterpart.
gem "http_parser.rb", "~> 0.6.0", platforms: [ :jruby ]

# enables .env file
gem "dotenv-rails"

# for frontend to add icons
gem "font-awesome-sass", "~> 6.4.2"

# Tailwind CSS via standalone CLI (no Node.js required)
gem "tailwindcss-rails"

# Table support used by Prawn-based PDF generation
gem "prawn"

gem "prawn-table"
gem "rubocop", "~> 1.71", groups: [ :development, :test ]

gem "ruby-lsp", "~> 0.26.1", group: :development

gem "rubocop-rspec", "~> 3.4", groups: [ :development, :test ]
