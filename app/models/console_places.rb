# frozen_string_literal: true

# **The console's panel cut by place**: one entry a place panel draws, in the machine's order,
# from the places `Operation#panel` derived for each instrument and lever. A machine with several
# places gets The Works last, for what is in none; one with a single place puts everything in it;
# one with none has only The Works.
class ConsolePlaces
  WORKS = :works

  Place = Data.define(:id, :label, :instruments, :controls)

  include Enumerable

  def initialize(panel)
    @panel = panel
    @declared = panel.fetch(:places, [])
  end

  def each(&) = places.each(&)

  # The places box is worth drawing only when there is more than one place to choose between.
  def boxed? = @declared.size > 1

  # The place everybody is drawn in whose own place has no panel.
  def fallback = places.last.id

  def places
    @places ||= if boxed?
      @declared.map { |place| entry(place.fetch(:id), place.fetch(:label)) { |places| places.include?(place.fetch(:id)) } } +
        [ entry(WORKS, "The Works", &:empty?) ]
    else
      only = @declared.first
      [ entry(only ? only.fetch(:id) : WORKS, only ? only.fetch(:label) : "The Works") { true } ]
    end
  end

  # Where each post stands, for the console to send somebody's row where they are going.
  def stations = @panel.fetch(:stations).to_h { |station| [ station.fetch(:id), station[:place] ] }

  # **Each person in the panel of the place their seat was dealt to**, with their place on the
  # roster: `{ place_id => [[minion, order], ...] }`. The console moves them as they walk.
  def seated(minions)
    panels = places.map(&:id)
    minions.each_with_index.group_by { |minion, _| panels.include?(minion.default_place) ? minion.default_place : fallback }
  end

  private

  # An instrument is drawn in every place it names; a lever where it stands, or The Works.
  def entry(id, label)
    instruments = @panel.fetch(:instruments).reject { |chrome| chrome[:role] }
                        .select { |chrome| yield(chrome.fetch(:places, [])) }
    controls = @panel.fetch(:controls).select { |control| yield(control[:place] ? [ control[:place] ] : []) }
    Place.new(id:, label:, instruments:, controls:)
  end
end
