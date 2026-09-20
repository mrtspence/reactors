# frozen_string_literal: true

# **The one place the escape hatch is decided, and it refuses to open outside development.**
#
# `REACTOR_OPERATOR_BYPASS=1` lets a developer drive operations they do not own, which is how two
# machines get tested side by side. Set anywhere but development or test, this **raises at boot**
# rather than logging a warning: a misconfigured production that fails to start is recoverable in
# a minute, and one that silently serves every operation to everybody is a breach nobody notices.
#
# Deciding it here rather than at the call site is the same argument as `DevMatch.chassis` — a
# rule read from two places is a rule two processes can disagree about. See
# `docs/design_sketches/operator_identity.md` §3.1.
# **The literal lives here and nowhere else.** `Operator` reads it back off the config rather
# than naming it again, because an initializer must not reference an autoloaded constant and two
# copies of an env var name is a rule two files can disagree about.
var = "REACTOR_OPERATOR_BYPASS"
enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch(var, false)) || false

if enabled && !Rails.env.local?
  raise "#{var} is a development escape hatch and cannot be enabled in #{Rails.env}. " \
        "It lets one player operate machines they do not own."
end

Rails.application.config.x.operator_bypass = enabled
Rails.application.config.x.operator_bypass_var = var
