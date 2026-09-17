# frozen_string_literal: true

require "reactor_sim"

# Equipment and training: layers three and four of a minion's sheet.
#
# Both are registries rather than content for the reason `Parts` is — the pull of data was never
# diffability, it was letting somebody outside this repository add one, and that is ruled out.
# What is worth guarding here is the shape they must keep so the four layers fold through one
# arithmetic: offsets, valued tags, and an id that cannot be quietly reused.
RSpec.describe "the kit catalogue" do
  describe ReactorSim::Equipment do
    it "files every registered item under one of exactly three slots" do
      expect(described_class::SLOTS).to contain_exactly(:tool, :gear, :utility)

      described_class.known.each do |id|
        expect(described_class::SLOTS).to include(described_class.fetch(id).slot),
                                          "#{id} is in no slot"
      end
    end

    it "offers something for each slot, or the slot is furniture" do
      described_class::SLOTS.each do |slot|
        expect(described_class.of_slot(slot)).not_to be_empty, "nothing fits #{slot}"
      end
    end

    it "refuses a slot it does not have, rather than filing it nowhere" do
      expect { described_class.new(id: :hat, slot: :head) }
        .to raise_error(ReactorSim::Error, /unknown slot :head/)
    end

    # An id is the address a roster uses, so a silent overwrite would mean a snapshot rebuilding
    # a different kit from the same name — the trap `Parts.register` guards against for exactly
    # the same reason.
    it "refuses to re-register an id that is already taken" do
      expect { described_class.register(:stokers_shovel, slot: :gear, label: "Impostor") }
        .to raise_error(ReactorSim::Error, /already registered/)
    end

    it "raises on an unknown id rather than returning nil" do
      expect { described_class.fetch(:nope) }
        .to raise_error(ReactorSim::Error, /unknown equipment/)
    end

    # **Stats are OFFSETS, so an item says nothing about what it does not touch.** An archetype
    # must declare all five; an item almost always speaks to one or two, and a missing key must
    # mean "unchanged" rather than "zero" — the second would strip a worker of every stat their
    # gloves had no opinion about.
    it "carries only the stats an item actually speaks to" do
      gloves = described_class.fetch(:fettlers_gloves)

      expect(gloves.stats).to eq(dexterity: -0.1)
      expect(gloves.tags).to include(:heat_resistance)
    end

    # A tag that cuts both ways is the point of the vocabulary, and the sketch's worked example.
    # A candle is what lets you see down a drift and what ignites the gas in one.
    it "lets one item carry a benefit and a hazard together" do
      tools = described_class.fetch(:crude_miners_tools)

      expect(tools.tags).to include(darkvision: 0.1, open_flame: true)
    end

    # Tags add across layers and are signed, so "less clumsy" needs no second vocabulary for
    # penalties — it is the same key with a negative value.
    it "expresses a penalty reduced as a negative on the same tag" do
      expect(described_class.fetch(:lucky_amulet).tags[:clumsy]).to be < 0
    end
  end

  describe ReactorSim::Training do
    it "raises on an unknown course rather than returning nil" do
      expect { described_class.fetch(:nope) }
        .to raise_error(ReactorSim::Error, /unknown training/)
    end

    it "refuses to re-register an id that is already taken" do
      expect { described_class.register(:hot_work_ticket, label: "Impostor") }
        .to raise_error(ReactorSim::Error, /already registered/)
    end

    # Training and equipment contribute the same two things, which is what lets all four layers
    # fold through one piece of arithmetic. The difference between them is permanence, and that
    # difference lives in the delivery tier rather than here.
    it "contributes the same shape an item does" do
      course = described_class.fetch(:hot_work_ticket)

      expect(course.stats).to include(:toughness)
      expect(course.tags).to include(heat_resistance: 0.2, licensed: true)
    end
  end
end
