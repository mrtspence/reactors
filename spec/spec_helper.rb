# frozen_string_literal: true

# Deliberately Rails-free.
#
# This is the helper the simulation specs use, and it must never load Rails, boot the
# app, or touch a database. That is not incidental tidiness — the whole point of
# lib/reactor_sim is that it stands alone (docs/architecture.md §3), and a spec_helper
# that quietly booted Rails would let the boundary rot without anyone noticing.
#
# Specs that genuinely need the app require "rails_helper" instead.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = false
  config.order = :random
  Kernel.srand config.seed
end
