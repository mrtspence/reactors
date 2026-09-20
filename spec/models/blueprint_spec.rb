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
    it "covers all six kinds" do
      expect(described_class::KINDS)
        .to contain_exactly(:operation, :chassis, :part, :minion, :equipment, :training)
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

    # **`catalogued`, not `known`.** A spec rig registers globally — it must, or `Match.create`
    # cannot resolve it — and deriving from `known` picked one up as an operation nobody had
    # priced, which took the whole catalogue down. It only ever failed in a full-suite run,
    # because nothing else loads `spec/support/loop_rig.rb`; every targeted run passed.
    it "has one operation blueprint per catalogued machine, and none per spec rig" do
      expect(described_class.of_kind(:operation).map(&:blueprint_id))
        .to match_array(ReactorSim::Operations.catalogued.map(&:to_s))
    end

    it "ignores a harness even when one is registered" do
      ReactorSim::Operations.register(:spec_only_rig, harness: true) { |**| nil }
      described_class.reload!

      expect(described_class.of_kind(:operation).map(&:blueprint_id)).not_to include("spec_only_rig")
      expect(ReactorSim::Operations.known).to include(:spec_only_rig)
    end

    # **Per individual, not per archetype.** This said "archetype" for a release and enumerated
    # `fireman` and `yardhand`, which are jobs. What a player unlocks is a person.
    it "has one minion blueprint per hireable individual in the roster" do
      expect(described_class.of_kind(:minion).map(&:blueprint_id))
        .to match_array(ReactorSim::Content.default.hireable.keys.map(&:to_s))
    end

    # **Equipment and training are owned per minion**, so the catalogue is the cross product and
    # the id is scoped — exactly as a chassis id is scoped to its operation. Jim's apron and
    # Elowynne's apron are two unlocks, and buying one does not clothe the other.
    # **The last resort must never be for sale**, which is the whole of what makes it a last
    # resort: it turns up when nobody better will, and it cannot be taken away. It is an ordinary
    # individual in content — one resolution path, not a special case in the engine — and
    # `hireable: false` is the single field that keeps it out of the shop.
    it "does not offer the standin, nor kit or courses for it" do
      standin = ReactorSim::Content.default.minions.keys -
                ReactorSim::Content.default.hireable.keys

      expect(standin).not_to be_empty, "no standin in the roster at all"
      standin.each do |id|
        expect(described_class.key?(:minion, id)).to be(false)
        expect(described_class.key?(:equipment, "#{id}/leather_apron")).to be(false)
        expect(described_class.key?(:training, "#{id}/hot_work_ticket")).to be(false)
      end
    end

    it "scopes equipment to a minion, one blueprint per pairing" do
      roster = ReactorSim::Content.default.hireable.keys
      expected = roster.flat_map { |m| ReactorSim::Equipment.known.map { |i| "#{m}/#{i}" } }

      expect(described_class.of_kind(:equipment).map(&:blueprint_id)).to match_array(expected)
    end

    it "scopes training the same way" do
      roster = ReactorSim::Content.default.hireable.keys
      expected = roster.flat_map { |m| ReactorSim::Training.known.map { |t| "#{m}/#{t}" } }

      expect(described_class.of_kind(:training).map(&:blueprint_id)).to match_array(expected)
    end

    # **The price is the item's, not the pairing's.** Pricing every combination would put 39
    # identical lines in `config/blueprints.yml` today and need a fresh one whenever anybody
    # hires a minion — the inventory list that drifts, which is the shape `docs/CLAUDE.md` names
    # as the thing to avoid. `priced_as:` is what keeps one entry per item.
    it "charges every minion the same for the same item" do
      bills = ReactorSim::Content.default.hireable.keys.map do |minion|
        described_class.fetch(:equipment, "#{minion}/stokers_shovel").materials
      end

      expect(bills.uniq.length).to eq(1)
      expect(bills.first).not_to be_empty
    end

    it "carries the same gate to every minion's copy of a gated course" do
      gates = ReactorSim::Content.default.hireable.keys.map do |minion|
        described_class.fetch(:training, "#{minion}/hot_work_ticket").requires_achievement
      end

      expect(gates).to all(eq(:first_full_head_of_steam))
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

  # **The gates, stubbed in their real shape.** Nothing can pay a bill of materials yet — there is
  # no resource ledger — and nothing awards an achievement, so neither gate is enforced against a
  # player today. What is guarded here is that the data is *checkable*, because the cost of
  # getting this wrong is a part that is silently free or permanently locked.
  describe "gates" do
    # Several examples below stub the cost file and clear the memo to do it. Rebuilding
    # afterwards keeps a deliberately broken catalogue from leaking into the next example.
    after { described_class.reload! }

    it "prices every blueprint in the catalogue" do
      # Not `all?` — the failure message has to name which one, or a missing entry in a
      # thirty-four-line file is a scavenger hunt.
      expect(described_class.known.reject { |b| b.materials.is_a?(Hash) }).to be_empty
    end

    it "denominates a bill in resources the simulation knows" do
      described_class.known.each do |blueprint|
        blueprint.materials.each_key do |id|
          expect { ReactorSim::Content.default.resource(id) }
            .not_to raise_error, "#{blueprint.blueprint_id} is priced in unknown #{id}"
        end
      end
    end

    it "quotes quantities as positive numbers" do
      quantities = described_class.known.flat_map { |b| b.materials.values }

      expect(quantities).to all(be_a(Float).and(be_positive))
    end

    # **Free has to be written down.** The difference between "decided to be free" and "nobody
    # filled it in" is the whole reason a missing entry raises, and the starting operation is the
    # example that has to stay free.
    it "lets a blueprint be explicitly free" do
      expect(described_class.fetch(:operation, :steam_engine)).to be_free
      expect(described_class.fetch(:part, :locomotive_boiler)).not_to be_free
    end

    it "names only achievements that exist" do
      required = described_class.known.filter_map(&:requires_achievement)

      expect(required).not_to be_empty, "no blueprint exercises the achievement gate"
      expect(required.uniq).to all(satisfy { |id| Achievement.known?(id) })
    end

    describe "a blueprint the cost file does not price" do
      # `Ungated` fails the whole catalogue rather than the one entry, because a partly built
      # catalogue is how a part goes quietly missing from the workshop.
      it "raises, rather than treating it as free" do
        allow(described_class).to receive(:costs).and_return({})
        described_class.reload!

        expect { described_class.known }
          .to raise_error(Blueprint::Ungated, /no entry in config\/blueprints\.yml/)
      end
    end

    describe "a bill naming something nothing knows" do
      # There is no `copper` in `content/resources/materials.yml` — the six metals are cast iron,
      # wrought iron, steel, bronze, babbitt and fusible alloy. This is not a hypothetical: the
      # design sketch's own worked example priced a boiler in copper.
      it "refuses an unknown material" do
        allow(described_class).to receive(:costs)
          .and_return({ [ :operation, "steam_engine" ] => { "materials" => { "copper" => 5 } } })
        described_class.reload!

        expect { described_class.known }.to raise_error(ReactorSim::Error, /unknown resource/)
      end

      it "refuses an unknown achievement" do
        allow(described_class).to receive(:costs)
          .and_return({ [ :operation, "steam_engine" ] => { "requires" => "been_terribly_clever" } })
        described_class.reload!

        expect { described_class.known }
          .to raise_error(Blueprint::Ungated, /unknown achievement/)
      end
    end

    describe "obtainability" do
      let(:gated) { described_class.fetch(:part, :ramsbottom_safety_valve) }

      # **These no longer stub anything, and that is the point.** `Achievement.earned?` used to
      # return true unconditionally, so the only way to prove the gate was wired was to make the
      # stub say no. It reads `awards` now, so the gate can be opened the way a player opens it.
      it "opens once the prerequisite has actually been earned" do
        Award.grant(owner_id: DevPlayer::ID, achievement_id: gated.requires_achievement)

        expect(gated).to be_obtainable_by(DevPlayer::ID)
      end

      it "closes when the prerequisite is unmet" do
        expect(gated).not_to be_obtainable_by(DevPlayer::ID)
        expect(described_class.fetch(:part, :plain_chimney)).to be_obtainable_by(DevPlayer::ID)
      end
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
