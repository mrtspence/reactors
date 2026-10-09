# frozen_string_literal: true

require "reactor_sim"
require "support/ignition_rig"

# **What a district full of gas and dust does when it meets a flame — at the limits, not at one
# arbitrary point on the way past them.**
#
# `ignition_spec` already proves the flammability-limit *mechanism* against synthetic resources.
# This is the other half and it cannot be said there: that with the **game's real firedamp, real
# air and real reactions**, a district lights between about 5% and 15% by volume and not outside
# it. Mass and volume are different questions — firedamp is 0.668 kg/m³ against air's 1.225 — so a
# limit that is right in one is wrong by nearly a factor of two in the other, and only real
# content can settle it.
#
# ## Why this is not in `firedamp_spec` or `dust_spec`
#
# Those are the mine's integration specs, and reaching a 7% mixture by *seepage* takes two or three
# thousand ticks of waiting — which is how a handful of claims about chemistry came to cost minutes
# each and still only ever probed one point. Everything here is deterministic and state is a plain
# hash, so the mixture is **constructed** and only the ticks that decide the outcome are run.
# Measured: **40 ms per case**, against minutes, and it tests both limits instead of neither.
#
# What stays in the mine's own specs is the **wiring** — that a mine actually produces firedamp,
# reads the naked-flame lever, and hurts the people standing in the district.
#
# See `docs/design_sketches/suite-runtime.md`.
RSpec.describe "a district meeting a flame" do
  include IgnitionRig

  # The limits the design states, in `content/reactions/combustion.yml`. **Methods rather than
  # constants**: a constant assigned inside an example group resolves lexically and lands on
  # `Object`, so two spec files naming one overwrite each other silently, and which wins depends
  # on the randomised file order.
  def lean = 0.05

  def rich = 0.15

  def fired(firedamp: 0.0, coal_dust: 0.0)
    op = rig(firedamp: firedamp, coal_dust: coal_dust)
    events = light!(op)

    { lit: events.any? { |e| e[:type] == :fire_lit }, peak: temperature(op), op: op }
  end

  describe "the flammability limits, in real content" do
    # **Both sides of the lean limit**, which is the figure a safety lamp exists to read. A
    # district at 4% is a district a naked light does not fire — and that is what makes the 1.04%
    # the mine sits at ordinarily a *safe* district rather than a lucky one.
    it "will not light below the lean limit" do
      expect(fired(firedamp: lean - 0.01).fetch(:lit)).to be(false)
      expect(fired(firedamp: lean - 0.03).fetch(:lit)).to be(false)
    end

    it "lights inside the band" do
      [ 0.06, 0.08, 0.12 ].each do |fraction|
        expect(fired(firedamp: fraction).fetch(:lit)).to be(true), "#{fraction} should carry a flame"
      end
    end

    # **The rich limit is the half nobody expects, and it is why a district can be TOO gassy to
    # explode.** It is also the reason an afterdamp fixture has to be lit at a measured moment
    # rather than "once there is plenty of gas".
    it "will not light above the rich limit" do
      expect(fired(firedamp: rich + 0.01).fetch(:lit)).to be(false)
      expect(fired(firedamp: rich + 0.05).fetch(:lit)).to be(false)
    end

    # Asserted as an ordering rather than as temperatures, because the peak is a balance figure
    # and the shape is the contract: a mixture near a limit burns feebly, one in the middle does
    # not.
    it "burns hardest in the middle of the band" do
      near_limit = fired(firedamp: lean + 0.01).fetch(:peak)
      middle = fired(firedamp: 0.10).fetch(:peak)

      expect(middle).to be > near_limit
    end
  end

  describe "what the fire then does" do
    it "takes the district past what a roadway stands" do
      expect(fired(firedamp: 0.09).fetch(:peak)).to be > IgnitionRig::MAX_TEMPERATURE_K
    end

    # **Dust carries an explosion a gas mixture could not sustain on its own**, which is the
    # mechanism behind Courrières and Senghenydd and the reason stone dusting exists. Below the
    # lean limit the gas cannot carry a flame — so if this lights, the dust is what did it.
    it "carries on dust where the gas alone is too lean" do
      gas_only = fired(firedamp: lean - 0.01)
      with_dust = fired(firedamp: lean - 0.01, coal_dust: 400.0)

      expect(gas_only.fetch(:lit)).to be(false)
      expect(with_dust.fetch(:lit)).to be(true)
      expect(with_dust.fetch(:peak)).to be > gas_only.fetch(:peak)
    end

    it "eats the air it burned in" do
      op = fired(firedamp: 0.09).fetch(:op)

      expect(held(op, :air)).to be < IgnitionRig::AIR_KG
      expect(held(op, :flue_gas)).to be > 0.0
    end
  end

  # The conversion that makes every figure above mean what it says. A limit stated by mass would
  # be wrong by nearly a factor of two, and nothing downstream would notice.
  it "states its mixtures by volume, not by mass" do
    air_kg = IgnitionRig::AIR_KG
    kg = IgnitionRig.firedamp_kg(0.05, air_kg)
    densities = ReactorSim::Content.default

    by_volume = (kg / densities.density(:firedamp)) /
                ((kg / densities.density(:firedamp)) + (air_kg / densities.density(:air)))

    expect(by_volume).to be_within(1e-6).of(0.05)
    expect(kg / (kg + air_kg)).to be < 0.03, "the same mixture is under 3% by mass"
  end
end
