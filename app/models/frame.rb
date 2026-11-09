# frozen_string_literal: true

# **The app's frame around one page**: the nav row, the state strip and the feed, which every
# screen shares (`docs/reference/layout.md`). It frames one machine — the page's own, or the
# match's primary for a page that belongs to the whole match — and shows only that machine's
# state: another player's output stays on their screen.
class Frame
  SCREENS = { "consoles" => :console, "loadouts" => :outfitting, "crews" => :crew,
              "match_setups" => :match_setup }.freeze

  # A machine's own screens, beside its console.
  FITTING = %i[outfitting crew].freeze

  # Shown in the nav row, not yet pages. TODO: Hiring is the roster and buying people
  # (`Blueprint.minions`), Workshop the blueprints and unlocks, Record the UI overhaul's U6.
  STUBS = %w[Hiring Workshop Record].freeze

  attr_reader :operation, :screen

  # Nil where there is nothing to frame: a controller with no screen here, or a machine the
  # player may not see.
  def self.for(controller:, match_id:, operation:, player:)
    screen = SCREENS[controller]
    operation ||= Operation.locate(match_id, DevMatch::PRIMARY)
    return nil unless screen && operation&.viewable_by?(player)

    new(operation: operation, player: player, screen: screen)
  end

  def initialize(operation:, player:, screen:)
    @operation = operation
    @player = player
    @screen = screen
  end

  def match_id = @operation.match_id
  def operation_id = @operation.operation_id
  def fittable? = @operation.fittable?

  # **The frame says when the hatch is open.** A development affordance that looks identical to
  # the real thing is how somebody debugs the wrong rule for an afternoon.
  def borrowed? = Operator.bypass? && !@operation.owner_id.eql?(@player)

  # Every machine in the match the player may look at, so a pill never leads to a 404.
  def machines
    @machines ||= Operation.in_match(match_id).select { |op| op.viewable_by?(@player) }
  end

  # Where a machine's pill goes: the same screen on that machine where it has one, else its
  # console — so switching machine never changes what you are doing to one you cannot do it to.
  def screen_for(machine)
    return :console unless FITTING.include?(@screen)

    machine.fittable? && machine.operable_by?(@player) ? @screen : :console
  end

  def weather = strip(:weather)
  def outputs = strip(:output)

  # **Ids name the machine**, so the frame survives navigation between one machine's screens and
  # is replaced, with a fresh subscription, on another machine's.
  def dom_id(region) = "frame-#{region}-#{operation_id}"

  private

  def strip(role) = panel.fetch(:instruments).select { |chrome| chrome[:role] == role }

  def panel = @panel ||= DevMatch.panel(operation_id: operation_id)
end
