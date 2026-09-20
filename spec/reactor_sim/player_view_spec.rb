# frozen_string_literal: true

require "reactor_sim"

# The wire protocol, not the instrument chain — that is diagnostic_spec's job. What matters
# here is that a client which MERGES successive deltas ends up with the same state as one
# that received a full view, because that equivalence is the whole basis of the delta
# protocol (docs/reference/diagnostics.md).
RSpec.describe ReactorSim::PlayerView do
  def view(tick:, gauges: {}, flags: {}, controls: {}, incidents: [], crew: {})
    described_class.new(tick: tick, operation_id: :eng, viewer: :player,
                        gauges: gauges, flags: flags, controls: controls,
                        incidents: incidents, crew: crew)
  end

  # What a client actually does with a stream of deltas.
  def merge(full, *deltas)
    deltas.each_with_object(full.to_h.dup) do |delta, acc|
      acc[:gauges] = acc[:gauges].merge(delta[:gauges])
      acc[:flags] = acc[:flags].merge(delta[:flags])
      acc[:controls] = acc[:controls].merge(delta[:controls])
    end
  end

  describe "#delta_from" do
    it "returns the whole view when there is nothing to diff against" do
      v = view(tick: 1, gauges: { boiler: 300.0 })

      expect(v.delta_from(nil)).to eq(v.to_h)
    end

    it "omits gauges that did not move" do
      first  = view(tick: 1, gauges: { boiler: 300.0, wheel: 0.0 })
      second = view(tick: 2, gauges: { boiler: 301.0, wheel: 0.0 })

      expect(second.delta_from(first)[:gauges]).to eq(boiler: 301.0)
    end

    # The bug this file was written for. `flags` is sparse, so an instrument that falls
    # silent simply has no key — and rejecting unchanged entries iterates only the current
    # flags, which no longer mention it. The clear was invisible and the client showed the
    # warning forever.
    it "emits an explicit empty list for an instrument whose flags cleared" do
      pegged   = view(tick: 1, flags: { boiler: [ :pegged_high ] })
      recovered = view(tick: 2, flags: {})

      expect(recovered.delta_from(pegged)[:flags]).to eq(boiler: [])
    end

    it "lets a merging client clear a flag it was previously shown" do
      pegged    = view(tick: 1, flags: { boiler: [ :pegged_high ] })
      recovered = view(tick: 2, flags: {})

      merged = merge(pegged, recovered.delta_from(pegged))

      expect(merged[:flags][:boiler]).to be_empty
    end

    # Every lagged gauge raises :warming_up for its first few ticks, so this is not an edge
    # case — it is what happens on tick 2 of every match.
    it "clears warming_up without disturbing an instrument that is still flagged" do
      first  = view(tick: 1, flags: { boiler: [ :warming_up ], wheel: [ :warming_up ] })
      second = view(tick: 2, flags: { wheel: [ :warming_up ] })

      delta = second.delta_from(first)

      expect(delta[:flags]).to eq(boiler: [])
    end

    it "carries this tick's incidents in full, since they are not cumulative" do
      burst = { type: :part_failed, node: :flywheel, mode: :burst }
      first  = view(tick: 1)
      second = view(tick: 2, incidents: [ burst ])

      expect(second.delta_from(first)[:incidents]).to eq([ burst ])
    end
  end

  # **The seam that was dead and claimed not to be.** `CrewComponent`'s own comment said the
  # posting "arrives on the projection"; it did not, so the station dropdown always rendered at
  # its first option however the crew were actually posted, and a reassignment, a reset or a
  # restore was never reflected back.
  describe "the crew" do
    it "reports where each of them is standing" do
      posted = view(tick: 1, crew: { crew_1: { station: :stoking, injury: nil } })

      expect(posted.to_h[:crew]).to eq(crew_1: { station: :stoking, injury: nil })
    end

    it "carries only the ones whose posting or condition moved" do
      first = view(tick: 1, crew: { crew_1: { station: :stoking, injury: nil },
                                    crew_2: { station: :feed, injury: nil } })
      second = view(tick: 2, crew: { crew_1: { station: :damper_open, injury: nil },
                                     crew_2: { station: :feed, injury: nil } })

      expect(second.delta_from(first)[:crew]).to eq(crew_1: { station: :damper_open,
                                                              injury: nil })
    end

    # A minion who has been carried out has `station: nil`, which is a VALUE rather than an
    # absence — so unlike `flags` there is no vanished-entry case and a plain reject is honest.
    it "reports somebody being stood down rather than omitting them" do
      before = view(tick: 1, crew: { crew_1: { station: :stoking, injury: nil } })
      after = view(tick: 2, crew: { crew_1: { station: nil, injury: :severe } })

      expect(after.delta_from(before)[:crew])
        .to eq(crew_1: { station: nil, injury: :severe })
    end

    it "counts a crew change as a reason to broadcast" do
      before = view(tick: 1, crew: { crew_1: { station: :stoking, injury: nil } })
      after = view(tick: 2, crew: { crew_1: { station: :stoking, injury: :minor } })

      expect(after).not_to be_unchanged_from(before)
    end
  end

  describe "#unchanged_from?" do
    it "is false against no previous view, so the first view is always sent" do
      expect(view(tick: 1).unchanged_from?(nil)).to be(false)
    end

    it "is true when nothing moved" do
      first  = view(tick: 1, gauges: { boiler: 300.0 }, controls: { feed: { target: 0.0, actual: 0.0 } })
      second = view(tick: 2, gauges: { boiler: 300.0 }, controls: { feed: { target: 0.0, actual: 0.0 } })

      expect(second.unchanged_from?(first)).to be(true)
    end

    # Guards the broadcast-skipping optimisation: a cleared flag is a real change, and
    # treating the tick as unchanged would strand the warning on the client's panel.
    it "is false when a flag cleared, even though nothing else moved" do
      first  = view(tick: 1, gauges: { boiler: 300.0 }, flags: { boiler: [ :pegged_high ] })
      second = view(tick: 2, gauges: { boiler: 300.0 }, flags: {})

      expect(second.unchanged_from?(first)).to be(false)
    end
  end
end
