# frozen_string_literal: true

require "reactor_sim"

# **A district with exactly the mixture you want in it, and a flame.**
#
# The mine specs were slow for a reason that had nothing to do with what they assert: to test what
# a 7% mixture does when it meets a flame, they ran a pit for two or three thousand ticks until the
# seep happened to produce 7%, then lit it. Everything in this engine is deterministic and state
# is a plain hash — so the mixture can simply be **built**, and only the ticks that decide the
# claim need running.
#
# That is faster by two orders of magnitude and it is a **better test**, because a constructed
# mixture can be put exactly where the claim is: at the lean limit, a hair under it, a hair over
# the rich limit. Waiting for a seep gives you one arbitrary point on the way past.
#
# ## Why the state is reachable rather than invented
#
# `Vessel#initial_contents` is the engine's own seeding path and derives each parcel's enthalpy
# from the resource's specific heat at the temperature given — so a rig built here holds a mixture
# the simulation could have arrived at itself. **Hand-writing `joules` into a parcel would not**:
# it is how you get a district at a temperature its contents cannot explain, and then the spec is
# testing a state that cannot exist.
#
# ## What this is not for
#
# Wiring. That a *mine* puts firedamp into its district, reads the naked-flame lever and hurts the
# people standing there is an integration claim and belongs in the mine's own spec. This rig
# answers only "given this mixture, what does the chemistry do".
module IgnitionRig
  # The mine's district, to the figures that matter for combustion — see
  # `Operations::Mine`'s `:district`. Copied rather than imported because a rig that drifts with
  # the mine is a rig that stops isolating anything; if these diverge, that is a decision somebody
  # should have to make on purpose.
  VOLUME_M3 = 1_400.0
  AIR_KG = 1_700.0
  HEAT_CAPACITY = 3.0e5
  MAX_TEMPERATURE_K = 480.0
  AMBIENT_K = 292.0

  module_function

  # A district holding `air` plus whatever `mix` names, at `AMBIENT_K`, with an open flame on a
  # lever. `firedamp:` is given as a **fraction by volume of the gas**, because that is the
  # quantity the flammability limits are stated in and converting it here is what keeps an example
  # readable.
  def district(firedamp: 0.0, coal_dust: 0.0, air_kg: AIR_KG)
    mix = [ { resource: :air, kg: air_kg } ]
    mix << { resource: :firedamp, kg: firedamp_kg(firedamp, air_kg) } if firedamp.positive?
    mix << { resource: :coal_dust, kg: coal_dust } if coal_dust.positive?

    ReactorSim::Nodes::Vessel.new(
      id: :district, label: "District", volume_m3: VOLUME_M3,
      heat_capacity: HEAT_CAPACITY, ambient_conductance: 300.0, ambient_k: AMBIENT_K,
      initial_temperature_k: AMBIENT_K,
      initial_contents: mix.map { |p| p.merge(temperature_k: AMBIENT_K) },
      reactions: %i[firedamp_combustion coal_dust_combustion],
      heater_control_id: :naked_flame, heater_watts: 1.2e3, igniter_kg_per_s: 4.0e-4,
      max_temperature_k: MAX_TEMPERATURE_K, stress_rate: 2.4
    )
  end

  # **By volume, not by mass**, which is the trap the whole damp model rests on: firedamp is
  # 0.668 kg/m³ against air's 1.225, so a mixture that is 5% by volume is about 2.8% by mass.
  # Stating a limit in mass would silently move every figure in the design by a factor of two.
  def firedamp_kg(fraction, air_kg)
    air_m3 = air_kg / ReactorSim::Content.default.density(:air)

    fraction / (1.0 - fraction) * air_m3 * ReactorSim::Content.default.density(:firedamp)
  end

  def rig(**mix)
    ReactorSim::Operation.new(id: :rig, type: :test, seed: 1,
                              nodes: [ district(**mix) ],
                              control_points: [ ReactorSim::ControlPoint.new(id: :naked_flame) ])
  end

  # Hold a flame to it and see what happens. Tens of ticks, because an ignition is immediate —
  # what used to need thousands was the *waiting for a mixture*, never the burning.
  def light!(op, ticks: 40)
    op.set_control(:naked_flame, 100)
    ticks.times.flat_map { |i| op.step!(tick: i + 1) }
  end

  def temperature(op)
    op.nodes.fetch(:district).temperature_k(op.state.fetch(:nodes).fetch(:district), op.content)
  end

  def held(op, resource)
    ReactorSim::Parcel.total_kg(
      op.state.dig(:nodes, :district, :parcels).select { |p| p.fetch(:resource) == resource }
    )
  end
end
