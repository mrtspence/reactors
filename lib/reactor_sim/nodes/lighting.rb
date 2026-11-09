# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **A light: it offers `darkvision` to the places it lights**, so a job gated on light can be
    # done there by anybody, lamp or none — the better of the two, never the sum (`Minion#gate`).
    #
    # **A `Load`, always**, even when it burns nothing: one that hangs off no shaft declares no
    # torque and its `omega` is never consulted. That keeps one class from a candle on a nail to a
    # dynamo's arc lamps.
    #
    # What it gives is `illumination` times:
    # - **its lever** (`control_id:`), turned down dimmer;
    # - **its shaft's speed** against `rated_omega`, for lamps on a dynamo — dark with the shaft
    #   stopped; driven past `BLOWS_AT` of rated speed, less once worn, they blow;
    # - **the fire it names** (`fire:`), its lit fuel against `fire_full_kg` as of last tick — a
    #   basket of coal, an oil burner — so it dims as the fire burns down;
    # - **its carbons** (`burns_s:`), spent while it is lit and put back by whoever is posted to
    #   `tended_by:` at `tend_per_s` a man; spent through, it is dark. `starts_spent:` draws how far
    #   gone they are when the match begins.
    #
    # `lights:` names the places it lights, its own if none. **A flame** (`flame:`, an ignition
    # offer) is an igniter in its room; **a gauze** (`gauze_passes_m_s:`) passes its flame past that
    # draught, read off `draught_from:` across `draught_area_m2`, and is a naked light then, named
    # `:gauze`. `supplied_from:` is the holder its fuel comes from, for its board.
    #
    #   state: lit, draught_m_s, signal; fire_share with `fire:`; spent with `burns_s:`
    class Lighting < Load
      include Concerns::Wearing

      SIGNALS = {
        out: "out",
        blown: "blown",
        dark_shaft: "dark — the shaft stopped",
        burnt_out: "carbons burnt out",
        running_dry: "running dry",
        burning_low: "burning low",
        carbons_short: "lit — carbons short",
        lit: "lit"
      }.freeze
      # What asks nothing of anybody (`Displays::Prose.signals`). Out is the lever off, as by day.
      CALM = %i[out lit].freeze

      BLOWS_AT = 1.4

      # Under this share of its fire the board says it burns low; past this share spent, its
      # carbons are short.
      LOW = 0.5
      SHORT = 0.7

      attr_reader :illumination, :lights, :fire, :fire_full_kg, :burns_s, :tended_by, :tend_per_s,
                  :supplied_from, :gauze_passes_m_s

      def initialize(illumination:, lights: [], fire: nil, fire_full_kg: nil, burns_s: nil, tended_by: nil,
                     tend_per_s: 0.0, starts_spent: nil, supplied_from: nil, igniter_kg_per_s: 0.0,
                     flame_watts: 0.0, flame_cause: nil, gauze_passes_m_s: nil, draught_from: nil,
                     draught_area_m2: 1.0, **opts)
        @illumination = illumination.to_f
        @lights = Array(lights).map(&:to_sym).freeze
        @fire = fire&.to_sym
        @fire_full_kg = fire_full_kg&.to_f
        @burns_s = burns_s&.to_f
        @tended_by = tended_by&.to_sym
        @tend_per_s = tend_per_s.to_f
        @starts_spent = starts_spent
        @supplied_from = supplied_from&.to_sym
        @igniter_kg_per_s = igniter_kg_per_s.to_f
        @flame_watts = flame_watts.to_f
        @flame_cause = flame_cause&.to_sym
        @gauze_passes_m_s = gauze_passes_m_s&.to_f
        @draught_from = draught_from&.to_sym
        @draught_area_m2 = draught_area_m2.to_f
        super(**opts)
      end

      def initial_state(rng, content = nil)
        state = super.merge(signal: SIGNALS.keys.index(:out))
        state = state.merge(fire_share: 0.0) if @fire
        return state unless @burns_s

        spent = @starts_spent ? rng.between(@starts_spent.begin, @starts_spent.end) : 0.0
        state.merge(spent: spent)
      end

      def overload?(state, _ctx, integrity)
        return false unless @rated_omega.positive?

        omega(state).abs / @rated_omega > 1.0 + ((BLOWS_AT - 1.0) * integrity)
      end

      def failure_modes = { blown: { derates: { illumination: 0.0 } } }

      # What somebody standing where it lights gets for free. Read off N−1 state and the actuated
      # levers, so it cannot depend on phase order.
      def ambient_tags(state, levers) = { darkvision: lit(state, levers) }

      # **The flame goes with the lever, not with the light.** A candle turned down is fewer
      # candles, each as hot as ever, so a powered tier's shaft speed has no say here.
      def ignition(state, levers)
        fraction = lever(levers)
        return through_the_gauze(state, fraction) if @gauze_passes_m_s
        return nil unless @igniter_kg_per_s.positive?

        { kg_per_s: @igniter_kg_per_s * fraction, watts: @flame_watts * fraction, cause: @flame_cause || @control_id }
      end

      def lit(state, levers)
        return 0.0 if state.fetch(:spent, 0.0) >= 1.0

        fraction = lever(levers)
        fraction *= (omega(state).abs / @rated_omega).clamp(0.0, 1.0) if @rated_omega.positive?
        fraction *= state.fetch(:fire_share, 0.0) if @fire

        @illumination * fraction * derating(state, :illumination)
      end

      # Recorded so the panel can read it as an ordinary field, the way `carried_kg` is.
      def apply(state, ctx, grant)
        applied = super.merge(lit: lit(state, ctx.controls), draught_m_s: draught_m_s(ctx))
        applied = applied.merge(fire_share: fire_share(ctx)) if @fire
        applied = applied.merge(spent: spent(applied, ctx)) if @burns_s
        applied.merge(signal: SIGNALS.keys.index(signal(applied, ctx)))
      end

      private

      def lever(levers) = @control_id ? (levers.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0) : 1.0

      def through_the_gauze(state, fraction)
        return nil unless state.fetch(:draught_m_s, 0.0) > @gauze_passes_m_s

        { kg_per_s: @igniter_kg_per_s * fraction, watts: @flame_watts * fraction, cause: :gauze }
      end

      def draught_m_s(ctx)
        return 0.0 unless @draught_from && ctx.dt.positive?

        kg = ctx.node_state(@draught_from)&.fetch(:carried_kg, 0.0).to_f
        kg / Units::AIR_DENSITY_KG_PER_M3 / @draught_area_m2 / ctx.dt
      end

      # The lit fuel in its fire, as of last tick, against a well-kept fire's.
      def fire_share(ctx)
        burning = ctx.node_state(@fire)&.fetch(:ignition, {}) || {}
        (burning.values.sum { |i| i.fetch(:kg, 0.0) } / @fire_full_kg).clamp(0.0, 1.0)
      end

      # Spent as it is lit, at full lever a whole set in `burns_s`; put back by its tenders.
      def spent(state, ctx)
        burning = @illumination.positive? ? state.fetch(:lit) / @illumination : 0.0
        tenders = @tended_by ? [ ctx.controls.fetch(@tended_by, 0.0) / 100.0, 0.0 ].max : 0.0
        (state.fetch(:spent, 0.0) + (((burning / @burns_s) - (@tend_per_s * tenders)) * ctx.dt)).clamp(0.0, 1.0)
      end

      def signal(state, ctx)
        return :blown if state[:failure]
        return :burnt_out if state.fetch(:spent, 0.0) >= 1.0
        return :out unless lever(ctx.controls).positive?
        return :dark_shaft if @rated_omega.positive? && (omega(state).abs / @rated_omega) < 0.1
        return :running_dry if supply_empty?(ctx)
        return :burning_low if @fire && state.fetch(:fire_share) < LOW
        return :carbons_short if state.fetch(:spent, 0.0) > SHORT

        :lit
      end

      def supply_empty?(ctx)
        return false unless @supplied_from

        Parcel.total_kg((ctx.node_state(@supplied_from) || {}).fetch(:parcels, [])) <= Parcel::EPSILON
      end
    end
  end
end
