# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      # **What a mobile engine's board says about the engine itself**, before what it is doing: the
      # fire out, the tank empty, the glass low, the drum down, the valve lifting. Read from the
      # engine's last tick by whichever node writes the board — the dipper, the train — through
      # `@engine`, the names of the pieces it reads: `{ boiler:, supply:, firebox:, relief: }` with
      # the boiler's `working_pa:`.
      module EngineBoard
        # Under these shares of his working pressure and of the glass, the board says so.
        SHORT_OF_STEAM = 0.75
        SHORT_OF_WATER = 0.35

        def engine_signal(ctx)
          fire = (ctx.node_state(@engine.fetch(:firebox)) || {}).dig(:ignition, :coal_combustion, :kg).to_f
          return :standing unless fire.positive?

          tank = Parcel.total_kg((ctx.node_state(@engine.fetch(:supply)) || {}).fetch(:parcels, []))
          return :out_of_water unless tank > Parcel::EPSILON
          return :short_of_water if ctx.node_reading(@engine.fetch(:boiler), :effective_fill).to_f < SHORT_OF_WATER
          return :short_of_steam if ctx.node_pressure(@engine.fetch(:boiler)).to_f < SHORT_OF_STEAM * @engine.fetch(:working_pa)

          :blowing_off if (ctx.node_state(@engine.fetch(:relief)) || {}).fetch(:lift, 0.0).positive?
        end
      end
    end
  end
end
