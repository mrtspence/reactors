# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **Somewhere to take cover**: a pure fitting, no ports, whose `cover` is the share of a
    # `sheltered:` peril it keeps off whoever is in it (`Cover`). It shelters `seats` of those
    # taking cover in each of its `places:` — a hut by the face — or whoever is at its `stations:`,
    # called or not — a machine's cab over its driver and fireman.
    class Shelter < Node
      # The cover of the kinds there are, against crouching's `Cover::CROUCH`: an open platform a
      # little better, a timber hut most, steel plate nearly all.
      OPEN = 0.6
      TIMBER = 0.9
      STEEL = 0.98

      attr_reader :cover, :places, :seats, :stations

      def initialize(id:, cover:, label: nil, places: [], seats: 0, stations: [])
        @cover = cover.to_f
        @places = Array(places).map(&:to_sym).freeze
        @seats = Integer(seats)
        @stations = Array(stations).map(&:to_sym).freeze
        super(id: id, label: label)
      end
    end
  end
end
