# frozen_string_literal: true

require "reactor_sim"

# Content is data, so mistakes in it are data mistakes: a typo surfaces mid-match as a nil,
# and an unbalanced reaction quietly creates matter every time it fires. Validation is
# eager and loud for exactly that reason — a bad content file should never reach a tick.
RSpec.describe ReactorSim::Content do
  # A complete archetype, so a spec about one thing does not have to spell out five stats it
  # does not care about. Every one of them is required, deliberately — see `STATS`.
  def human
    { label: "Human", strength: 1.0, toughness: 1.0, intelligence: 1.0,
      dexterity: 1.0, charisma: 1.0 }
  end

  describe "validation" do
    it "rejects a resource missing its physical properties" do
      expect {
        described_class.build(resources: { mystery: { tags: [ :liquid ] } })
      }.to raise_error(ReactorSim::Error, /mystery: missing/)
    end

    it "rejects a reaction referring to a resource that does not exist" do
      expect {
        described_class.build(
          resources: { a: { specific_heat_j_per_kg_k: 1, density_kg_per_m3: 1 } },
          reactions: { r: { consumes: { a: 1.0 }, produces: { ghost: 1.0 }, rate_per_s: 0.1,
                            enthalpy_j_per_unit: -1.0 } }
        )
      }.to raise_error(ReactorSim::Error, /unknown resource ghost/)
    end

    # The one that would be invisible otherwise. An unbalanced reaction breaks conservation
    # from inside a content file — somewhere nobody would think to look when the totals
    # stopped adding up.
    it "rejects a reaction that does not conserve mass" do
      expect {
        described_class.build(
          resources: {
            a: { specific_heat_j_per_kg_k: 1, density_kg_per_m3: 1 },
            b: { specific_heat_j_per_kg_k: 1, density_kg_per_m3: 1 }
          },
          reactions: { r: { consumes: { a: 1.0 }, produces: { b: 2.0 }, rate_per_s: 0.1,
                            enthalpy_j_per_unit: -1.0 } }
        )
      }.to raise_error(ReactorSim::Error, /mass not conserved/)
    end

    it "accepts a balanced reaction" do
      expect {
        described_class.build(
          resources: {
            a: { specific_heat_j_per_kg_k: 1, density_kg_per_m3: 1 },
            b: { specific_heat_j_per_kg_k: 1, density_kg_per_m3: 1 },
            c: { specific_heat_j_per_kg_k: 1, density_kg_per_m3: 1 }
          },
          reactions: { r: { consumes: { a: 1.0, b: 1.1 }, produces: { c: 2.1 }, rate_per_s: 0.1,
                            enthalpy_j_per_unit: -1.0 } }
        )
      }.not_to raise_error
    end

    it "raises on an unknown resource rather than returning nil" do
      registry = described_class.build(resources: {})

      expect { registry.resource(:nope) }.to raise_error(ReactorSim::Error, /unknown resource/)
    end

    it "rejects an archetype missing any of the five stats" do
      expect {
        described_class.build(archetypes: { idler: { label: "Idler", strength: 1.0 } })
      }.to raise_error(ReactorSim::Error, /idler: missing toughness/)
    end

    it "raises on an unknown archetype rather than returning nil" do
      registry = described_class.build(archetypes: {})

      expect { registry.archetype(:nope) }
        .to raise_error(ReactorSim::Error, /unknown archetype/)
    end

    # An individual naming a race that does not exist is a person with no stats at all, and the
    # failure would otherwise surface as a KeyError from inside the stat arithmetic, at the
    # moment somebody tried to work a lever with them.
    it "rejects a minion whose archetype does not exist" do
      expect {
        described_class.build(minions: { nobody: { name: "Nobody", archetype: :ghost } })
      }.to raise_error(ReactorSim::Error, /nobody: unknown archetype :ghost/)
    end

    it "rejects a minion with no name, which is all that separates one from an archetype" do
      expect {
        described_class.build(archetypes: { human: human }, minions: { jim: { archetype: :human } })
      }.to raise_error(ReactorSim::Error, /jim: missing name/)
    end
  end

  # Layers one and two of the four. Training and equipment are the delivery tier's, because they
  # are things a player OWNS — see docs/design_sketches/minions.md §2.
  describe "a minion's sheet" do
    let(:registry) do
      described_class.build(
        archetypes: { elf: human.merge(label: "Elf", strength: 0.75, dexterity: 1.2,
                                       tags: { darkvision: 0.3, clumsy: 0.1 }) },
        minions: { quick: { name: "Quick", archetype: :elf, stats: { dexterity: 0.15 },
                            tags: { keen_eyed: 0.25 } },
                   heavy: { name: "Heavy", archetype: :elf, stats: { strength: 0.35 },
                            tags: { darkvision: 0.2, clumsy: true } } }
      )
    end

    it "folds the race's baseline with the individual's own offsets" do
      expect(registry.sheet(:quick)[:stats][:dexterity]).to be_within(1e-9).of(1.35)
      expect(registry.sheet(:heavy)[:stats][:strength]).to be_within(1e-9).of(1.1)
    end

    it "leaves a stat the individual says nothing about at the race's figure" do
      expect(registry.sheet(:quick)[:stats][:strength]).to be_within(1e-9).of(0.75)
    end

    # **Two members of the same race are not the same worker**, which is the entire reason the
    # individual layer exists. Galathas is strong for an elf and heavy-handed with it.
    it "separates two individuals of one race" do
      quick = registry.sheet(:quick)[:stats]
      heavy = registry.sheet(:heavy)[:stats]

      expect(heavy[:strength]).to be > quick[:strength]
      expect(heavy[:dexterity]).to be < quick[:dexterity]
    end

    it "adds tag values from both layers and keeps the ones only one layer has" do
      expect(registry.sheet(:heavy)[:tags][:darkvision]).to be_within(1e-9).of(0.5)
      expect(registry.sheet(:quick)[:tags]).to include(darkvision: 0.3, keen_eyed: 0.25)
    end

    # `true` means a trait is simply present. Adding to it would be nonsense, so it wins outright
    # rather than being coerced into arithmetic.
    it "lets a present-or-absent tag win over a numeric one rather than summing them" do
      expect(registry.sheet(:heavy)[:tags][:clumsy]).to be(true)
    end
  end

  describe "the shipped content" do
    let(:content) { described_class.default }

    it "loads water and steam" do
      expect(content.tags(:water)).to include(:liquid)
      expect(content.tags(:steam)).to include(:gas)
    end

    # The gap between the two formation enthalpies IS the latent heat. If it drifts, boiling
    # and condensing stop being each other's inverse and energy leaks across every phase
    # change in the game.
    it "keeps the latent heat consistent with the two formation enthalpies" do
      t = 373.15
      h_water = (content.specific_heat(:water) * t) + content.formation_enthalpy(:water)
      h_steam = (content.specific_heat(:steam) * t) + content.formation_enthalpy(:steam)
      latent = content.phase(:water).fetch(:latent_heat_j_per_kg)

      expect(h_steam - h_water).to be_within(1.0).of(latent)
    end

    # Materials are resources like anything else, so a foundry could one day produce them.
    # What a structural part needs is the ratio of tensile strength to density, and both
    # live here rather than inside whatever is made of them.
    it "carries mechanical properties for structural materials" do
      expect(content.tensile_strength_pa(:cast_iron)).to be > 0.0
      expect(content.density(:cast_iron)).to be > 0.0
      expect(content.tags(:cast_iron)).to include(:structural)
    end

    it "makes steel a better flywheel material than cast iron" do
      ratio = ->(m) { content.tensile_strength_pa(m) / content.density(m) }

      expect(ratio.call(:steel)).to be > ratio.call(:cast_iron)
    end

    # Asking a substance that was never meant to be built with for a tensile strength should
    # say so, not feed a nil into a stress calculation.
    it "refuses to treat a fluid as a structural material" do
      expect { content.tensile_strength_pa(:water) }
        .to raise_error(ReactorSim::Error, /cannot be used as a structural material/)
    end

    # **This exists because a missing rating is silent and total.** Over-temperature fatigue in
    # `Vessel` and `Conduit` was complete and wired from the day `Wearing` landed, and had never
    # once fired in any operation, because every node shipped `Float::INFINITY` and
    # `stress_per_second` returned on its first branch every time. Nothing failed, nothing
    # warned, and the mechanic simply did not exist.
    #
    # `max_temperature_k` returns infinity for a resource that declares none, which is right for
    # coal and steam and wrong for anything a boiler is built out of — so the guard belongs here,
    # on the tag that says "things are made of this".
    it "rates every structural material for temperature" do
      structural = content.resources.keys.select { |id| content.tags(id).include?(:structural) }

      expect(structural).not_to be_empty
      structural.each do |id|
        expect(content.max_temperature_k(id)).to be_finite,
          "#{id} is tagged :structural but declares no max_temperature_k, which silently " \
          "disables over-temperature failure for everything built from it"
      end
    end

    # It is the temperature the metal stops being structural at, NOT its melting point — steel
    # is useless as a pressure boundary hundreds of kelvin before it melts. The ordering below is
    # the one the crown sheet depends on: the plug has to go before the plate does.
    it "makes the fusible alloy let go before the boiler plate it protects" do
      expect(content.max_temperature_k(:fusible_alloy))
        .to be < content.max_temperature_k(:wrought_iron)
    end

    it "returns infinity for a substance with no temperature rating" do
      expect(content.max_temperature_k(:water)).to eq(Float::INFINITY)
    end

    it "indexes the phase pair from both the liquid and the vapour side" do
      expect(content.phase_pair(:water)).to eq([ :water, :steam ])
      expect(content.phase_pair(:steam)).to eq([ :water, :steam ])
    end
  end
end
