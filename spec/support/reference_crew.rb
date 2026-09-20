# frozen_string_literal: true

require "reactor_sim"

# The crew a spec runs a machine with, and why it is **not** anybody from `content/minions/`.
#
# ## Why a machine needs a crew at all now
#
# A work station's lever is an *instruction*; what comes of it depends on who is carrying it out.
# A match with no roster is crewed by day-labourers, and a locomotive cannot be run by
# day-labourers. Measured on the reference cold start:
#
#     day-labourers    56 kPa   fire  511 K      0 rpm     0 kW   — never gets going
#     a capable human 608 kPa   fire 1008 K  174.6 rpm   398 kW
#
# So a spec that runs an engine and does not say who is working it is **under-specified**: it
# measures the labour exchange rather than the machine.
#
# ## Why fixtures rather than Jim
#
# **Pinning a spec to a real individual is a rake to step on.** Jim's stats are game content and
# will be tuned — repeatedly, as more mechanics land — and every tune would break specs that have
# nothing to do with Jim, for reasons that look like physics regressions and are not. The same
# argument that keeps `failure_spec` asserting *modes* rather than pressures applies to people.
#
# So: a deliberately boring fixture. Every stat exactly 1.0, no tags, no training, no equipment —
# **capability exactly 1.0**, which is the baseline every work station's declared throughput is
# defined against. If this number ever changes it will be because somebody changed it here, on
# purpose.
#
# A spec that is genuinely *about* crew quality posts its own people and should — see
# `crew_spec` and `injury_spec`.
module ReferenceCrew
  # Flat 1.0 across the board. Not a race anybody can hire; it exists so a reference machine is a
  # reference machine.
  # **Endurance is the one stat that is deliberately not 1.0, and it is not a balance figure.**
  # `endurance` divides fatigue accrual and does NOT enter `capability`, so an arbitrarily large
  # value leaves every throughput baseline exactly where it was while making the reference hand
  # tireless. That is what keeps a spec about a *machine* measuring the machine: a real fireman at
  # the firehole is spent in about five minutes and the fire then dies, which turned a
  # seven-thousand-tick boiler-burst example into a cold boiler and nobody hurt.
  #
  # A spec that is genuinely about fatigue posts its own people, exactly as `injury_spec` and
  # `crew_spec` do — see `fatigue_spec`.
  TIRELESS = 1.0e6

  ARCHETYPE = { label: "Test Hand", strength: 1.0, toughness: 1.0, endurance: TIRELESS,
                intelligence: 1.0, dexterity: 1.0, charisma: 1.0, tags: {} }.freeze

  # One fixture person per job the steam engine asks for. Separate ids rather than one shared
  # entry, so a spec can hurt one of them without the other changing.
  MINIONS = { test_hand_a: { name: "Test Hand A", archetype: :test_hand, hireable: false },
              test_hand_b: { name: "Test Hand B", archetype: :test_hand, hireable: false } }.freeze

  # The shipped content plus the fixtures. Real resources and real reactions — a spec wants the
  # actual physics — with people who will not move underneath it.
  CONTENT = ReactorSim::Content.default
                               .merging(archetypes: { test_hand: ARCHETYPE }, minions: MINIONS)

  # **Seats, not jobs**, and the roster no longer says where anybody stands — everybody starts in
  # the crew quarters. A spec that wants the engine actually working has to **deploy the shift**,
  # which is the opening move of a match now rather than a line on a form. `deploy!` is that move.
  CREW = { crew_1: { minion: :test_hand_a },
           crew_2: { minion: :test_hand_b } }.freeze

  # The reference posting: one hand on the shovel, one on the oil round. Reproduces every balance
  # figure recorded before crew capacity — verified at 547.9 kPa and 495.5 kW against 547.8 and
  # the same rpm.
  def self.deploy!(op, stoking: :crew_1, oiling: :crew_2)
    op.assign_minion(stoking, :stoking) if stoking
    op.assign_minion(oiling, :oiling) if oiling
    op
  end

  # **The reference MACHINE, which is a different idea from the reference crew.**
  #
  # The blower slot defaults to `:hand_bellows`, because that is the starting blueprint and
  # raising steam by hand is meant to be the hard opening. But a bellows is an **effort station**
  # — a fourth one, against two seats — so an unmanned one delivers 0.302 kg/s, exactly what an
  # engine with no blower at all gets, and the machine never raises steam.
  #
  # Every balance figure in this repository was taken against the donkey, and the sketch says so:
  # *"deliberately today's figures, exactly."* So a spec measuring the MACHINE fits the donkey and
  # a spec about the bellows asks for it by name. Measured: donkey 608.8 kPa at t=1600, manned
  # bellows 608.1 at t=3800, unmanned bellows never.
  REFERENCE_LOADOUT = { blower: :donkey_blower }.freeze

  def self.loadout(overrides = {}) = REFERENCE_LOADOUT.merge(overrides || {})

  # ## Why this stubs `Content.default` rather than passing `content:`
  #
  # **Content is global and is never snapshotted.** `Operation.from_h` rebuilds through the
  # registered builder with no `content:`, so a restored match always resolves against
  # `Content.default` — which means a crew injected at build time simply does not exist after a
  # round trip, and the rebuild raises `unknown minion`.
  #
  # That is correct behaviour and worth knowing: content is data loaded once at boot and
  # identical in every process, so a *per-match* content registry is not a thing the snapshot
  # contract supports. Fixtures therefore have to be visible where the builder will look.
  #
  # What a spec merges into an operation spec to get the reference machine. Only the crew — the
  # content arrives through the hook below, because it has to be visible to the *builder* rather
  # than handed to one call.
  def self.options = { crew: CREW }
end

RSpec.configure do |config|
  # Opt in with `crew: :reference` on a describe block. A spec that runs a machine needs one;
  # a spec about crew quality posts its own people instead.
  config.before(:each, crew: :reference) do
    allow(ReactorSim::Content).to receive(:default).and_return(ReferenceCrew::CONTENT)
  end
end
