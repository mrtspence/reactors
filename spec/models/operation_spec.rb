# frozen_string_literal: true

require "rails_helper"

# **Who owns a machine, and what that lets them do.**
#
# Before this row existed, every controller answered "may you touch this" by comparing a path
# segment against `DevMatch::ID` — four copies of a rule with no owner, and the reason a second
# operation could not exist.
#
# See docs/design_sketches/operator_identity.md §2.
RSpec.describe Operation do
  def provision(owner: "alice", operation_id: "engine", match_id: "m")
    described_class.provision(match_id: match_id, operation_id: operation_id,
                              kind: :steam_engine, owner_id: owner)
  end

  describe "provisioning" do
    it "is idempotent, so a seed or a boot may run it as often as it likes" do
      provision
      expect { provision }.not_to change(described_class, :count)
    end

    # **The rule that makes ownership worth having.** Fitting parts, posting a crew and
    # resetting a match all rebuild a machine, and none of them may transfer it — which is why
    # ownership is a row of its own rather than a column on `loadouts`.
    it "never reassigns an existing machine" do
      provision(owner: "alice")

      expect(provision(owner: "mallory").owner_id).to eq("alice")
    end

    it "refuses a machine nobody owns, because a gate with no subject fails open" do
      expect { described_class.create!(match_id: "m", operation_id: "e", kind: "steam_engine") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    it "refuses two machines with one id in one match" do
      provision
      expect { described_class.create!(match_id: "m", operation_id: "engine",
                                       kind: "steam_engine", owner_id: "bob") }
        .to raise_error(ActiveRecord::RecordInvalid)
    end

    # The same id in a different match is a different machine — which is what `:match_id` has
    # been in every route since the beginning.
    it "allows the same id in a different match" do
      provision(match_id: "m")
      expect { provision(match_id: "other") }.to change(described_class, :count).by(1)
    end
  end

  describe "locating" do
    it "finds nothing rather than raising, so absent and forbidden look alike from outside" do
      expect(described_class.locate("nope", "engine")).to be_nil
      expect(described_class.locate(nil, nil)).to be_nil
    end
  end

  describe "permissions" do
    it "lets the owner operate and watch" do
      operation = provision(owner: "alice")

      expect(operation.operable_by?("alice")).to be(true)
      expect(operation.viewable_by?("alice")).to be(true)
    end

    it "refuses everybody else" do
      operation = provision(owner: "alice")

      expect(operation.operable_by?("bob")).to be(false)
      expect(operation.viewable_by?("bob")).to be(false)
    end
  end

  # **The escape hatch widens who may operate, and nothing else.**
  describe "the development bypass" do
    before { allow(Operator).to receive(:bypass?).and_return(true) }

    it "lets a developer drive a machine they do not own" do
      expect(provision(owner: "alice").operable_by?("bob")).to be(true)
    end

    # It must not fabricate an owner: turning the hatch off has to restore the real rule with no
    # data to repair, and a bypass that wrote `owner_id` would have rewritten what it bypassed.
    it "leaves the owner exactly as it found them" do
      operation = provision(owner: "alice")
      operation.operable_by?("bob")

      expect(operation.reload.owner_id).to eq("alice")
    end

    it "stops mattering the moment it is switched off" do
      operation = provision(owner: "alice")
      allow(Operator).to receive(:bypass?).and_return(false)

      expect(operation.operable_by?("bob")).to be(false)
    end
  end
end
