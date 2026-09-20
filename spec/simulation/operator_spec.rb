# frozen_string_literal: true

require "rails_helper"

# **The escape hatch, and the boot that refuses to open it.**
#
# `REACTOR_OPERATOR_BYPASS` lets a developer drive machines they do not own. The example that
# matters here is the *refusal*: a misconfigured production must fail to start rather than
# quietly serve every operation to everybody, and a check nobody exercises is a check that rots.
#
# See docs/design_sketches/operator_identity.md §3.
RSpec.describe Operator do
  # The initializer, run as a script against a stubbed environment. Loading the real file is the
  # point — a spec that reimplemented the rule would pass while the initializer was wrong.
  def boot(env:, value:)
    # **`EnvironmentInquirer`, not `StringInquirer`.** `local?` is what the initializer asks, and
    # a plain `StringInquirer` answers it through `method_missing` as "is this string 'local'" —
    # false for development, so the stub refused a boot the real Rails would have allowed.
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(env))
    # `fetch` with a default, which is what the initializer uses — so a stub has to answer the
    # same way rather than pretending the key is present.
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with(described_class.env_var, false)
                                .and_return(value.nil? ? false : value)

    load Rails.root.join("config/initializers/operator_bypass.rb")
  end

  around do |example|
    was = Rails.application.config.x.operator_bypass
    example.run
    Rails.application.config.x.operator_bypass = was
  end

  describe "the boot-time refusal" do
    it "refuses to start with the hatch open in production" do
      expect { boot(env: "production", value: "1") }
        .to raise_error(/cannot be enabled in production/)
    end

    it "refuses in staging too, because `local?` is the whole allowance" do
      expect { boot(env: "staging", value: "true") }.to raise_error(/cannot be enabled/)
    end

    # The common case, and it must not raise: production with the hatch shut is the normal world.
    it "starts happily in production with the hatch shut" do
      expect { boot(env: "production", value: nil) }.not_to raise_error
      expect(described_class.bypass?).to be(false)
    end
  end

  describe "in development" do
    it "opens when asked" do
      boot(env: "development", value: "1")

      expect(described_class.bypass?).to be(true)
    end

    it "stays shut by default, so the real rule is what a developer sees unless they ask" do
      boot(env: "development", value: nil)

      expect(described_class.bypass?).to be(false)
    end

    it "reads a word as well as a digit, since that is what a shell exports" do
      boot(env: "development", value: "true")

      expect(described_class.bypass?).to be(true)
    end

    it "treats an explicit falsehood as shut rather than as present" do
      boot(env: "development", value: "false")

      expect(described_class.bypass?).to be(false)
    end
  end
end
