# frozen_string_literal: true

require "reactor_sim"

# **What a reaction does when it cannot get enough of one reagent.**
#
# A fire with air to spare burns clean. The same fire with half the air it wants burns all of
# its fuel anyway and makes carbon monoxide doing it — that is not the reaction going slower,
# it is a different reaction, and the supply of one named reagent decides how much of each
# happens. Most of industrial chemistry is this: coking, producer gas, a blast furnace running
# reducing rather than oxidising.
#
# The arithmetic needs no tuning and this file is mostly about proving that. With `a₁` and `a₂`
# per unit and `A` available, the split that spends `A` exactly is `x·a₁ + (E−x)·a₂ = A`, so
# the examples check kilograms against that equation rather than against a measured figure.
#
# See `docs/design_sketches/reaction-pathways.md`.
RSpec.describe ReactorSim::Resources::Reaction do
  # A made-up chemistry, so nothing here moves when coal is rebalanced. One `stuff` plus some
  # `air`, either cleanly or — for half the air — dirtily, leaving `soot` behind.
  RESOURCES = {
    stuff: { tags: %i[solid fuel], specific_heat_j_per_kg_k: 1000.0, density_kg_per_m3: 800.0 },
    air: { tags: %i[gas oxidiser breathable], specific_heat_j_per_kg_k: 1005.0,
           density_kg_per_m3: 1.225, molar_mass_g_per_mol: 28.96 },
    steam_x: { tags: %i[gas], specific_heat_j_per_kg_k: 2000.0, density_kg_per_m3: 0.6,
               molar_mass_g_per_mol: 18.0 },
    clean_gas: { tags: %i[gas exhaust], specific_heat_j_per_kg_k: 1100.0,
                 density_kg_per_m3: 1.1, molar_mass_g_per_mol: 29.5 },
    soot: { tags: %i[gas exhaust], specific_heat_j_per_kg_k: 1100.0,
            density_kg_per_m3: 1.1, molar_mass_g_per_mol: 28.0 }
  }.freeze

  CLEAN = { consumes: { stuff: 1.0, air: 10.0 }, produces: { clean_gas: 11.0 },
            rate_per_s: 1.0, enthalpy_j_per_unit: -1.0e6 }.freeze

  # Half the air, and it leaves soot rather than clean gas.
  DIRTY = { consumes: { stuff: 1.0, air: 5.0 }, produces: { soot: 6.0 },
            enthalpy_j_per_unit: -4.0e5 }.freeze

  def content(reactions)
    ReactorSim::Content.build(resources: RESOURCES, reactions: reactions)
  end

  def spec(alternatives: [ DIRTY ], **overrides)
    CLEAN.merge(limited_by: :air, alternatives: alternatives, **overrides)
  end

  def parcels(mix, content)
    mix.map do |resource, kg|
      ReactorSim::Parcel.build(resource: resource, kg: kg, temperature_k: 1_000.0,
                               content: content)
    end
  end

  def burn(reaction, mix, dt: 1_000.0)
    c = content(burn: reaction)
    described_class.advance(reaction, parcels(mix, c), temperature_k: 1_000.0, dt: dt,
                                                       content: c)
  end

  def kg(result, resource)
    result.first.find { |p| p.fetch(:resource) == resource }&.fetch(:kg) || 0.0
  end

  # `dt` long enough that the closed form is effectively complete, so an example is about the
  # allocation rather than about the rate.
  describe "when the gated reagent is plentiful" do
    it "runs the preferred pathway and nothing else" do
      # 5 kg of stuff wants 50 kg of air and has 80.
      result = burn(spec, { stuff: 5.0, air: 80.0 })

      expect(kg(result, :soot)).to eq(0.0)
      expect(kg(result, :clean_gas)).to be_within(1e-6).of(55.0)
      expect(kg(result, :stuff)).to be_within(1e-6).of(0.0)
    end

    # The claim that protects every tuned reaction in the game: declaring alternatives may not
    # change what a reaction does while it has what it wants.
    it "matches the same reaction declared with no alternatives at all" do
      rich = { stuff: 5.0, air: 80.0 }

      with = burn(spec, rich)
      without = burn(CLEAN, rich)

      expect(kg(with, :clean_gas)).to be_within(1e-9).of(kg(without, :clean_gas))
      expect(with.last).to be_within(1e-9).of(without.last)
    end
  end

  describe "when the gated reagent runs short" do
    # 4 kg of stuff, 30 kg of air. Clean wants 40, dirty wants 20, so all 4 kg react:
    #   x·10 + (4−x)·5 = 30  →  x = 2.
    it "splits the extent so the supply is spent exactly" do
      result = burn(spec, { stuff: 4.0, air: 30.0 })

      expect(kg(result, :clean_gas)).to be_within(1e-6).of(2.0 * 11.0)
      expect(kg(result, :soot)).to be_within(1e-6).of(2.0 * 6.0)
      expect(kg(result, :air)).to be_within(1e-6).of(0.0)
    end

    # **The point of the whole mechanism.** Starved, the fire burns all of its fuel rather than
    # banking it — a rich flame consumes more fuel per unit of air, not less.
    it "burns fuel a single-pathway reaction would have left alone" do
      lean = { stuff: 4.0, air: 30.0 }

      tiered = burn(spec, lean)
      single = burn(CLEAN, lean)

      expect(kg(tiered, :stuff)).to be_within(1e-6).of(0.0)
      expect(kg(single, :stuff)).to be_within(1e-6).of(1.0)
    end

    # And it is worth less heat, which is the trade: more fuel gone, less to show for it.
    it "releases less energy per kilogram of fuel than burning clean" do
      starved = burn(spec, { stuff: 4.0, air: 30.0 })
      rich = burn(spec, { stuff: 4.0, air: 80.0 })

      expect(starved.last).to be < rich.last
      expect(starved.last).to be_within(1e-3).of((2.0 * 1.0e6) + (2.0 * 4.0e5))
    end
  end

  describe "when even the last pathway cannot be fed" do
    # 6 kg of stuff, 15 kg of air. Dirty wants 30, so only 3 kg can react at all.
    it "falls back to capping the extent, as a single-pathway reaction always has" do
      result = burn(spec, { stuff: 6.0, air: 15.0 })

      expect(kg(result, :clean_gas)).to eq(0.0)
      expect(kg(result, :soot)).to be_within(1e-6).of(3.0 * 6.0)
      expect(kg(result, :stuff)).to be_within(1e-6).of(3.0)
    end
  end

  describe "three pathways" do
    # Cleanest first, then middling, then the last resort.
    MIDDLING = { consumes: { stuff: 1.0, air: 7.0 }, produces: { soot: 8.0 },
                 enthalpy_j_per_unit: -7.0e5 }.freeze

    it "spends the supply on the cleanest pathway that still lets the rest be paid for" do
      # 4 kg, 34 air. Cheapest of the rest is 5, so the clean share solves
      #   x·10 + (4−x)·5 = 34  →  x = 2.8, and the middling pathway is never reached.
      result = burn(spec(alternatives: [ MIDDLING, DIRTY ]), { stuff: 4.0, air: 34.0 })

      expect(kg(result, :clean_gas)).to be_within(1e-6).of(2.8 * 11.0)
      expect(kg(result, :air)).to be_within(1e-6).of(0.0)
      expect(kg(result, :stuff)).to be_within(1e-6).of(0.0)
    end
  end

  # The seam. Nothing in the game uses it yet, so this rig is its only coverage — which is
  # exactly why it has one. See `Resources::Reaction.extra_reagent_cap`.
  describe "a pathway that needs a reagent the preferred one does not" do
    WATER_GAS = { consumes: { stuff: 1.0, air: 0.0, steam_x: 2.0 },
                  produces: { clean_gas: 3.0 }, enthalpy_j_per_unit: 5.0e5 }.freeze

    it "runs it when that reagent is there, and it needs none of the gated one" do
      result = burn(spec(alternatives: [ WATER_GAS ]), { stuff: 4.0, air: 20.0, steam_x: 8.0 })

      # Air pays for 2 clean; the rest goes the steam route while the steam lasts.
      expect(kg(result, :stuff)).to be_within(1e-6).of(0.0)
      expect(kg(result, :steam_x)).to be_within(1e-6).of(4.0)
      expect(kg(result, :air)).to be_within(1e-6).of(0.0)
    end

    it "skips it when that reagent is absent, and the fuel simply waits" do
      result = burn(spec(alternatives: [ WATER_GAS ]), { stuff: 4.0, air: 20.0 })

      expect(kg(result, :stuff)).to be_within(1e-6).of(2.0)
      expect(kg(result, :clean_gas)).to be_within(1e-6).of(2.0 * 11.0)
    end
  end

  describe "conservation" do
    it "conserves mass across a split extent" do
      mix = { stuff: 4.0, air: 30.0 }
      c = content(burn: spec)
      before = parcels(mix, c).sum { |p| p.fetch(:kg) }

      after = described_class.advance(spec, parcels(mix, c), temperature_k: 1_000.0,
                                                             dt: 1_000.0, content: c)

      expect(after.first.sum { |p| p.fetch(:kg) }).to be_within(1e-9).of(before)
    end

    # Enthalpy rides with the mass and the reaction's own energy is the only thing added, so
    # the parcels' own joules must be untouched by the swap — the same rule one pathway follows.
    it "carries the reactants' enthalpy into the products" do
      mix = { stuff: 4.0, air: 30.0 }
      c = content(burn: spec)
      before = parcels(mix, c).sum { |p| p.fetch(:joules) }

      after = described_class.advance(spec, parcels(mix, c), temperature_k: 1_000.0,
                                                             dt: 1_000.0, content: c)

      expect(after.first.sum { |p| p.fetch(:joules) }).to be_within(1e-3).of(before)
    end
  end

  # **Silence must never be the safe answer**: every one of these would otherwise be a reaction
  # that quietly does something other than what it reads as.
  describe "what the content registry refuses" do
    def build(reaction)
      ReactorSim::Content.build(resources: RESOURCES, reactions: { burn: reaction })
    end

    it "refuses alternatives with no limited_by" do
      expect { build(CLEAN.merge(alternatives: [ DIRTY ])) }
        .to raise_error(ReactorSim::Error, /need limited_by/)
    end

    it "refuses a limited_by the reaction does not consume" do
      expect { build(spec(limited_by: :soot)) }
        .to raise_error(ReactorSim::Error, /does not consume/)
    end

    it "refuses a pathway that does not balance" do
      expect { build(spec(alternatives: [ DIRTY.merge(produces: { soot: 9.0 }) ])) }
        .to raise_error(ReactorSim::Error, /alternative 1: mass not conserved/)
    end

    # Rule 2, and the one that matters: the pathways have to be fates for the same fuel.
    it "refuses a pathway that consumes a different amount of the shared reagent" do
      expect { build(spec(alternatives: [ DIRTY.merge(consumes: { stuff: 2.0, air: 5.0 },
                                                      produces: { soot: 7.0 }) ])) }
        .to raise_error(ReactorSim::Error, /different fate for the same stuff/)
    end

    it "refuses alternatives declared cheapest-first" do
      expect { build(spec(alternatives: [ DIRTY, CLEAN.reject { |k, _| k == :rate_per_s } ])) }
        .to raise_error(ReactorSim::Error, /alternatives run most-first/)
    end

    it "refuses a pathway missing its own enthalpy" do
      expect { build(spec(alternatives: [ DIRTY.reject { |k, _| k == :enthalpy_j_per_unit } ])) }
        .to raise_error(ReactorSim::Error, /alternative 1: missing enthalpy_j_per_unit/)
    end
  end
end
