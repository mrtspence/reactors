# frozen_string_literal: true

require "rails_helper"

# The catalogue of unlockable things.
#
# What matters here is that it is **derived** rather than written down. A hand-maintained list of
# "things a player can unlock" drifts the first time somebody registers a part without looking,
# and it drifts silently — the new part is simply unreachable, and nothing fails. So the guards
# below are mostly about coverage of the registries rather than about any particular entry.
#
# See `docs/design_sketches/blueprints.md` §1 and §5.
RSpec.describe Blueprint do
  describe "the catalogue" do
    it "covers all four kinds" do
      expect(described_class::KINDS).to contain_exactly(:operation, :chassis, :part, :minion)
      described_class::KINDS.each do |kind|
        expect(described_class.of_kind(kind)).not_to be_empty, "no #{kind} blueprints at all"
      end
    end

    # The derivation guarantee, and the reason this file exists. Register a part and it is
    # unlockable; no second list to remember.
    it "has exactly one part blueprint per registered part" do
      expect(described_class.of_kind(:part).map(&:blueprint_id))
        .to match_array(ReactorSim::Parts.known.map(&:to_s))
    end

    it "has one operation blueprint per registered operation type" do
      expect(described_class.of_kind(:operation).map(&:blueprint_id))
        .to match_array(ReactorSim::Operations.known.map(&:to_s))
    end

    it "has one minion blueprint per content archetype" do
      expect(described_class.of_kind(:minion).map(&:blueprint_id))
        .to match_array(ReactorSim::Content.default.minions.keys.map(&:to_s))
    end

    # Labels are the part's own, so the outfitting screen and the unlock list cannot disagree
    # about what something is called — and so a part's story stays in `parts.rb`.
    it "takes a part's label from the part rather than inventing one" do
      expect(described_class.fetch(:part, :ramsbottom_safety_valve).label)
        .to eq(ReactorSim::Parts.fetch(:ramsbottom_safety_valve).label)
    end
  end

  # **A chassis has no standalone existence.** Two machines could each call a frame `standard`,
  # and if the blueprint id were the bare frame name, unlocking one would silently unlock the
  # other. Same class of bug the simulation avoids by keeping ids in one flat namespace and
  # refusing duplicates outright.
  describe "chassis scoping" do
    it "scopes a chassis id to the operation it is a frame for" do
      expect(described_class.of_kind(:chassis).map(&:blueprint_id))
        .to contain_exactly("steam_engine/atmospheric", "steam_engine/high_pressure")
    end

    it "builds the same id the registry enumerates" do
      ReactorSim::Operations.chassis_for(:steam_engine).each do |frame|
        expect(described_class)
          .to be_key(:chassis, described_class.chassis_id(:steam_engine, frame))
      end
    end

    it "does not know a bare frame name" do
      expect(described_class).not_to be_key(:chassis, "high_pressure")
    end
  end

  describe "lookup" do
    # A blueprint that silently misses is a feature silently switched off — the rule that makes
    # `Parts.fetch` raise and `content_spec` refuse a material with no temperature rating.
    it "raises on an unknown id rather than returning nil" do
      expect { described_class.fetch(:part, :stock_boiler) }
        .to raise_error(Blueprint::Unknown, /no part blueprint/)
    end

    # The pair is the identity. A real part id is not a real chassis id.
    it "will not find a real id under the wrong kind" do
      expect(described_class).to be_key(:part, :locomotive_boiler)
      expect(described_class).not_to be_key(:chassis, :locomotive_boiler)
      expect { described_class.fetch(:chassis, :locomotive_boiler) }
        .to raise_error(Blueprint::Unknown)
    end

    it "accepts a symbol or a string for either half" do
      expect(described_class.fetch("part", "wide_damper"))
        .to eq(described_class.fetch(:part, :wide_damper))
    end
  end
end
