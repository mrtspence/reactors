# frozen_string_literal: true

require "reactor_sim"

# How much of the fuel is alight, and what that does to the burn.
#
# The model exists because a lumped-temperature node cannot honestly represent a match: it has
# no hot spot, so gating combustion on the BULK temperature made fire all-or-nothing, and the
# only winning move was to hold the igniter on forever
# (docs/design_sketches/ignition.md).
RSpec.describe ReactorSim::Resources::Ignition do
  let(:content) do
    ReactorSim::Content.build(
      resources: {
        coal: { tags: [ :solid, :fuel ], specific_heat_j_per_kg_k: 1300, density_kg_per_m3: 800 },
        air: { tags: [ :gas, :oxidiser ], specific_heat_j_per_kg_k: 1005,
               density_kg_per_m3: 1.2, molar_mass_g_per_mol: 28.96 },
        ash: { tags: [ :solid, :waste ], specific_heat_j_per_kg_k: 840, density_kg_per_m3: 700 }
      },
      reactions: {
        burn: { consumes: { coal: 1.0, air: 11.0 }, produces: { ash: 12.0 },
                enthalpy_j_per_unit: -30_000_000, rate_per_s: 6.0, min_temperature_k: 500,
                ignition: { spread_per_s: 0.30, quench_per_s: 0.45 } },
        # No `ignition:` block — the opt-in that keeps every pre-existing reaction untouched.
        inert: { consumes: { coal: 1.0, air: 11.0 }, produces: { ash: 12.0 },
                 enthalpy_j_per_unit: -30_000_000, rate_per_s: 6.0, min_temperature_k: 500 }
      }
    )
  end

  let(:spec) { content.reaction(:burn) }
  let(:fuelled) { [ { resource: :coal, kg: 10.0, joules: 0.0 }, { resource: :air, kg: 5.0, joules: 0.0 } ] }

  def advance(ignition, parcels: fuelled, temperature_k: 600.0, seed_kg: 0.0, dt: 0.25)
    described_class.advance(spec, ignition, parcels, temperature_k: temperature_k, dt: dt,
                                                    content: content, seed_kg: seed_kg)
  end

  describe "opting in" do
    it "models ignition only where content asks for it" do
      expect(described_class.modelled?(spec)).to be(true)
      expect(described_class.modelled?(content.reaction(:inert))).to be(false)
    end
  end

  describe "needing a spark" do
    # The property the whole model rests on. Logistic growth from exactly zero stays at zero,
    # which is what makes the igniter a match rather than a switch.
    it "stays out no matter how hot or well aired, with nothing alight" do
      result = advance({ kg: 0.0, oxidiser_kg: 99.0 }, temperature_k: 2000.0)

      expect(result.fetch(:kg)).to eq(0.0)
    end

    it "catches from a seed" do
      result = advance({ kg: 0.0, oxidiser_kg: 0.0 }, seed_kg: 0.01)

      expect(result.fetch(:kg)).to be > 0.01
    end
  end

  describe "spreading" do
    it "grows a fire that has taken hold" do
      result = advance({ kg: 1.0, oxidiser_kg: 500.0 })

      expect(result.fetch(:kg)).to be > 1.0
    end

    # Spread must NOT be gated on the bulk temperature. Gating it there is what made the first
    # attempt at this model fail exactly as the one it replaced: a fire cannot reach 500 K
    # without spreading, and cannot spread without reaching 500 K. A flame front is hot even
    # when the room is cold.
    it "still spreads in a firebox far below the sustaining temperature" do
      result = advance({ kg: 1.0, oxidiser_kg: 500.0 }, temperature_k: 300.0)

      expect(result.fetch(:kg)).to be > 1.0
    end

    # Air has to be abundant for this to be a fair test: starvation and chill are combined by
    # taking whichever is worse, so a fire short of draught spreads at the same rate hot or
    # cold — correctly, since the air is what is holding it back.
    it "spreads faster when the firebox is hot than when it is cold" do
      hot = advance({ kg: 1.0, oxidiser_kg: 500.0 }, temperature_k: 900.0).fetch(:kg)
      cold = advance({ kg: 1.0, oxidiser_kg: 500.0 }, temperature_k: 300.0).fetch(:kg)

      expect(hot).to be > cold
    end

    it "cannot light more fuel than is present" do
      result = advance({ kg: 9.9, oxidiser_kg: 50.0 }, dt: 1000.0)

      expect(result.fetch(:kg)).to be <= 10.0
    end
  end

  describe "going out" do
    it "dies back when starved of air" do
      starved = [ { resource: :coal, kg: 10.0, joules: 0.0 } ]
      result = advance({ kg: 1.0, oxidiser_kg: 0.0 }, parcels: starved)

      expect(result.fetch(:kg)).to be < 1.0
    end

    it "leaves an ember rather than snapping to nothing" do
      starved = [ { resource: :coal, kg: 10.0, joules: 0.0 } ]
      result = advance({ kg: 1.0, oxidiser_kg: 0.0 }, parcels: starved)

      expect(result.fetch(:kg)).to be > 0.0
    end

    it "goes out when the fuel is gone, and refilling does not relight it" do
      empty = [ { resource: :air, kg: 5.0, joules: 0.0 } ]
      out = advance({ kg: 1.0, oxidiser_kg: 500.0 }, parcels: empty)

      expect(out.fetch(:kg)).to eq(0.0)
      expect(advance(out).fetch(:kg)).to eq(0.0)
    end
  end

  # Air passes THROUGH a firebox and its standing inventory oscillates to zero every other
  # tick — a period-2 limit cycle from the one-tick-per-hop delay. Read instantaneously that
  # says "starved" on a fire consuming barely one percent of what blows past it, and it killed
  # the fire two ticks at a time. A bed of burning coal has real thermal inertia and does not
  # go out because the draught faltered for 250 ms.
  describe "remembering the draught" do
    it "survives a tick with no air at all, having just had plenty" do
      airless = [ { resource: :coal, kg: 10.0, joules: 0.0 } ]
      result = advance({ kg: 1.0, oxidiser_kg: 500.0 }, parcels: airless)

      expect(result.fetch(:kg)).to be >= 1.0
    end

    it "still dies if the air never comes back" do
      airless = [ { resource: :coal, kg: 10.0, joules: 0.0 } ]
      state = { kg: 1.0, oxidiser_kg: 500.0 }
      # Long enough for the remembered draught to decay well past what the fire needs, and
      # then for the fire to burn down. Memory buys it seconds, not indefinite life.
      60.times { state = advance(state, parcels: airless) }

      expect(state.fetch(:kg)).to be < 0.1
    end

    it "forgets the draught it has not seen, rather than remembering it forever" do
      airless = [ { resource: :coal, kg: 10.0, joules: 0.0 } ]
      result = advance({ kg: 1.0, oxidiser_kg: 500.0 }, parcels: airless)

      expect(result.fetch(:oxidiser_kg)).to be < 500.0
    end
  end

  describe "the fraction alight" do
    it "is the lit mass over the fuel present" do
      fraction = described_class.fraction(spec, { kg: 2.5 }, fuelled, content: content)

      expect(fraction).to eq(0.25)
    end

    # Shovelling cold fuel onto a fire damps it. This falls out for free from storing the lit
    # MASS and deriving the fraction, which is the same choice the rest of the physics makes.
    it "falls when fresh fuel is piled on, without the fire itself changing" do
      doubled = [ { resource: :coal, kg: 20.0, joules: 0.0 } ]
      before = described_class.fraction(spec, { kg: 2.5 }, fuelled, content: content)
      after = described_class.fraction(spec, { kg: 2.5 }, doubled, content: content)

      expect(after).to be < before
    end
  end
end
