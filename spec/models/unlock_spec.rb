# frozen_string_literal: true

require "rails_helper"

# What a player owns.
#
# The two things worth guarding are that a row **cannot be created naming something that does not
# exist**, and that a row a *rename* stranded can still be found afterwards. The second is not
# hypothetical: stage 3 of the modularisation renamed `:stock_boiler` to `:locomotive_boiler`,
# and nothing stops that happening again. A stale row is not a crash — it is a player quietly
# missing a part they earned, which is exactly the kind of failure that survives for months.
#
# See `docs/design_sketches/blueprints.md` §5.
RSpec.describe Unlock do
  def grant(kind, id, owner: DevPlayer::ID)
    described_class.grant(owner_id: owner, kind: kind, blueprint_id: id)
  end

  describe "validation" do
    it "accepts a blueprint the catalogue has" do
      expect(grant(:part, :locomotive_boiler)).to be_persisted
    end

    it "refuses an id the catalogue does not have" do
      row = described_class.new(owner_id: DevPlayer::ID, kind: "part",
                                blueprint_id: "stock_boiler")

      expect(row).not_to be_valid
      expect(row.errors.full_messages.join).to match(/not a known part blueprint/)
    end

    # The pair is the identity, so a real part id under the wrong kind is just as wrong as a
    # typo — and much easier to write by accident.
    it "refuses a real id filed under the wrong kind" do
      row = described_class.new(owner_id: DevPlayer::ID, kind: "chassis",
                                blueprint_id: "locomotive_boiler")

      expect(row).not_to be_valid
    end

    # One mistake, one message. "gubbins is not a kind" and "not a known gubbins blueprint" are
    # the same complaint twice, and the second is the less useful half.
    it "refuses a kind that is not a blueprint kind, and says so once" do
      row = described_class.new(owner_id: DevPlayer::ID, kind: "gubbins",
                                blueprint_id: "steam_engine")

      expect(row).not_to be_valid
      expect(row.errors.full_messages).to contain_exactly("Kind is not a blueprint kind")
    end
  end

  # Owning a thing twice is not a thing. Granting has to be safe to repeat, because the dev
  # seed runs it over the whole catalogue on every boot.
  describe "granting" do
    it "is idempotent" do
      first = grant(:part, :wide_damper)
      second = grant(:part, :wide_damper)

      expect(second.id).to eq(first.id)
      expect(described_class.count).to eq(1)
    end

    it "keeps two owners apart" do
      grant(:part, :wide_damper)
      grant(:part, :wide_damper, owner: "someone_else")

      expect(described_class.owned_by(DevPlayer::ID).count).to eq(1)
      expect(described_class.count).to eq(2)
    end

    it "revokes what it granted" do
      grant(:part, :wide_damper)
      described_class.revoke(owner_id: DevPlayer::ID, kind: :part, blueprint_id: :wide_damper)

      expect(described_class.owned_by(DevPlayer::ID)).to be_empty
    end
  end

  # **The rename guard.** `insert_all` skips validation, which is precisely what a rename does
  # to rows that are already in the table — nothing revalidates them.
  describe "after a blueprint is renamed out from under a row" do
    before do
      grant(:part, :locomotive_boiler)
      described_class.insert_all([ { owner_id: DevPlayer::ID, kind: "part",
                                     blueprint_id: "stock_boiler",
                                     created_at: Time.current, updated_at: Time.current } ])
    end

    it "finds the stranded row and leaves the good one alone" do
      expect(described_class.stale.map(&:blueprint_id)).to contain_exactly("stock_boiler")
    end

    it "raises rather than reading nil when the stranded row is resolved" do
      stranded = described_class.find_by(blueprint_id: "stock_boiler")

      expect { stranded.blueprint }.to raise_error(Blueprint::Unknown)
    end
  end

  describe DevPlayer do
    it "owns the whole catalogue once granted, and can be granted twice" do
      described_class.grant_everything!
      described_class.grant_everything!

      expect(described_class.unlocks.count).to eq(Blueprint.known.length)
      expect(Unlock.stale).to be_empty
    end

    # **Earning goes through the gates; granting is an override.** They are different words on
    # purpose — conflating them would leave `obtainable_by?` with no live call site, and a check
    # that only ever runs in a spec rots.
    describe "earning versus granting" do
      it "earns a blueprint whose prerequisite is met" do
        expect(described_class.earn(:part, :ramsbottom_safety_valve)).to be_persisted
        expect(described_class).to be_unlocked(:part, :ramsbottom_safety_valve)
      end

      it "refuses to earn one whose prerequisite is not, and stores nothing" do
        allow(Achievement).to receive(:earned?).and_return(false)

        expect(described_class.earn(:part, :ramsbottom_safety_valve)).to be_nil
        expect(described_class).not_to be_unlocked(:part, :ramsbottom_safety_valve)
      end

      # An ungated part is unaffected by an unmet achievement — the gate is per blueprint, not a
      # global switch.
      it "still earns an ungated part while achievements are unmet" do
        allow(Achievement).to receive(:earned?).and_return(false)

        expect(described_class.earn(:part, :plain_chimney)).to be_persisted
      end

      # The dev baseline, and it bypasses deliberately: stage 5a's acceptance is that the dev
      # player owns everything, and nothing awards an achievement yet.
      it "grants everything regardless of gates" do
        allow(Achievement).to receive(:earned?).and_return(false)
        described_class.grant_everything!

        expect(described_class).to be_unlocked(:part, :ramsbottom_safety_valve)
      end
    end

    it "answers ownership by the pair, not by the id alone" do
      described_class.grant(:part, :locomotive_boiler)

      expect(described_class).to be_unlocked(:part, :locomotive_boiler)
      expect(described_class).not_to be_unlocked(:chassis, :locomotive_boiler)
      expect(described_class).not_to be_unlocked(:part, :beam_boiler)
    end

    # The shape the outfitting screen wants: one query, then twenty-odd membership tests.
    it "hands back the owned ids of one kind, and only that kind" do
      described_class.grant(:part, :locomotive_boiler)
      described_class.grant(:part, :beam_boiler)
      described_class.grant(:chassis, Blueprint.chassis_id(:steam_engine, :high_pressure))

      expect(described_class.owned_ids(:part))
        .to contain_exactly("locomotive_boiler", "beam_boiler")
      expect(described_class.owned_ids(:chassis))
        .to contain_exactly("steam_engine/high_pressure")
    end
  end
end
