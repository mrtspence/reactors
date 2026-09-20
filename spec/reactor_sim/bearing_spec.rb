# frozen_string_literal: true

require "reactor_sim"

# The hot box, on a rig rather than on a machine.
#
# `Nodes::Bearing` is the one node whose drag is meant to **heat itself**, and the whole
# failure ladder hangs off that: friction raises its temperature, temperature spends its
# durability, and a wiped interface rubs harder than a sound one. Everything here is that loop.
#
# The rig is a heavy shaft turning freely with one bearing under it, so the bearing's own
# behaviour is never confused with an engine's. Starvation is expressed as a bearing built
# **dry** — `oil_charge_kg: 0.0` — which needs no state surgery and is exactly the condition
# the oiling round will produce when it can run a store empty.
RSpec.describe ReactorSim::Nodes::Bearing do
  let(:content) { ReactorSim::Content.default }

  # 1e6 kg·m² so the shaft coasts nearly unchanged across a run: the bearing is under test, not
  # the flywheel's rundown. Cast iron at this rim speed is nowhere near bursting.
  #
  # **The load is what decides whether a dry journal can actually cook**, and it has to be set
  # deliberately. Equilibrium is `T_ambient + P/ambient_conductance`, so the default 26 kN
  # plateaus at 461 K — above the service limit and below the melting point, which wipes and
  # then sits there forever. 40 kN is a heavy shaft, and a heavy shaft is the case worth
  # specifying.
  def rig(oil_charge_kg:, stress_rate: 200.0, damages: {}, material: :babbitt,
          static_load_n: 40_000.0, oil_loss_kg_per_m: 0.0, oiling: false, wear_rate: 0.0,
          lining_kg: 6.0)
    shaft = ReactorSim::Nodes::Flywheel.new(
      id: :shaft, mass_kg: 2.0e6, radius_m: 1.0, initial_omega: 18.0
    )
    bearing = ReactorSim::Nodes::Bearing.new(
      id: :journal, supports: :shaft, duty: :journal, material: material,
      heat_capacity: 45.0 * content.specific_heat(material),
      oil_charge_kg: oil_charge_kg, stress_rate: stress_rate, damages: damages,
      oil_loss_kg_per_m: oil_loss_kg_per_m, wear_rate: wear_rate, lining_kg: lining_kg,
      static_load_n: static_load_n, ambient_conductance: 42.0
    )
    nodes = [ shaft, bearing ]
    links = []

    controls = []

    if oiling
      nodes += [ oil_drum, oil_line ]
      links += [
        ReactorSim::Link.new(from: [ :drum, :out ],    to: [ :line, :inlet ]),
        ReactorSim::Link.new(from: [ :line, :outlet ], to: [ :journal, :oil_in ])
      ]
      # **Shut by default**, so a test can run a bearing down before opening it. A line with no
      # lever is always pouring, which is not a machine anybody has to attend to.
      controls << ReactorSim::ControlPoint.new(id: :oiling, label: "Oil Round",
                                               node: :line, default: 0.0)
    end

    ReactorSim::Operation.new(id: :rig, type: :rig, seed: 1, content: content,
                              nodes: nodes, links: links, control_points: controls)
  end

  def oil_drum
    ReactorSim::Nodes::Vessel.new(
      id: :drum, volume_m3: 0.3, ambient_conductance: 0.0,
      initial_contents: [ { resource: :bearing_oil, kg: 50.0 } ],
      ports: [ ReactorSim::Port.new(id: :out, direction: :outlet,
                                    accepts: [ :lubricant ], max_kg_per_s: 0.2) ]
    )
  end

  def oil_line
    ReactorSim::Nodes::Conduit.new(id: :line, accepts: [ :lubricant ],
                                   max_kg_per_s: 0.06, heat_capacity: 40.0,
                                   ambient_conductance: 0.0, control_id: :oiling)
  end

  def oil_kg(op, id = :journal)
    ReactorSim::Parcel.total_kg(op.state.fetch(:nodes).fetch(id).fetch(:parcels, []))
  end

  def journal(op) = op.state.fetch(:nodes).fetch(:journal)
  def temperature(op) = op.nodes.fetch(:journal).temperature_k(journal(op), content)
  def omega(op) = op.nodes.fetch(:shaft).omega(op.state.fetch(:nodes).fetch(:shaft))

  # Steps until `mode` is reached, returning the tick it happened on or nil.
  def run_to(op, mode, limit: 4000)
    (1..limit).each do |t|
      op.step!(tick: t)
      return t if journal(op).fetch(:failure) == mode
    end
    nil
  end

  describe "a bearing with oil in it" do
    it "runs warm and never wears" do
      op = rig(oil_charge_kg: 1.2)
      2000.times { |i| op.step!(tick: i + 1) }

      expect(journal(op).fetch(:failure)).to be_nil
      expect(op.nodes.fetch(:journal).integrity(journal(op))).to eq(1.0)
      expect(temperature(op)).to be < op.nodes.fetch(:journal).service_temperature_k(content)
    end
  end

  describe "the ladder" do
    # The rung that gives the player their warning. Asserting the ORDER matters more than
    # either tick: a threshold that slides with durability lets the part seize before fatigue
    # can finish, and then the warning rung never happens at all. That is not hypothetical —
    # it is what the first cut of `overload?` did, at 481.7 K on a 0.63 integrity.
    it "wipes before it seizes, not instead of" do
      op = rig(oil_charge_kg: 0.0)
      wiped = run_to(op, :wiped)
      expect(wiped).not_to be_nil, "a dry journal never wiped"

      seized = run_to(op, :seized)
      expect(seized).not_to be_nil, "a wiped journal never seized"
      expect(seized).to be > wiped
    end

    it "wipes above the service limit and seizes at the rating itself" do
      op = rig(oil_charge_kg: 0.0)
      node = op.nodes.fetch(:journal)

      run_to(op, :wiped)
      expect(temperature(op)).to be > node.service_temperature_k(content)
      expect(temperature(op)).to be < node.rated_temperature_k(content)

      run_to(op, :seized)
      expect(temperature(op)).to be >= node.rated_temperature_k(content)
    end

    # The runaway, and the reason `:wiped` is not merely a label: losing the white metal costs
    # the film, which raises the boundary fraction, which is what wiped it.
    #
    # **Asserted on an oiled bearing, because a dry one has nothing left to lose.** `film` is
    # already 0.0 when the charge is zero, so the derate changes nothing there — the runaway is
    # a mechanic for a bearing that is still partly wet, and a dry one is simply already at the
    # bottom of the Stribeck curve.
    it "rubs harder once wiped than it did sound" do
      op = rig(oil_charge_kg: 1.2)
      node = op.nodes.fetch(:journal)
      wet = journal(op)

      sound = node.film(wet.merge(failure: nil), 18.0)
      wiped = node.film(wet.merge(failure: :wiped), 18.0)
      seized = node.film(wet.merge(failure: :seized), 18.0)

      expect(sound).to be > 0.0
      expect(wiped).to be < sound
      expect(seized).to eq(0.0)
    end

    it "survives the round trip as a Symbol" do
      op = rig(oil_charge_kg: 0.0)
      run_to(op, :wiped)

      through_json = ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h.fetch(:state))))
      restored = op.send(:restore, through_json)

      # `eq` passes on the String this comes back as; only identity finds the bug.
      expect(restored.fetch(:nodes).fetch(:journal).fetch(:failure)).to be(:wiped)
    end
  end

  # The trap the design called out: **neither existing mechanism stops the shaft.**
  # `Tick#stress` zeroes momentum on the failing node and a bearing does not rotate;
  # `Arbiter.settle_drive` severs a link whose end failed and a bearing is not an end. A
  # seizure works only because the bearing keeps declaring a drag — and declares a far bigger
  # one. A regression here fails silently and in the safe direction, which is the worst kind.
  describe "seizing" do
    it "stops the shaft it was carrying" do
      op = rig(oil_charge_kg: 0.0)
      run_to(op, :seized)
      spinning = omega(op)

      4.times { |i| op.step!(tick: 5000 + i) }

      expect(spinning).to be > 1.0
      expect(omega(op)).to be < spinning * 0.05
    end

    it "takes the parts it is declared to take with it" do
      op = rig(oil_charge_kg: 0.0, damages: { seized: { shaft: 0.5 } })
      started = op.state.fetch(:nodes).fetch(:shaft).fetch(:durability)
      run_to(op, :seized)

      expect(op.state.fetch(:nodes).fetch(:shaft).fetch(:durability)).to be < started
    end
  end

  # **Wear is rubbing; heat is a second, separate mechanism.** Collapsing them into one law is
  # the mistake §3.10 records: a starved journal rubs at 10 kW while healthy piston rings rub at
  # 76, so one coefficient fast enough to wipe the first destroys the second in about a minute.
  describe "wearing by rubbing" do
    # `stress_rate: 0.0` throughout, so any durability spent here is Archard's and not the
    # thermal term's. Measured as durability rather than by reaching into the node: what matters
    # is that the part wears, not that a particular method returned a number.
    def spent(op, ticks: 400)
      ticks.times { |i| op.step!(tick: i + 1) }
      journal(op).fetch(:initial_durability) - journal(op).fetch(:durability)
    end

    it "does not wear at all without a rate, however hard it rubs" do
      expect(spent(rig(oil_charge_kg: 0.0, wear_rate: 0.0, stress_rate: 0.0))).to eq(0.0)
    end

    it "spends durability while it is turning" do
      expect(spent(rig(oil_charge_kg: 1.2, wear_rate: 7.3e-7, stress_rate: 0.0))).to be > 0.0
    end

    # The Stribeck curve doing the work: same load, same speed, and the only difference is
    # whether there is oil between the two surfaces.
    it "wears far faster dry than flooded" do
      wet = spent(rig(oil_charge_kg: 1.2, wear_rate: 7.3e-7, stress_rate: 0.0))
      dry = spent(rig(oil_charge_kg: 0.0, wear_rate: 7.3e-7, stress_rate: 0.0))

      expect(dry).to be > wet * 10.0
    end

    # **An oil film shears; it does not wear anything.** The viscous term is deliberately absent
    # from the wear law, so raising it changes the heat and not the durability.
    it "ignores viscous drag, which carries no metal away" do
      plain = ReactorSim::Nodes::Bearing.new(
        id: :journal, supports: :shaft, heat_capacity: 1.0e4,
        oil_charge_kg: 0.0, wear_rate: 7.3e-7, viscous_c: 3.5
      )
      syrupy = ReactorSim::Nodes::Bearing.new(
        id: :journal, supports: :shaft, heat_capacity: 1.0e4,
        oil_charge_kg: 0.0, wear_rate: 7.3e-7, viscous_c: 350.0
      )
      ctx = Struct.new(:dt, :content, :states, :nodes).new(ReactorSim::DT, content, {}, {})
      def ctx.node_omega(_id) = 18.0
      def ctx.node_state(_id) = nil
      def ctx.node_pressure(_id) = 0.0

      state = { parcels: [], joules: 0.0, failure: nil }
      expect(syrupy.rubbing_wear(state, ctx)).to eq(plain.rubbing_wear(state, ctx))
    end
  end

  # `Concerns::Fusible`. **Not a temperature bound** — measured, 6 kg of babbitt takes 31 K off
  # the spike of a seizure and nothing off the equilibrium, because the shaft dumps more energy in
  # one tick than the whole lining can absorb. What it buys is that `:seized` has a reason: the
  # white metal ran out and the carrier is riding the shaft.
  describe "melting its lining" do
    def lining(op) = journal(op).fetch(:fusible_remaining_kg)

    it "keeps its lining while it is merely hot" do
      op = rig(oil_charge_kg: 1.2, wear_rate: 0.0)
      400.times { |i| op.step!(tick: i + 1) }

      expect(temperature(op)).to be < op.nodes.fetch(:journal).rated_temperature_k(content)
      expect(lining(op)).to eq(6.0)
    end

    it "loses it once past the melting point, and cannot get it back" do
      op = rig(oil_charge_kg: 0.0)
      run_to(op, :seized)
      after_seizing = lining(op)

      400.times { |i| op.step!(tick: 5000 + i) }

      expect(after_seizing).to be < 6.0
      expect(lining(op)).to be <= after_seizing
      expect(lining(op)).to be >= 0.0
    end

    # **The energy leaves with the metal.** A melt that did not book its latent heat would be a
    # silent energy sink, which is exactly what `conservation_spec` exists to catch — and the
    # mass is deliberately NOT booked, because structure mass was never in `total_mass` and
    # reporting it would break the balance while blaming the wrong line.
    it "books the latent heat out and still balances" do
      op = rig(oil_charge_kg: 0.0)
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      run_to(op, :seized)
      200.times { |i| op.step!(tick: 5000 + i) }

      # A dry rig holds no parcels at all, so the mass baseline is zero — hence the floor, the
      # same one `conservation_spec` uses.
      expect(lining(op)).to be < 6.0
      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass0).abs /
             [ mass0.abs, 1.0 ].max).to be < 1e-9
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules0).abs /
             [ joules0.abs, 1.0 ].max).to be < 1e-9
    end

    # A material with no latent heat declared does not melt at all. **Infinity, not zero** —
    # zero would vaporise a part's whole substance the instant it passed its rating.
    it "does not melt a material that declares no latent heat" do
      op = rig(oil_charge_kg: 0.0, material: :bronze)
      2000.times { |i| op.step!(tick: i + 1) }

      expect(content.latent_heat_of_fusion_j_per_kg(:bronze)).to be_infinite
      expect(lining(op)).to eq(6.0)
    end
  end

  describe "the oil round" do
    # **The regression that disabled the entire mechanic, and it was silent.** Returning
    # `Intent.none` when full declares nothing, and a path with nothing declared at either end
    # is driven by the path — so oil kept arriving until the HOUSING was full. A journal meant
    # to hold 1.2 kg sat at 8.9, which is its 0.01 m³ of volume, and nothing could ever run
    # short of oil again. The draw has to be declared even when it is zero.
    it "takes only what it is short of, however much is on offer" do
      op = rig(oil_charge_kg: 1.2, oiling: true)
      op.set_control(:oiling, 100)
      400.times { |i| op.step!(tick: i + 1) }

      expect(oil_kg(op)).to be_within(1e-6).of(1.2)
    end

    it "fills a bearing that has been run down" do
      op = rig(oil_charge_kg: 1.2, oil_loss_kg_per_m: 2.0e-3, oiling: true)
      # The lever is shut, so nobody is on the round and it drinks its charge.
      600.times { |i| op.step!(tick: i + 1) }
      low = oil_kg(op)
      expect(low).to be < 1.0

      op.set_control(:oiling, 100)
      100.times { |i| op.step!(tick: 601 + i) }

      expect(oil_kg(op)).to be > low
      expect(oil_kg(op)).to be_within(0.05).of(1.2)
    end

    # **Oil spent is on the books.** It is neither vented nor spilled — an engine working
    # properly would read as one leaking if it were — so it has its own line, and the enthalpy
    # goes with it or the energy balance drifts by the heat content of every drop burnt off.
    it "books what it burns off, and balances both ways" do
      op = rig(oil_charge_kg: 1.2, oil_loss_kg_per_m: 2.0e-3, oiling: true)
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      800.times { |i| op.step!(tick: i + 1) }

      expect(op.ledger.fetch(:mass_consumed)).to be > 0.0
      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass0).abs / mass0)
        .to be < 1e-9
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules0).abs / joules0.abs)
        .to be < 1e-9
    end

    # Oil goes with sliding distance rather than with time, so a faster engine drinks more.
    # That is what makes working an engine hard cost something before it costs a bearing.
    it "spends oil by rubbing, not by the clock" do
      slow = ReactorSim::Nodes::Bearing.new(
        id: :journal, supports: :shaft, heat_capacity: 1.0e4,
        oil_charge_kg: 1.2, oil_loss_kg_per_m: 1.0e-3
      )
      state = { parcels: [], joules: 0.0 }
      ctx = Struct.new(:dt, :content, :speed).new(ReactorSim::DT, content, nil)
      def ctx.node_omega(_id) = speed

      ctx.speed = 9.0
      at_nine = slow.oil_loss_kg(state.merge(parcels: [ { resource: :bearing_oil, kg: 1.2,
                                                          joules: 0.0 } ]), ctx)
      ctx.speed = 18.0
      at_eighteen = slow.oil_loss_kg(state.merge(parcels: [ { resource: :bearing_oil, kg: 1.2,
                                                              joules: 0.0 } ]), ctx)

      expect(at_eighteen).to be_within(1e-9).of(at_nine * 2.0)
    end
  end

  # A bronze interface is rated 700 K against babbitt's 520 K, and the whole ladder moves with
  # it — the thresholds come from `content/`, never from a constant here.
  it "takes both of its thresholds from the material" do
    babbitt = rig(oil_charge_kg: 0.0).nodes.fetch(:journal)
    bronze = rig(oil_charge_kg: 0.0, material: :bronze).nodes.fetch(:journal)

    expect(bronze.rated_temperature_k(content)).to be > babbitt.rated_temperature_k(content)
    expect(bronze.service_temperature_k(content)).to be > babbitt.service_temperature_k(content)
    expect(babbitt.service_temperature_k(content))
      .to be_within(1e-9).of(babbitt.rated_temperature_k(content) *
                             described_class::SERVICE_FRACTION)
  end
end
