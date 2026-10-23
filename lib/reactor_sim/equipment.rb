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

    attr_reader :id, :slot, :label, :description, :stats, :tags, :mass_kg, :weapon

    # **What a weapon asks of the hand, and what it brings by itself.**
    #
    #   handling  a blend of stats and derived figures, like a station's `effort:` — a pick is
    #             swung, a knife is placed — whose weights may sum past one for a good weapon or
    #             short of it for a poor one
    #   edge      severity it adds to a landed blow whoever holds it: a point, a blade
    #   wounds    the hazard tags of what it leaves
    #   mass_kg   what it weighs to swing — the item's own, which is what a fight tires you by
    def self.weapon_profile(owner, spec, mass_kg: 0.0)
      handling = spec.fetch(:handling).to_h { |stat, weight| [ stat.to_sym, weight.to_f ] }.freeze
      unknown = handling.keys - Sheet::STATS - Sheet::DERIVED
      raise Error, "#{owner}: weapon handling names unknown #{unknown.join(', ')}" if unknown.any?
      raise Error, "#{owner}: weapon handling weights cannot be negative" if handling.values.any?(&:negative?)

      { handling: handling, edge: spec.fetch(:edge, 0.0).to_f,
        wounds: Array(spec.fetch(:wounds)).map(&:to_sym).freeze, mass_kg: mass_kg.to_f }.freeze
    end

    # **Bare hands, which are a poor weapon**: mostly swing, a little placement, at six tenths of
    # what a proper one gives — so somebody swinging a pick to kill is far deadlier than somebody
    # beating the brakes off a rival.
    UNARMED = weapon_profile("fists", { handling: { swing: 0.42, precision: 0.18 }, wounds: %i[impact] })

    # **`mass_kg:` is required, with no default.** What a thing weighs is half of what it costs to
    # carry it, so an item that does not say is a free upgrade by omission. Required rather than
    # defaulted means a missing one is an `ArgumentError` the moment `kit.rb` loads, which
    # `ruby -Ilib -e 'require "reactor_sim"'` already checks.
    #
    # Something genuinely weightless says `mass_kg: 0.0` and means it.
    # `weapon:` is `{ handling:, edge:, wounds: }` (`weapon_profile`). Only drawn in a brawl
    # somebody is willing to kill in.
    def initialize(id:, slot:, mass_kg:, label: nil, description: nil, stats: {}, tags: {}, weapon: nil)
      @id = id.to_sym
      @slot = slot.to_sym
      raise Error, "equipment #{@id}: unknown slot #{@slot.inspect}" unless SLOTS.include?(@slot)

      @mass_kg = mass_kg.to_f
      raise Error, "equipment #{@id}: mass_kg cannot be negative" if @mass_kg.negative?

      @label = label || @id.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
      @description = description
      # Offsets, so an item that says nothing about a stat leaves it alone. Unlike an
      # archetype, which must declare every one, an item almost always speaks to one or two.
      @stats = Sheet.offsets("equipment #{@id}", stats)
      # Valued, and added to whatever the layers above supply. `true` for simply present.
      @tags = tags.to_h { |k, v| [ k.to_sym, v ] }.freeze
      @weapon = weapon && self.class.weapon_profile("equipment #{@id}", weapon, mass_kg: @mass_kg)
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
