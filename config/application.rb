require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"
require "action_cable/engine"
# require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Reactor
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    #
    # `reactor_sim` is ignored deliberately. The simulation is a self-contained
    # library reached by an explicit `require "reactor_sim"`, not a Rails citizen
    # (docs/architecture.md §3). Letting Zeitwerk manage it would:
    #
    #   * fight the explicit require_relative chain in lib/reactor_sim.rb,
    #   * make the sim reloadable in development, so a long-running match runner
    #     could end up holding state built from unloaded constants, and
    #   * quietly erode the boundary the purity spec exists to defend.
    # Both entries are needed: the ignore list matches exact paths, so `reactor_sim`
    # covers the directory but not lib/reactor_sim.rb, which is the entry point.
    config.autoload_lib(ignore: %w[assets tasks reactor_sim reactor_sim.rb])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
