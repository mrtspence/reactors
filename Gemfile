source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.3", ">= 8.1.3.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Postgres for progression and end-of-match writes. Note that match runtime state
# never touches the database (docs/architecture.md §5) — this carries progression,
# achievements, and the archived seed + command log that replays are rebuilt from.
gem "pg", "~> 1.5"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Tailwind via the standalone binary — no Node, no package.json. Paired with
# importmap this keeps the project entirely Node-free (docs/architecture.md §9).
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Server-rendered components for the discrete-event half of the UI (docs/architecture.md §7)
gem "view_component"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Kafka. Two clients, split by role (docs/architecture.md §6):
#
#   * rdkafka drives the match runner, which needs a non-blocking poll inside its own
#     tick loop and manual offset commits at the tick barrier. Neither fits a
#     message-driven framework.
#   * karafka drives the egress consumers, which genuinely are message-driven. Its Web
#     UI is also where consumer lag and partition assignment become visible.
gem "rdkafka", "~> 0.19"
gem "karafka", "~> 2.4"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # spec/spec_helper.rb is deliberately Rails-free so the simulation specs can run
  # outside Rails; spec/rails_helper.rb is the one that boots the app.
  gem "rspec-rails"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # bin/dev has to start web, runner and consumers together (docs/architecture.md §9)
  gem "foreman"
end
