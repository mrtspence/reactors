# frozen_string_literal: true

require "rails_helper"

# The outfitting screen, and the chain behind the button.
#
# What matters here is not the HTML. It is the **order** — validate, store, then produce a reset
# carrying the loadout — and the two things that order exists to prevent: a build the validator
# refused reaching the database, and a runner reading a table at the moment it happens to be
# half-written. See `docs/design_sketches/modular_components.md` §8.
RSpec.describe "Outfitting", type: :request do
  let(:producer) { instance_spy(CommandProducer) }

  # A spec that needs a broker running is a spec nobody runs.
  before { allow(CommandProducer).to receive(:instance).and_return(producer) }

  # **Every blueprint owned unless an example says otherwise.** Ownership is now a precondition
  # for fitting anything at all, so without this every example here would fail for a reason it is
  # not about. The enforcement examples revoke what they need.
  before { DevPlayer.grant_everything! }
  # An operation has to exist to be owned: every controller finds the row and asks whether this
  # player may touch it, so without this the filter answers 404 before the action runs.
  before { DevMatch.provision! }

  def path = edit_loadout_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
  def fit_path = loadout_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)

  # Every slot named explicitly, which is what the form submits — a partial loadout would
  # re-default and silently refit the parts a player just removed.
  def full_loadout(**overrides)
    DevMatch.outfitting.loadout.to_h { |slot, part| [ slot.to_s, part.to_s ] }
            .merge(overrides.transform_keys(&:to_s).transform_values(&:to_s))
  end

  describe "GET" do
    it "renders the machine's slots without touching simulation state" do
      get path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Outfitting")
      expect(response.body).to include("Fusible Plug")
      expect(response.body).to include("Fit and test drive")
    end

    # The hole where a part would go is the point of the screen.
    it "shows an empty optional slot as empty rather than hiding it" do
      Loadout.fit(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY,
                  chassis: :high_pressure,
                  parts: DevMatch.outfitting(loadout: { fusible_plug: nil }).loadout)

      get path

      expect(response.body).to include("Nothing fitted here")
      expect(response.body).to include("nothing between you and the plate letting go")
    end

    it "404s anything that is not the dev match" do
      get edit_loadout_path(match_id: "nope", operation_id: DevMatch::PRIMARY)

      expect(response).to have_http_status(:not_found)
    end

    # **The preview renders a DRAFT.** Changing a dropdown posts the form back into a Turbo
    # frame, so the stats and the verdict follow the selection before anything is committed.
    # Reported from play: the stats panels never moved when a part was swapped, because until
    # this the page only ever rendered what was already fitted.
    #
    # **A draft is its own resource**, so this is `create` rather than a `preview` action — see
    # `app/CLAUDE.md`. POST rather than GET so a twenty-slot loadout rides in the body instead of
    # the query string, and from there into history and logs.
    describe "previewing a draft" do
      def preview_path
        loadout_draft_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
      end

      it "renders into the same frame the form lives in" do
        post preview_path, params: { loadout: full_loadout }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(%(id="outfitting"))
      end

      it "shows the selected part rather than the stored one, without storing it" do
        post preview_path, params: { loadout: full_loadout(boiler: "beam_boiler") }

        expect(response.body).to include("Wide, thin, and low-pressure")
        expect(response.body).not_to include("A long riveted barrel")
        expect(Loadout.count).to eq(0)
      end

      # The verdict is the reason this is a round trip instead of a few lines of JavaScript:
      # only the simulation can say what a build will do, so a client-side preview would have to
      # show live stats beside stale warnings.
      it "updates the verdict along with the stats" do
        get path

        expect(response.body).not_to include("nothing between you and the plate letting go")

        post preview_path, params: { loadout: full_loadout(fusible_plug: "") }

        expect(response.body).to include("nothing between you and the plate letting go")
      end

      it "shows why a draft will not run, without refusing to render it" do
        post preview_path, params: { loadout: full_loadout(chimney: "") }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("This will not run")
      end

      # An empty hash means "every slot explicitly empty" and no param at all means "show what
      # is fitted". Conflating them would make the first GET render a stripped machine.
      it "treats no loadout param as the stored machine, not as an empty one" do
        get path

        expect(response.body).to include("A long riveted barrel")
        expect(response.body).not_to include("This will not run")
      end
    end
  end

  describe "PATCH — fitting" do
    it "stores the loadout and resets the match" do
      patch fit_path, params: { loadout: full_loadout(safety_valve: "") }

      expect(response).to redirect_to(
        console_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
      )

      stored = Loadout.find_by(match_id: DevMatch::ID)
      expect(stored.parts.fetch("safety_valve")).to be_nil
      expect(stored.parts.fetch("boiler")).to eq("locomotive_boiler")
    end

    # **The loadout rides inside the command, not merely referenced by it.** A runner that read
    # the table instead would be reading it at whatever moment the row happened to arrive, and a
    # reset racing a save would rebuild the previous machine with nothing to show for it.
    it "carries the loadout in the reset command rather than only in the database" do
      patch fit_path, params: { loadout: full_loadout(safety_valve: "") }

      expect(producer).to have_received(:produce).with(
        match_id: DevMatch::ID,
        command: hash_including(
          "type" => "reset_match",
          # Keyed by operation now: a reset rebuilds every machine in the match, each with its
          # own frame, fittings and crew.
          "operations" => hash_including(
            DevMatch::PRIMARY.to_s => hash_including(
              "chassis" => "high_pressure",
              "loadout" => hash_including("safety_valve" => nil)
            )
          )
        )
      )
    end

    # An unchecked slot must arrive as an explicit nil. If the form omitted it, `Assembly` would
    # fall back to `slot.default` and refit the part the player just took off.
    it "keeps a removed part removed instead of re-defaulting it" do
      patch fit_path, params: { loadout: full_loadout(fusible_plug: "", drain_cocks: "") }

      stored = Loadout.find_by(match_id: DevMatch::ID)
      expect(stored.parts).to have_key("fusible_plug")
      expect(stored.parts.fetch("fusible_plug")).to be_nil
      expect(stored.parts.fetch("drain_cocks")).to be_nil
    end

    describe "a build that cannot run" do
      # The chimney is required: with no way for the flue gas to leave, the fire cannot breathe.
      let(:broken) { full_loadout.merge("chimney" => "") }

      it "refuses it and says why, without storing anything" do
        patch fit_path, params: { loadout: broken }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("This will not run")
        expect(Loadout.count).to eq(0)
      end

      # The important half: a refused build must not reach the runner either, or a cold boot
      # would inherit a machine the validator already rejected.
      it "does not reset the match" do
        patch fit_path, params: { loadout: broken }

        expect(producer).not_to have_received(:produce)
      end
    end

    it "refuses a part fitted in the wrong slot" do
      patch fit_path, params: { loadout: full_loadout.merge("boiler" => "light_flywheel") }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Loadout.count).to eq(0)
    end
  end

  # **The frame is a choice now, not an environment variable.**
  #
  # It decides what slots exist — the atmospheric frame has a condenser and the high-pressure one
  # does not — so changing it changes the page below it, and the parameter permitting has to
  # follow the *submitted* chassis rather than the stored one.
  describe "choosing a chassis" do
    def draft_path
      loadout_draft_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
    end

    it "offers every frame the player owns" do
      get path

      expect(response.body).to include(%(value="high_pressure"))
      expect(response.body).to include(%(value="atmospheric"))
    end

    # The slot list is a function of the frame, and this is the example that proves the permit
    # call follows the submission: against the stored chassis, `condenser` is not a slot at all
    # and would be dropped before `Outfitting` ever saw it.
    it "grows the condenser slot when the frame becomes atmospheric" do
      get path
      expect(response.body).not_to include("Jet Condenser")

      post draft_path, params: { chassis: "atmospheric", loadout: full_loadout }

      expect(response.body).to include("Jet Condenser")
    end

    # Cross-frame fitting is legal and is meant to be — a locomotive boiler on a beam engine is a
    # decision, not an error. The parts a player has already chosen must survive the switch.
    it "carries the chosen parts across the switch" do
      post draft_path, params: { chassis: "atmospheric",
                                 loadout: full_loadout(boiler: "locomotive_boiler") }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("A long riveted barrel")
    end

    it "stores the new frame and carries it in the reset command" do
      patch fit_path, params: { chassis: "atmospheric", loadout: full_loadout }

      expect(Loadout.find_by(match_id: DevMatch::ID).chassis).to eq("atmospheric")
      expect(producer).to have_received(:produce).with(
        match_id: DevMatch::ID,
        command: hash_including(
          "operations" => hash_including(
            DevMatch::PRIMARY.to_s => hash_including("chassis" => "atmospheric")
          )
        )
      )
    end

    # A blank select is "nothing submitted", not "an unknown machine". `assembly_for` raises on a
    # frame it does not know, which is right for a hand-typed id and wrong for an empty field.
    it "falls back to the stored frame rather than raising on a blank one" do
      post draft_path, params: { chassis: "", loadout: full_loadout }

      expect(response).to have_http_status(:ok)
    end

    describe "a frame the player has not unlocked" do
      before do
        DevPlayer.revoke(:chassis,
                         Blueprint.chassis_id(DevMatch.kind_of(DevMatch::PRIMARY), :atmospheric))
      end

      it "is refused, on its own line rather than as a part's fault" do
        patch fit_path, params: { chassis: "atmospheric", loadout: full_loadout }

        expect(response).to have_http_status(:unprocessable_content)
        expect(response.body).to include("You have not unlocked the Atmospheric frame")
        expect(Loadout.count).to eq(0)
        expect(producer).not_to have_received(:produce)
      end

      it "is not offered while a frame the player does own is selected" do
        get path

        expect(response.body).not_to include(%(value="atmospheric"))
        expect(response.body).to include(%(value="high_pressure"))
      end
    end
  end

  # **The second validator: is this yours?**
  #
  # A locked part is structurally perfect — it assembles, it runs, the machine is fine — so
  # nothing `Assembly` knows can refuse it, and nothing `Assembly` knows ever should. Ownership is
  # a fact about a *player*, it lives on this side of the boundary, and it is checked before the
  # build is. See `docs/design_sketches/blueprints.md` §6.
  describe "a part the player has not unlocked" do
    before { DevPlayer.revoke(:part, :ramsbottom_safety_valve) }

    # The half a filtered dropdown cannot do. The form is a plain POST and anyone can submit any
    # id, which is the whole reason the screen's filter is a courtesy rather than a gate.
    it "is refused when posted directly, and nothing is stored or sent" do
      patch fit_path, params: { loadout: full_loadout }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include("Not in your workshop")
      expect(response.body).to include("You have not unlocked the Ramsbottom Valve")
      expect(Loadout.count).to eq(0)
      expect(producer).not_to have_received(:produce)
    end

    # Tested on a build that is *not* wearing it, because a fitted locked part is deliberately
    # still shown — see the example below. The two rules only look contradictory: what is fitted
    # is a fact about the machine, what is offered is a fact about the workshop.
    it "disappears from the dropdown it would have been offered in" do
      post loadout_draft_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY),
           params: { loadout: full_loadout(safety_valve: "low_pressure_safety_valve") }

      expect(response.body).not_to include(%(value="ramsbottom_safety_valve"))
      expect(response.body).to include(%(value="low_pressure_safety_valve"))
    end

    # **A locked part that is already fitted still shows.** The stored machine holds one, and a
    # screen that hid it would report an error about a part the player cannot see, let alone
    # change.
    it "still appears, flagged, when the stored machine is already wearing it" do
      get path

      expect(response.body).to include("Ramsbottom Valve (locked)")
      expect(response.body).to include("Not in your workshop")
    end

    # Ownership is checked first, so the player is told what is actually wrong rather than being
    # sent looking for a wiring fault that is not there.
    it "reports ownership rather than a structural complaint" do
      patch fit_path, params: { loadout: full_loadout }

      expect(response.body).to include("Not in your workshop")
      expect(response.body).not_to include("This will not run")
    end

    # Removing the part you do not own is a legitimate fix, and the safety valve is optional.
    it "lets the player fit the machine once the locked part is taken off" do
      patch fit_path, params: { loadout: full_loadout(safety_valve: "") }

      expect(response).to redirect_to(
        console_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
      )
      expect(Loadout.find_by(match_id: DevMatch::ID).parts.fetch("safety_valve")).to be_nil
    end

    # `Assembly` must stay ignorant of all of this — it is what keeps it specced without a player.
    it "leaves the simulation's own verdict untouched" do
      expect(DevMatch.outfitting.verdict).to be_ok
    end
  end

  # **The loadout parameter is attacker-shaped, and `permit!` was letting every shape through.**
  #
  # Brakeman flagged the mass assignment; the worse half was that `permit!` also admits
  # non-scalars. An Array reaches `Assembly#normalise_part_id`, where `Array#to_sym` raises —
  # and on the *preview* action, which has no rescue, that is a 500 rather than the "no such
  # part" the validator exists to report. `permit` with the slot ids fixes both.
  #
  # None of these had a spec, which is why the shape survived. They assert **no 500**, not a
  # particular verdict: what matters is that malformed input reaches the validator as data.
  describe "a malformed loadout parameter" do
    def preview_path
      loadout_draft_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
    end

    # `permit` drops a non-scalar outright, so the key never reaches `Outfitting` and the slot
    # takes its default — the same path a slot only the new chassis has follows. That is the
    # honest outcome and it is visible: the dropdown renders whatever was fitted. What matters is
    # that it is a rendered page and not an exception.
    it "treats a nested array as no part rather than raising" do
      post preview_path, params: { loadout: full_loadout.merge("boiler" => %w[a b]) }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("A long riveted barrel")
    end

    it "treats a nested hash as no part rather than raising" do
      post preview_path, params: { loadout: full_loadout.merge("boiler" => { "evil" => "1" }) }

      expect(response).to have_http_status(:ok)
    end

    # `?loadout=x` makes the parameter a String, which does not respond to `permit`.
    it "treats a scalar loadout as nothing submitted rather than raising" do
      post preview_path, params: { loadout: "not-a-hash" }

      expect(response).to have_http_status(:ok)
    end

    # A JSON body can carry a number, and `Integer#to_sym` does not exist.
    it "reports a non-string part id by name instead of raising on it" do
      post preview_path, params: { loadout: full_loadout.merge("boiler" => 1) }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("no such part")
    end

    # A key that is not a slot is dropped by `permit` before `Assembly` ever sees it, so the
    # "no slot :x on this chassis" branch is unreachable from the web. That is the right layering
    # — the validator still guards the library — but it should not be mistaken for dead code.
    it "drops a key that is not a slot instead of storing it" do
      patch fit_path, params: { loadout: full_loadout.merge("mainframe" => "locomotive_boiler") }

      expect(response).to redirect_to(
        console_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
      )
      expect(Loadout.find_by(match_id: DevMatch::ID).parts).not_to have_key("mainframe")
    end
  end

  # The panel is a pure function of the loadout, which is what keeps rebuilding a throwaway
  # match in the web process sound now that a player chooses the configuration.
  describe "the panel follows the loadout" do
    it "drops the safety valve's gauges when the valve is not fitted" do
      before_count = DevMatch.panel[:instruments].length

      patch fit_path, params: { loadout: full_loadout(safety_valve: "") }

      after_count = DevMatch.panel[:instruments].length
      expect(after_count).to eq(before_count - 2)
      expect(DevMatch.panel[:instruments].map { |i| i[:id] }).not_to include(:safety_valve)
    end
  end
end
