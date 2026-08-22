# frozen_string_literal: true

# The Rails-aware helper. Only specs that actually exercise the web tier — request
# specs, ViewComponent specs, channel specs — should require this. Simulation specs
# require "spec_helper" and stay outside Rails entirely.

require "spec_helper"

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

abort("The Rails environment is running in production mode!") if Rails.env.production?

require "rspec/rails"

RSpec.configure do |config|
  config.fixture_paths = [ Rails.root.join("spec/fixtures") ]
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!
end
