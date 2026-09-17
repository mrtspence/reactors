# frozen_string_literal: true

module ReactorSim
  # A permanent upgrade to one individual. Layer three of the four in
  # `content/archetypes/races.yml`.
  #
  # **The difference from equipment is permanence, and it is the whole of the difference.** A
  # certificate cannot be swapped between matches, cannot be handed to somebody else, and
  # cannot be lost in an accident — once Jim has done his hot-work ticket, Jim has done it.
  # That is why the two are separate kinds rather than one with a flag: a player reasons about
  # them completely differently, and the pre-match screen shows only one of them.
  #
  # Mechanically it contributes exactly what an item does — stat offsets and tags — so the two
  # fold through the same arithmetic. Merge adds, use multiplies.
  #
  # See docs/design_sketches/minions.md §3.
  class Training
    attr_reader :id, :label, :description, :stats, :tags

    def initialize(id:, label: nil, description: nil, stats: {}, tags: {})
      @id = id.to_sym
      @label = label || @id.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
      @description = description
      @stats = stats.to_h { |k, v| [ k.to_sym, v.to_f ] }.freeze
      @tags = tags.to_h { |k, v| [ k.to_sym, v ] }.freeze
      freeze
    end

    class << self
      def register(id, **options)
        course = new(id: id, **options)

        if @courses&.key?(course.id) && !@courses.fetch(course.id).equal?(course)
          raise Error, "training #{course.id} is already registered"
        end

        courses[course.id] = course
      end

      def fetch(id)
        courses.fetch(id.to_sym) do
          raise Error, "unknown training: #{id.inspect} (known: #{courses.keys.join(', ')})"
        end
      end

      def key?(id) = courses.key?(id.to_sym)

      def known = courses.keys

      def reset! = @courses = {}

      private

      def courses = (@courses ||= {})
    end
  end
end
