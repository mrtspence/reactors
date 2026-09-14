# frozen_string_literal: true

require "rails_helper"
require "open3"

# Infrastructure checks. These exist because each one of them has a failure mode that
# is silent or misleading rather than loud, and each cost real time to diagnose once.
RSpec.describe "the Rails environment" do
  it "connects to the Postgres test database" do
    expect(ActiveRecord::Base.connection.adapter_name).to eq("PostgreSQL")
    expect(ActiveRecord::Base.connection_db_config.database).to eq("reactor_test")
  end

  it "has the Solid Queue, Cache and Cable databases wired to their own schemas" do
    %w[queue cache cable].each do |role|
      config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: role)
      expect(config).not_to be_nil, "no `#{role}` database configured for test"
      expect(config.database).to eq("reactor_test_#{role}")
    end
  end

  # The match runner is a Rails-booted process that hosts the pure simulation
  # (docs/architecture.md §2). It reaches the sim by requiring it off $LOAD_PATH — not
  # by autoloading, which would drag the sim into Rails' dependency graph and quietly
  # undo the boundary the purity spec defends.
  it "makes the simulation requirable from a Rails process" do
    require "reactor_sim"

    expect(ReactorSim::Match).to be_a(Class)
    expect(ReactorSim::DT).to eq(0.25)
  end

  # `lib` itself is an autoload path, which is fine for ordinary app-adjacent code.
  # The simulation specifically must stay out of Zeitwerk's hands, or it becomes a
  # reloadable Rails constant and the boundary quietly stops being a boundary — a
  # long-running runner would end up holding state built from unloaded constants.
  #
  # This used to be tested by consequence: eager load the app in a fresh process and fail
  # if ReactorSim was defined with nobody having required it. That proxy died the moment
  # the delivery tier legitimately required the sim (config/initializers/reactor_sim.rb),
  # because "defined" no longer distinguishes "we asked for it" from "Zeitwerk took it".
  #
  # `unloadable_cpaths` is the direct question instead: it lists exactly the constants
  # Zeitwerk owns and will unload on reload. The two positive controls matter — without
  # them a typo'd constant name would make this pass while checking nothing.
  it "is not managed by Zeitwerk, however it came to be loaded" do
    script = <<~RUBY
      require File.expand_path("config/environment", Dir.pwd)
      Rails.application.eager_load!
      require "reactor_sim"

      owned = Rails.autoloaders.main.unloadable_cpaths

      unless owned.include?("ApplicationController") && owned.include?("DevMatch")
        warn "control failed: Zeitwerk does not own app/ either, so this check proves nothing"
        exit 2
      end

      if owned.include?("ReactorSim")
        warn "Zeitwerk is managing the simulation — it is reloadable and the boundary is gone"
        exit 1
      end
      exit 0
    RUBY

    stdout, status = Open3.capture2e(
      { "RAILS_ENV" => "development" }, "ruby", "-e", script, chdir: Rails.root.to_s
    )

    expect(status).to be_success, stdout
  end

  # Async is in-process only, so a runner broadcasting from its own process would
  # reach nobody at all — with no error anywhere to explain it.
  it "does not use the in-process async cable adapter in development" do
    config = Rails.application.config_for(:cable, env: "development")

    expect(config[:adapter]).to eq("solid_cable")
  end
end
