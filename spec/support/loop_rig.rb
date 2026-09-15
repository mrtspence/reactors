# frozen_string_literal: true

# A deliberately small operation that exercises every part of the engine at once, and in
# particular the things the old paradigm could not do:
#
#   * a CLOSED LOOP — boiler → steam line → condenser → return line → boiler. No
#     topological order exists here, which is the point.
#   * phase change driven by pressure, not by a hardcoded rule
#   * heat conduction between a vessel and the pipe attached to it
#   * ambient loss, so energy leaves through the walls rather than only at the ends
#   * back-pressure, when the steam valve is closed and the boiler has nowhere to vent
#
# It is a test fixture rather than a game operation. The Chemical Vats rebuild is a
# separate exercise with its own design input.
module LoopRig
  TYPE = :loop_rig

  module_function

  def build(id:, seed:, time_scale: 1.0, state: nil, rngs: nil, content: nil)
    ReactorSim::Operation.new(
      id: id, type: TYPE, seed: seed, time_scale: time_scale,
      state: state, rngs: rngs, content: content,
      nodes: nodes, links: links, thermal_links: thermal_links,
      control_points: control_points, diagnostics: diagnostics
    )
  end

  # One of each kind of instrument, so the whole Source -> Filters -> Display path is
  # exercised: a lagged noisy needle, a level the old engine could not have shown at all,
  # a rate, a lamp, and durability rendered as prose by an unreliable observer.
  def diagnostics
    [
      ReactorSim::Diagnostic.new(
        id: :boiler_temp, label: "Boiler Temperature",
        source: ReactorSim::Sources::Derived.new(:boiler, :temperature_k),
        filters: [ ReactorSim::Filters::Lag.new(2),
                   ReactorSim::Filters::Noise.new(1.5),
                   ReactorSim::Filters::Range.new(273.15, 873.15) ],
        display: ReactorSim::Displays::Needle.new(unit: "°C", convert: :k_to_c,
                                                  min: 273.15, max: 873.15)
      ),

      ReactorSim::Diagnostic.new(
        id: :boiler_pressure, label: "Boiler Pressure",
        source: ReactorSim::Sources::Derived.new(:boiler, :pressure_pa),
        filters: [ ReactorSim::Filters::Lag.new(1),
                   ReactorSim::Filters::Noise.new(4_000.0),
                   ReactorSim::Filters::Range.new(0.0, 2_000_000.0) ],
        display: ReactorSim::Displays::Needle.new(unit: "kPa", convert: :kpa, precision: 0)
      ),

      # The instrument v0 was structurally incapable of providing: how full something is.
      #
      # It used to point at `:steam_line`, which was a Conduit. Conduits stopped holding
      # material when transport moved to paths, so a level on one now reads nothing at all —
      # `Level` needs `contents_volume` and `volume_m3`, and a conduit has neither. A holder
      # is the only thing a level means anything about.
      ReactorSim::Diagnostic.new(
        id: :condenser_level, label: "Condenser Level",
        source: ReactorSim::Sources::Level.new(:condenser),
        filters: [ ReactorSim::Filters::Quantize.new(5.0) ],
        display: ReactorSim::Displays::Needle.new(unit: "%", precision: 0, min: 0.0, max: 100.0)
      ),

      ReactorSim::Diagnostic.new(
        id: :boiler_water, label: "Boiler Water",
        source: ReactorSim::Sources::Contents.new(:boiler, :water),
        filters: [ ReactorSim::Filters::Noise.new(0.5) ],
        display: ReactorSim::Displays::Digital.new(unit: "kg", precision: 1)
      ),

      # Rate of change, which needs memory of the previous tick and therefore has to be a
      # filter rather than a source.
      ReactorSim::Diagnostic.new(
        id: :boiler_heating_rate, label: "Heating Rate",
        source: ReactorSim::Sources::Derived.new(:boiler, :temperature_k),
        filters: [ ReactorSim::Filters::Rate.new, ReactorSim::Filters::Quantize.new(0.01) ],
        display: ReactorSim::Displays::Digital.new(unit: "K/s", precision: 2)
      ),

      ReactorSim::Diagnostic.new(
        id: :boiler_failed, label: "Boiler Fault",
        source: ReactorSim::Sources::Broken.new(:boiler),
        display: ReactorSim::Displays::Lamp.new(colour: :red, label: "RUPTURE")
      ),

      # Durability, readable but never numeric. Banded, put into prose, delayed twelve
      # ticks and occasionally just wrong — a report from someone eyeballing it rather
      # than an integrity readout (docs/simulation_architecture.md §7).
      ReactorSim::Diagnostic.new(
        id: :boiler_condition, label: "Boiler Condition", observer: :grubwick,
        source: ReactorSim::Sources::Durability.new(:boiler),
        filters: [ ReactorSim::Filters::Lag.new(12),
                   ReactorSim::Filters::Misread.new(chance: 0.15, magnitude: 300.0),
                   ReactorSim::Filters::Bands.new([ 1.0, 250.0, 600.0, 900.0 ]) ],
        display: ReactorSim::Displays::Prose.new([
          "about to let go", "weeping badly", "showing some cracks", "a bit tired", "sound"
        ])
      )
    ]
  end

  def nodes
    [
      ReactorSim::Nodes::Vessel.new(
        id: :boiler, label: "Boiler", volume_m3: 4.0,
        heat_capacity: 4.0e5, ambient_conductance: 40.0,
        initial_temperature_k: 300.0,
        initial_contents: [ { resource: :water, kg: 400.0, temperature_k: 300.0 } ],
        heater_control_id: :burner, heater_watts: 3.0e6,
        max_pressure_pa: 2.5e6, stress_rate: 40.0,
        ports: [
          ReactorSim::Port.new(id: :feed, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 6.0),
          ReactorSim::Port.new(id: :steam, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 6.0)
        ]
      ),

      ReactorSim::Nodes::Conduit.new(
        id: :steam_line, label: "Steam Line", accepts: [ :gas ],
        max_kg_per_s: 6.0, heat_capacity: 2.0e4,
        ambient_conductance: 15.0, control_id: :steam_valve
      ),

      ReactorSim::Nodes::Vessel.new(
        id: :condenser, label: "Condenser", volume_m3: 4.0,
        heat_capacity: 3.0e5, ambient_conductance: 45_000.0,
        initial_temperature_k: 300.0,
        ports: [
          ReactorSim::Port.new(id: :inlet, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 6.0),
          ReactorSim::Port.new(id: :drain, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 6.0)
        ]
      ),

      ReactorSim::Nodes::Conduit.new(
        id: :return_line, label: "Return Line", accepts: [ :liquid ],
        max_kg_per_s: 6.0, heat_capacity: 1.5e4,
        ambient_conductance: 10.0, control_id: :return_valve
      )
    ]
  end

  # The loop. Following these edges returns you to where you started, which is exactly the
  # topology a topological sort cannot order — and which double buffering handles without
  # noticing.
  def links
    [
      ReactorSim::Link.new(from: [ :boiler, :steam ],       to: [ :steam_line, :inlet ]),
      ReactorSim::Link.new(from: [ :steam_line, :outlet ],  to: [ :condenser, :inlet ]),
      ReactorSim::Link.new(from: [ :condenser, :drain ],    to: [ :return_line, :inlet ]),
      ReactorSim::Link.new(from: [ :return_line, :outlet ], to: [ :boiler, :feed ])
    ]
  end

  def thermal_links
    [ ReactorSim::ThermalLink.new(a: :boiler, b: :steam_line, conductance: 800.0) ]
  end

  def control_points
    [
      ReactorSim::ControlPoint.new(id: :burner, label: "Burner", node: :boiler),
      ReactorSim::ControlPoint.new(id: :steam_valve, label: "Steam Valve",
                                   node: :steam_line, default: 100.0),
      ReactorSim::ControlPoint.new(id: :return_valve, label: "Return Valve",
                                   node: :return_line, default: 100.0)
    ]
  end
end

# **`harness: true`, and without it this rig becomes an unlockable machine.** It has to register
# globally for `Match.create` to find it, and the delivery tier's blueprint catalogue is derived
# from that same registry — so the rig turned up as an operation nobody had priced and took the
# whole catalogue down with it. Only in a full-suite run, too, because nothing else loads this
# file.
ReactorSim::Operations.register(LoopRig::TYPE, harness: true) do |id:, seed:, time_scale: 1.0,
                                                                  state: nil, rngs: nil|
  LoopRig.build(id: id, seed: seed, time_scale: time_scale, state: state, rngs: rngs)
end
