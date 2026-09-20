# frozen_string_literal: true

# **The development escape hatch, and the one rule about it.**
#
# One player per operation is the real rule. A developer testing two machines at once needs to
# drive both, so this widens *who may operate* — and nothing else.
#
# > **It never fabricates an owner.** `Operation#owner_id` stays whatever it was, so every row
# > still records who the machine belongs to and turning the hatch off restores the real rule
# > with no data to repair. A bypass that wrote `owner_id = "dev"` would quietly rewrite the
# > thing it was bypassing, and the damage would outlive the flag.
#
# **It cannot be switched on in production**, and that is enforced at boot rather than at the
# check: `config/initializers/operator_bypass.rb` raises if the env var is set anywhere but
# development or test, so a misconfigured production **fails to start** instead of quietly
# serving everybody everything. A default that silently opens a gate is the failure worth
# designing against — the same instinct as `content_spec` refusing a structural material with no
# temperature rating.
#
# See docs/design_sketches/operator_identity.md §3.
module Operator
  module_function

  # Read through the config rather than from `ENV` at the call site, so the boot-time refusal
  # above is the only place the question is decided — and the env var's name is spelled once,
  # in the initializer, rather than in two files that can disagree.
  def bypass? = Rails.application.config.x.operator_bypass == true

  def env_var = Rails.application.config.x.operator_bypass_var

  # Whether the hatch *could* be opened here at all. The console says so when it is open — a
  # development affordance that looks identical to the real thing is how somebody ends up
  # debugging the wrong rule for an afternoon.
  def available? = Rails.env.local?
end
