# frozen_string_literal: true

module ReactorSim
  # Something a minion carries, wears or keeps in a pocket. Layer four of the four in
  # `content/archetypes/races.yml`, and the only one a player changes between matches.
  #
  # **An item contributes stat offsets and tags, and nothing else.** No nodes, no links, no
  # fragment — which is what makes this a much smaller thing than a `Part`, despite looking
  # like one. A pair of gloves has no wiring.
  #
  # Code rather than YAML, for the reason `Parts` gives: the pull of data was never
  # diffability, it was letting somebody outside this repository add one, and that is ruled
  # out. See docs/design_sketches/minions.md §7.
  class Equipment
    # Three, exactly, and one item in each.
    #
    #   tool     what they carry and work with — a pick, a shovel, a gauge spanner
    #   gear     what they wear — protective clothing, an exoskeleton
    #   utility  the niche thing — a rebreather, a lucky amulet
    #
    # Deliberately NOT `ReactorSim::Slot`. That class exists to answer one question — when
    # nothing is fitted here, what happens to the wiring? — and nothing here has any.
    SLOTS = %i[tool gear utility].freeze

    attr_reader :id, :slot, :label, :description, :stats, :tags

    def initialize(id:, slot:, label: nil, description: nil, stats: {}, tags: {})
      @id = id.to_sym
      @slot = slot.to_sym
      raise Error, "equipment #{@id}: unknown slot #{@slot.inspect}" unless SLOTS.include?(@slot)

      @label = label || @id.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
      @description = description
      # Offsets, so an item that says nothing about a stat leaves it alone. Unlike an
      # archetype, which must declare all five, an item almost always speaks to one or two.
      @stats = stats.to_h { |k, v| [ k.to_sym, v.to_f ] }.freeze
      # Valued, and added to whatever the layers above supply. `true` for simply present.
      @tags = tags.to_h { |k, v| [ k.to_sym, v ] }.freeze
      freeze
    end

    class << self
      def register(id, **options)
        item = new(id: id, **options)

        # Ids are the address a roster uses, so a silent overwrite would mean a snapshot
        # rebuilding a different kit from the same name — the same reasoning as `Parts`.
        if @items&.key?(item.id) && !@items.fetch(item.id).equal?(item)
          raise Error, "equipment #{item.id} is already registered " \
                       "(in slot #{@items.fetch(item.id).slot})"
        end

        items[item.id] = item
      end

      def fetch(id)
        items.fetch(id.to_sym) do
          raise Error, "unknown equipment: #{id.inspect} (known: #{items.keys.join(', ')})"
        end
      end

      def key?(id) = items.key?(id.to_sym)

      def known = items.keys

      # Everything that fits one slot. The pre-match screen's list of alternatives.
      def of_slot(slot) = items.values.select { |i| i.slot == slot.to_sym }

      def reset! = @items = {}

      private

      def items = (@items ||= {})
    end
  end
end
