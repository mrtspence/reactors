# frozen_string_literal: true

require "reactor_sim"
require "support/loop_rig"

# Instruments: Source -> Filters -> Display.
#
# The v0 base class carried lag, noise, history and clamping for every diagnostic, could
# only read one scalar off one mechanism, and computed a `pegged?` nobody could reach.
# These specs pin down what replaced it, and each of the three trace findings it closes.
RSpec.describe ReactorSim::Diagnostic do
  let(:content) { ReactorSim::Content.default }
  let(:rng) { ReactorSim::Rng.new(12_345) }
  let(:ctx) { ReactorSim::Operation::Context.new(controls: {}, dt: 1.0, tick: 1, content: content) }

  # A diagnostic reading a plain field off a fake node, so the chain is the only thing
  # under test.
  # Named explicitly rather than via `described_class`, which inside the nested filter
  # groups below would resolve to the filter rather than to Diagnostic.
  def instrument(filters: [], display: nil, source: nil)
    ReactorSim::Diagnostic.new(
      id: :probe, source: source || ReactorSim::Sources::Field.new(:box, :level),
      filters: filters, display: display
    )
  end

  def drive(diagnostic, values, rng: self.rng)
    state = diagnostic.initial_state(rng)
    values.map do |value|
      state = diagnostic.record(state, {}, { box: { level: value } }, ctx, rng)
      { value: diagnostic.read(state), truth: diagnostic.truth(state),
        flags: diagnostic.flags(state) }
    end
  end

  describe "the chain" do
    it "passes the source value through untouched when there are no filters" do
      expect(drive(instrument, [ 42.0 ]).last[:value]).to eq(42.0)
    end

    it "applies filters in order" do
      readings = drive(instrument(filters: [ ReactorSim::Filters::Quantize.new(10.0),
                                             ReactorSim::Filters::Range.new(0.0, 20.0) ]),
                       [ 34.0 ])

      expect(readings.last[:value]).to eq(20.0) # quantised to 30, then clamped to 20
    end

    it "reports a source it cannot read as offline rather than as zero" do
      diagnostic = instrument(source: ReactorSim::Sources::Field.new(:missing, :level))
      state = diagnostic.record(diagnostic.initial_state(rng), {}, {}, ctx, rng)

      expect(diagnostic.flags(state)).to include(:offline)
      expect(diagnostic.read(state)).to be_nil
    end
  end

  describe ReactorSim::Filters::Lag do
    it "reports what was true n ticks ago" do
      readings = drive(instrument(filters: [ described_class.new(2) ]), [ 1.0, 2.0, 3.0, 4.0, 5.0 ])

      expect(readings.map { |r| r[:value] }).to eq([ 1.0, 2.0, 1.0, 2.0, 3.0 ])
    end

    # v0 seeded gauge history with 0.0, so a match opened showing a reactor at 0 °C and
    # 0 kPa — which reads as "instruments not connected" rather than "idle".
    it "shows the current value while warming up rather than a fabricated zero" do
      readings = drive(instrument(filters: [ described_class.new(3) ]), [ 500.0 ])

      expect(readings.first[:value]).to eq(500.0)
      expect(readings.first[:flags]).to include(:warming_up)
    end
  end

  describe ReactorSim::Filters::Noise do
    it "offsets the reading away from the truth" do
      readings = drive(instrument(filters: [ described_class.new(5.0) ]), [ 100.0 ])

      expect(readings.first[:value]).not_to eq(100.0)
      expect(readings.first[:value]).to be_within(5.0).of(100.0)
    end

    # Finding #4. With a fresh draw every tick, every noisy gauge reported a change every
    # tick forever and "send only what changed" compressed nothing at all. Holding the
    # offset until the signal actually moves is both more honest and what makes the delta
    # protocol worth having.
    it "holds its offset steady while the underlying value is static" do
      readings = drive(instrument(filters: [ described_class.new(5.0, deadband: 2.0) ]),
                       [ 100.0 ] * 8)

      expect(readings.map { |r| r[:value] }.uniq.size).to eq(1)
    end

    it "redraws once the value moves past the deadband" do
      inputs = [ 100.0, 100.5, 100.9, 130.0 ]
      readings = drive(instrument(filters: [ described_class.new(5.0, deadband: 2.0) ]), inputs)
      offsets = readings.each_with_index.map { |r, i| r[:value] - inputs[i] }

      # Compared with a tolerance because recovering the offset by subtraction reintroduces
      # float rounding — the stored offset itself is untouched.
      expect(offsets[1]).to be_within(1e-9).of(offsets[0])
      expect(offsets[2]).to be_within(1e-9).of(offsets[0])
      expect((offsets[3] - offsets[0]).abs).to be > 1e-6
    end
  end

  # Finding #3. v0 computed `pegged?` and had no way to ship it, so a maxed-out gauge was
  # indistinguishable from one reading exactly its maximum.
  describe ReactorSim::Filters::Range do
    it "clamps and says so when the needle is pinned" do
      readings = drive(instrument(filters: [ described_class.new(0.0, 600.0) ]),
                       [ -5.0, 300.0, 900.0 ])

      expect(readings[0][:flags]).to include(:pegged_low)
      expect(readings[1][:flags]).to be_empty
      expect(readings[2][:flags]).to include(:pegged_high)
      expect(readings[2][:value]).to eq(600.0)
    end
  end

  describe ReactorSim::Filters::Rate do
    it "reports change per simulated second" do
      readings = drive(instrument(filters: [ described_class.new ]), [ 10.0, 15.0, 25.0 ])

      expect(readings.map { |r| r[:value] }).to eq([ 0.0, 5.0, 10.0 ])
    end
  end

  describe ReactorSim::Filters::Misread do
    it "is occasionally and confidently wrong" do
      readings = drive(instrument(filters: [ described_class.new(chance: 0.5, magnitude: 50.0) ]),
                       [ 100.0 ] * 40)
      wrong = readings.count { |r| r[:flags].include?(:misread) }

      expect(wrong).to be > 0
      expect(wrong).to be < 40
    end

    it "is deterministic for a given seed" do
      a = drive(instrument(filters: [ described_class.new(chance: 0.5, magnitude: 50.0) ]),
                [ 100.0 ] * 20, rng: ReactorSim::Rng.new(99))
      b = drive(instrument(filters: [ described_class.new(chance: 0.5, magnitude: 50.0) ]),
                [ 100.0 ] * 20, rng: ReactorSim::Rng.new(99))

      expect(a).to eq(b)
    end
  end

  # Part of the instrument palette rather than of any current operation, and specced for
  # exactly that reason: an upgrade slot nobody has exercised is an upgrade slot that does
  # not work when it is first reached for.
  describe ReactorSim::Filters::Stick do
    it "catches and holds its last reading, then releases" do
      readings = drive(instrument(filters: [ described_class.new(chance: 0.5) ]),
                       (1..60).map(&:to_f))
      stuck = readings.each_with_index.select { |r, _| r[:flags].include?(:stuck) }

      expect(stuck).not_to be_empty, "the needle never caught"
      expect(stuck.size).to be < 60, "the needle never released"
      stuck.each { |r, i| expect(r[:value]).to be <= (i + 1).to_f }
    end
  end

  describe ReactorSim::Sources::Aggregate do
    let(:content) { ReactorSim::Content.default }

    def tank(id, kg)
      ReactorSim::Nodes::Vessel.new(
        id: id, volume_m3: 10.0,
        initial_contents: [ { resource: :water, kg: kg } ]
      )
    end

    it "sums a quantity across several nodes" do
      nodes = { a: tank(:a, 100.0), b: tank(:b, 250.0) }
      states = nodes.to_h { |id, n| [ id, n.initial_state(rng, content) ] }
      source = described_class.new(
        %i[a b].map { |id| ReactorSim::Sources::Contents.new(id, :water) }
      )

      expect(source.sample(nodes, states, content).value).to be_within(1e-6).of(350.0)
    end

    it "takes the maximum when asked to" do
      nodes = { a: tank(:a, 100.0), b: tank(:b, 250.0) }
      states = nodes.to_h { |id, n| [ id, n.initial_state(rng, content) ] }
      source = described_class.new(
        %i[a b].map { |id| ReactorSim::Sources::Contents.new(id, :water) }, operation: :max
      )

      expect(source.sample(nodes, states, content).value).to be_within(1e-6).of(250.0)
    end

    it "reports unavailable when nothing it reads exists" do
      source = described_class.new([ ReactorSim::Sources::Contents.new(:nowhere, :water) ])

      expect(source.sample({}, {}, content).available).to be(false)
    end
  end

  # Durability, readable but never numeric (docs/simulation_architecture.md §7).
  describe "durability as prose" do
    let(:diagnostic) do
      described_class.new(
        id: :condition,
        source: ReactorSim::Sources::Field.new(:box, :level),
        filters: [ ReactorSim::Filters::Bands.new([ 1.0, 250.0, 600.0, 900.0 ]) ],
        display: ReactorSim::Displays::Prose.new(
          [ "about to let go", "weeping badly", "showing some cracks", "a bit tired", "sound" ]
        )
      )
    end

    it "describes the state of a part in words, never a number" do
      readings = drive(diagnostic, [ 1000.0, 700.0, 300.0, 50.0, 0.0 ])

      expect(readings.map { |r| r[:value] }).to eq([
        "sound", "a bit tired", "showing some cracks", "weeping badly", "about to let go"
      ])
    end
  end

  # Finding #5. A diagnostic could only read one scalar off one mechanism, so a buffer
  # level was structurally unobservable — which is why the steam line that killed the
  # player in the old trace had no instrument at all.
  describe "sources the old engine could not express" do
    let(:op) do
      m = ReactorSim::Match.create(id: "s", seed: 7,
                                   operations: [ { id: "rig", type: :loop_rig } ], time_scale: 4.0)
      m.operation(:rig).tap { |o| o.set_control(:burner, 100) }
    end

    it "can gauge how full a line is" do
      120.times { |i| op.step!(tick: i + 1) }

      expect(op.project.gauges.fetch(:steam_line_level)).to be > 0
    end

    it "can gauge one substance inside a mixture" do
      120.times { |i| op.step!(tick: i + 1) }

      expect(op.project.gauges.fetch(:boiler_water)).to be > 0
    end

    it "can gauge a rate of change" do
      40.times { |i| op.step!(tick: i + 1) }

      expect(op.project.gauges.fetch(:boiler_heating_rate)).to be > 0
    end
  end

  describe "player and spectator views" do
    let(:op) do
      m = ReactorSim::Match.create(id: "v", seed: 7,
                                   operations: [ { id: "rig", type: :loop_rig } ], time_scale: 4.0)
      m.operation(:rig).tap { |o| o.set_control(:burner, 100) }
    end

    before { 80.times { |i| op.step!(tick: i + 1) } }

    it "shows the spectator the truth and the player a distorted version of it" do
      expect(op.project(viewer: :player).gauges.fetch(:boiler_temp))
        .not_to eq(op.project(viewer: :spectator).gauges.fetch(:boiler_temp))
    end

    # Asserted as a lag relationship rather than "truth is higher", which only holds while
    # the temperature is climbing steeply — once the boiler reaches saturation it plateaus
    # and gauge noise decides the ordering.
    it "gives the spectator the undelayed value" do
      history = (1..6).map do |i|
        op.step!(tick: 100 + i)
        [ op.project(viewer: :spectator).gauges.fetch(:boiler_temp),
          op.project(viewer: :player).gauges.fetch(:boiler_temp) ]
      end

      truths = history.map(&:first)
      player_now = history.last.last

      # The gauge lags two ticks, and carries up to 1.5 K of noise on top.
      expect(player_now).to be_within(2.0).of(truths[-3])
    end

    # The god-view skips distortions, NOT transforms. Reporting the raw sample as "truth"
    # made a rate instrument show a temperature of 300 in a box labelled K/s.
    it "still applies filters that change what the number means" do
      truth = op.project(viewer: :spectator).gauges.fetch(:boiler_heating_rate)

      expect(truth.abs).to be < 100.0 # a rate, not a temperature
    end

    it "renders a banded prose gauge for the spectator too" do
      expect(op.project(viewer: :spectator).gauges.fetch(:boiler_condition)).to be_a(String)
    end

    it "does not send instrument flags to a spectator, who has no instrument" do
      expect(op.project(viewer: :spectator).flags).to be_empty
    end
  end

  describe "the projection" do
    let(:op) do
      m = ReactorSim::Match.create(id: "p", seed: 7,
                                   operations: [ { id: "rig", type: :loop_rig } ], time_scale: 4.0)
      m.operation(:rig).tap { |o| o.set_control(:burner, 60) }
    end

    # The property everything else rests on: a tick may be projected any number of times —
    # a player view, a spectator view, a resync of either — and none of it may perturb the
    # match. That is why noise is drawn in `record` and never in `read`.
    it "does not advance the simulation however many times it is called" do
      40.times { |i| op.step!(tick: i + 1) }
      before = ReactorSim.canonical(op.to_h)

      20.times { op.project; op.project(viewer: :spectator) }

      expect(ReactorSim.canonical(op.to_h)).to eq(before)
    end

    it "returns the same view every time for the same tick" do
      40.times { |i| op.step!(tick: i + 1) }

      expect(op.project.to_h).to eq(op.project.to_h)
    end

    it "sends only what changed in a delta" do
      40.times { |i| op.step!(tick: i + 1) }
      previous = op.project
      op.step!(tick: 41)
      delta = op.project.delta_from(previous)

      expect(delta.fetch(:gauges).size).to be < previous.gauges.size
    end

    it "sends the whole view when there is no previous one" do
      op.step!(tick: 1)

      expect(op.project.delta_from(nil)).to include(:gauges, :controls, :incidents)
    end

    it "describes the panel so a client can draw the instruments once" do
      panel = op.panel

      expect(panel.fetch(:instruments).map { |i| i.fetch(:kind) })
        .to include(:needle, :digital, :lamp, :prose)
      expect(panel.fetch(:controls).map { |c| c.fetch(:id) }).to include(:burner)
    end

    it "reports both the target and where the lever has actually got to" do
      op.step!(tick: 1)

      expect(op.project.controls.fetch(:burner)).to eq({ target: 60.0, actual: 60.0 })
    end
  end

  describe "snapshot" do
    # Instrument flags are symbols in an array — values, not keys — so JSON stringifies
    # them for exactly the same reason it stringifies resource ids.
    it "round-trips diagnostic state without losing a bit" do
      match = ReactorSim::Match.create(id: "r", seed: 7,
                                       operations: [ { id: "rig", type: :loop_rig } ], time_scale: 4.0)
      match.apply([ { type: "set_control", operation_id: "rig",
                      control_point_id: "burner", value: 100 } ])
      60.times { match.step! }

      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))

      expect(restored.digest).to eq(match.digest)
      expect(restored.project(operation_id: :rig).to_h).to eq(match.project(operation_id: :rig).to_h)
    end
  end
end
