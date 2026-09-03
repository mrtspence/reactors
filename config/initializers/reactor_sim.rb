# frozen_string_literal: true

# The one place the delivery tier crosses into the simulation.
#
# `lib/reactor_sim` is deliberately outside Zeitwerk (see config/application.rb), so it is not
# autoloaded and never will be — it is reached by an explicit require, exactly as it would be
# from a bare `ruby -Ilib` process. Putting that require here rather than at the top of
# whichever class happened to need it first keeps the crossing visible and singular.
#
# This is cheap: requiring the library defines constants and nothing else. Content YAML is
# read lazily by `Content.default` on first use, so no Rails process pays for it at boot, and
# `rails console` or a rake task loading this costs nothing.
require "reactor_sim"
