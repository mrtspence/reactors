# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **What the cage is doing and what it is waiting on**, as both landings can see it: one plain-words
# gauge, the first condition that holds winning — what has broken, then why it is not moving, then
# what it is waiting on. One tick from a constructed state each, because the signal is written as
# the tick ends. See `design_sketches/winding-signals.md`.
RSpec.describe "winding signals" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  let(:signals) { ReactorSim::Operations::Mine::Winding::SIGNALS }

  def pit = build_pit(id: "s", seed: 5, loadout: { winder: :cage_gear }, crew: PitRig::WOUND_CREW)

  def at(place, station) = { place: place, posting: station, station: station, via: nil }

  # Out of the way of the shaft: posted at the face, so nobody is waiting for the cage.
  def away = %i[crew_1 crew_2 crew_3 crew_4].to_h { |seat| [ seat, at(:district, nil) ] }

  def turning
    shaft = pit.nodes.fetch(:line_shaft)
    { line_shaft: { angular_momentum: shaft.moment_of_inertia * shaft.rated_omega } }
  end

  # The cage standing at bank, an engineman at the winder, the shaft turning — then whatever the
  # example changes. `to:` is where he has been told to wind, percent of the shaft from bank.
  def board(nodes: {}, minions: {}, controls: {}, to: 0.0, engineman: true)
    crew = away.merge(engineman ? { crew_5: at(:bank, :man_winding) } : { crew_5: at(:district, nil) })
    op = seed(pit, nodes: turning.merge(nodes), minions: crew.merge(minions), controls: controls)
    levers!(op, man_winding: to)
    run!(op, 1)
    op.project(viewer: :player).to_h.dig(:gauges, :winding_signals)
  end

  def cage(position_m, speed_m_s = 0.0)
    drum = pit.nodes.fetch(:cage_drive)
    { cage_drive: { position_m: position_m, angular_momentum: speed_m_s / drum.radius_m * drum.moment_of_inertia } }
  end

  def getting_in(place) = { crew_1: { place: place, via: :cage_drive, boarding_s: 2.0, posting: nil, station: nil } }

  describe "standing at a landing" do
    it "says where it stands with nothing called" do
      expect(board).to eq(signals.fetch(:at_bank))
      expect(board(nodes: cage(90.0), to: 100.0)).to eq(signals.fetch(:at_bottom))
    end

    it "reads with nobody at either landing" do
      expect(board(engineman: false)).to eq(signals.fetch(:unmanned))
    end

    it "says men are waiting at the other landing when he has not been sent for them" do
      waiting = { crew_2: { place: :pit_bottom, posting: :greasing, station: nil, via: nil } }

      expect(board(minions: waiting)).to eq(signals.fetch(:called_bottom))
    end
  end

  describe "the bell" do
    it "holds for the marshal while somebody is getting in" do
      onsetter = { crew_3: at(:pit_bottom, :onsetting) }

      expect(board(nodes: cage(90.0), to: 100.0, minions: getting_in(:pit_bottom).merge(onsetter)))
        .to eq(signals.fetch(:bell_bottom))
    end

    it "says only that men are getting in where there is no marshal to ring" do
      expect(board(minions: getting_in(:bank))).to eq(signals.fetch(:boarding_bank))
    end

    # A slip begins in phase 0 from a die thrown that tick, so it cannot be seeded; what the board
    # is handed is whether the marshal is slipping, and that is asserted at zero ticks.
    it "says a slipping marshal has rung with a man still getting in" do
      expect(told(landing: :bank, marshals: [ :bank ], slipping: [ :bank ], boarding: [ :bank ]))
        .to be(:false_ready)
      expect(told(landing: :bank, marshals: [ :bank ], boarding: [ :bank ])).to be(:bell_bank)
    end
  end

  # The engineman's word on a cage standing at bank, from the board's own inputs.
  def told(**inputs)
    op = pit
    winding = op.control_points.fetch(:man_winding).governor
    winding.signal(drum: op.nodes.fetch(:cage_drive), drum_state: op.state.dig(:nodes, :cage_drive),
                   states: op.state.fetch(:nodes),
                   **{ landing: :bank, staffed: true, fumbling: false, running: true, shuttling: false,
                       marshals: [], slipping: [], boarding: [], waiting: [] }.merge(inputs))
  end

  describe "coal" do
    it "says a shuttle is stood at the bottom with nobody to load it" do
      coal = { pit_bottom: { parcels: parcels_at(293.15, coal: 500.0, air: 1_100.0) } }
      op_nodes = cage(90.0).merge(coal)

      expect(board(nodes: op_nodes, to: 100.0, controls: { coal_winding: { target: 100.0, actual: 100.0 } }))
        .to eq(signals.fetch(:no_onsetter))
    end
  end

  describe "why it is not moving" do
    it "says when the winding engine is stopped" do
      expect(board(nodes: { line_shaft: { angular_momentum: 0.0 } })).to eq(signals.fetch(:stopped))
    end

    it "says when the engineman is fumbling the levers" do
      expect(told(fumbling: true)).to be(:fumbling)
    end

    it "says which way it is winding, and where it has stopped short" do
      expect(board(nodes: cage(45.0, 3.0), to: 100.0)).to eq(signals.fetch(:lowering))
      expect(board(nodes: cage(45.0, -3.0), to: 0.0)).to eq(signals.fetch(:raising))
      expect(board(nodes: cage(45.0), to: 50.0)).to eq(signals.fetch(:mid_shaft))
    end
  end

  describe "what has gone wrong, first of all" do
    it "names a tub lodged in the shaft over the cage winding through it" do
      expect(board(nodes: cage(45.0, 3.0).merge(shaft: { jam_m: 60.0, hold: 1.0e6 }), to: 100.0))
        .to eq(signals.fetch(:lodged))
    end

    it "names a cage hung on slack rope" do
      expect(board(nodes: { cage_drive: { position_m: 40.0, slack_m: 2.0 }, shaft: { jam_m: 38.0 } }, to: 44.0))
        .to eq(signals.fetch(:hung))
    end

    it "names a parted rope over everything, an empty winder included" do
      expect(board(nodes: { winding_rope: { failure: :parted_held } }, engineman: false))
        .to eq(signals.fetch(:rope_held))
    end

    it "names a missing engineman over men getting in" do
      expect(board(minions: getting_in(:bank), engineman: false)).to eq(signals.fetch(:unmanned))
    end
  end
end
