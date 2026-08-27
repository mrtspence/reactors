# frozen_string_literal: true

require "reactor_sim"

# Content is data, so mistakes in it are data mistakes: a typo surfaces mid-match as a nil,
# and an unbalanced reaction quietly creates matter every time it fires. Validation is
# eager and loud for exactly that reason — a bad content file should never reach a tick.
RSpec.describe ReactorSim::Content do
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

    it "indexes the phase pair from both the liquid and the vapour side" do
      expect(content.phase_pair(:water)).to eq([ :water, :steam ])
      expect(content.phase_pair(:steam)).to eq([ :water, :steam ])
    end
  end
end
