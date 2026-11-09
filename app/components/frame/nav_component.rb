# frozen_string_literal: true

class Frame
  # **The nav row**, on every page: the match's machines, this machine's screens, the match's,
  # the stubs, and on the right the tick, the connection and the developer's menu.
  class NavComponent < ViewComponent::Base
    PILL = "text-xs px-2 py-1 rounded ring-1"
    CURRENT = "bg-slate-700 ring-slate-500 text-slate-100"
    OTHER = "bg-slate-800 ring-slate-700 text-slate-300 hover:bg-slate-700"

    def initialize(frame:)
      @frame = frame
      super()
    end

    attr_reader :frame

    def tabs
      own = [ [ "Console", :console ] ]
      own += [ [ "Outfitting", :outfitting ], [ "Crew", :crew ] ] if frame.fittable?
      own.map { |label, screen| [ label, path(screen, frame.operation), screen == frame.screen ] }
    end

    def machine_path(machine) = path(frame.screen_for(machine), machine)

    def pill(current) = "#{PILL} #{current ? CURRENT : OTHER}"

    def match_setup_path = helpers.edit_match_setup_path(match_id: frame.match_id)

    def reset_path = helpers.match_reset_path(match_id: frame.match_id)

    def chassis = (DevMatch.chassis(operation_id: frame.operation_id).to_s.tr("_", " ") if frame.fittable?)

    def time_scale = DevMatch.time_scale.then { |scale| scale unless (scale - 1.0).abs < 1e-9 }

    private

    def path(screen, machine)
      at = { match_id: machine.match_id, operation_id: machine.operation_id }
      case screen
      when :outfitting then helpers.edit_loadout_path(at)
      when :crew then helpers.edit_crew_path(at)
      else helpers.console_path(at)
      end
    end
  end
end
