# frozen_string_literal: true

module ReactorSim
  module Mechanisms
    # Where the two reagents meet. The heart of the operation and the thing most
    # likely to kill everyone.
    #
    # The vessel is interesting to oversee because its demands pull against each
    # other: reagents must arrive in balance to react at all, the reaction heats the
    # vessel, and heat is what makes the steam that earns you anything — while cooling
    # protects the vessel and throws away the output.
    class ReactionVessel < Mechanism
      MAX_INTAKE        = 10.0  # units/sec drawn from each feed line
      EFFICIENCY        = 0.55  # fraction of the balanced pair that reacts per tick
      HEAT_PER_UNIT     = 9.0   # °C per reacted unit
      STEAM_PER_UNIT    = 1.4   # steam units per reacted unit, scaled by temperature
      AMBIENT           = 20.0
      AMBIENT_LOSS      = 0.08  # passive cooling coefficient per second
      COOLANT_MAX       = 64.0  # °C/sec removed at 100% coolant
      REF_TEMP          = 260.0 # steam yield scales against this
      VENT_RATE         = 40.0  # steam units/sec the relief vent can pass

      # Pressure is derived, not accumulated: it is what the trapped steam and the
      # heat are *doing* to the vessel right now. Steam that cannot escape is the
      # dangerous part, and it can only fail to escape for two reasons — the vent is
      # saturated, or the steam line downstream has backed up.
      BASE_PRESSURE     = 100.0
      PRESSURE_PER_UNIT = 9.0   # kPa per unit of trapped steam
      PRESSURE_PER_DEG  = 0.6   # kPa per °C above ambient

      TEMP_SAFE         = 420.0
      PRESSURE_SAFE     = 850.0
      STRESS_RATE       = 0.055

      attr_reader :control_id, :in_buffers, :out_buffer

      def initialize(id:, label:, control_id:, in_buffers:, out_buffer:)
        super(id: id, label: label)
        @control_id = control_id
        @in_buffers = in_buffers # [line_a, line_b]
        @out_buffer = out_buffer
      end

      def initial_state(rng)
        {
          temperature: AMBIENT,
          pressure: BASE_PRESSURE,
          slurry_a: 0.0,
          slurry_b: 0.0,
          reacted: 0.0,
          trapped: 0.0,
          vented: 0.0,
          wear: 0.0,
          threshold: roll_threshold(rng),
          failed: false
        }
      end

      def step(state, ctx)
        return ruptured(state) if state.fetch(:failed)

        line_a, line_b = @in_buffers
        dt = ctx.dt

        draw_a = [ ctx.available.fetch(line_a, 0.0), MAX_INTAKE * dt ].min
        draw_b = [ ctx.available.fetch(line_b, 0.0), MAX_INTAKE * dt ].min

        slurry_a = state.fetch(:slurry_a) + draw_a
        slurry_b = state.fetch(:slurry_b) + draw_b

        # Only balanced pairs react. Feeding one reagent hard while starving the other
        # just accumulates unreacted slurry, which is the mistake the diagnostics are
        # there to let you catch.
        reacted = [ slurry_a, slurry_b ].min * EFFICIENCY

        temperature = heat(state.fetch(:temperature), reacted, ctx.controls.fetch(@control_id, 0.0), dt)
        steam = reacted * STEAM_PER_UNIT * (temperature / REF_TEMP)
        steam = 0.0 if steam.negative?

        # Venting is capped by the relief vent AND by how much room the steam line has
        # left. The second cap is what makes the turbine throttle a safety control
        # rather than just an output dial: throttle down, the line backs up, the vessel
        # can no longer vent, and trapped steam drives it toward rupture. Opening the
        # throttle relieves the vessel at the cost of overspeeding the turbine.
        pool = state.fetch(:trapped) + steam
        room = ctx.room.fetch(@out_buffer, Float::INFINITY)
        vented = [ pool, room, VENT_RATE * dt ].min
        vented = 0.0 if vented.negative?
        trapped = pool - vented

        pressure = BASE_PRESSURE +
                   trapped * PRESSURE_PER_UNIT +
                   (temperature - AMBIENT) * PRESSURE_PER_DEG

        wear = state.fetch(:wear) + stress(temperature, pressure, dt)
        failed = wear >= state.fetch(:threshold)

        next_state = state.merge(
          temperature: temperature,
          pressure: pressure,
          slurry_a: slurry_a - reacted,
          slurry_b: slurry_b - reacted,
          reacted: reacted,
          trapped: trapped,
          vented: vented,
          wear: wear,
          failed: failed
        )

        Result.new(
          state: next_state,
          draws: { line_a => draw_a, line_b => draw_b },
          pushes: { @out_buffer => vented },
          events: failed ? [ rupture_event(next_state) ] : []
        )
      end

      private

      def heat(temperature, reacted, coolant, dt)
        gained = reacted * HEAT_PER_UNIT
        removed = (coolant / 100.0) * COOLANT_MAX * dt
        ambient = (temperature - AMBIENT) * AMBIENT_LOSS * dt
        [ temperature + gained - removed - ambient, AMBIENT ].max
      end

      def stress(temperature, pressure, dt)
        over_temp = temperature > TEMP_SAFE ? (temperature - TEMP_SAFE) / TEMP_SAFE : 0.0
        over_pressure = pressure > PRESSURE_SAFE ? (pressure - PRESSURE_SAFE) / PRESSURE_SAFE : 0.0
        (over_temp + over_pressure) * STRESS_RATE * dt
      end

      def rupture_event(state)
        failure_event(state, :vessel_rupture,
                      temperature: state.fetch(:temperature),
                      pressure: state.fetch(:pressure))
      end

      # A ruptured vessel holds no pressure and reacts nothing. It does not repair itself.
      def ruptured(state)
        Result.new(
          state: state.merge(pressure: 0.0, reacted: 0.0, vented: 0.0, trapped: 0.0,
                             temperature: [ state.fetch(:temperature) - 4.0, AMBIENT ].max),
          pushes: { @out_buffer => 0.0 }
        )
      end
    end
  end
end
