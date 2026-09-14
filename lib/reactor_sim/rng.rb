# frozen_string_literal: true

module ReactorSim
  # SplitMix64. Deliberately hand-rolled rather than using Ruby's Random:
  #
  #   * State is a single 64-bit integer, so it serialises into a snapshot exactly
  #     and restores exactly. Ruby's Random needs marshal_dump and ties us to a
  #     particular Ruby's internals.
  #   * The algorithm is fully specified in integer arithmetic, so a snapshot taken
  #     on one machine replays identically on another.
  #
  # Each mechanism and diagnostic gets its OWN stream via .stream, so draws do not
  # depend on the order mechanisms are evaluated in. That is what lets the tick be
  # genuinely order-independent (docs/architecture.md §4).
  class Rng
    MASK   = 0xFFFF_FFFF_FFFF_FFFF
    GOLDEN = 0x9E37_79B9_7F4A_7C15

    # FNV-1a 64. String#hash is randomised per process and must never be used here.
    FNV_OFFSET = 0xCBF2_9CE4_8422_2325
    FNV_PRIME  = 0x0000_0100_0000_01B3

    attr_reader :state

    def initialize(state)
      @state = state & MASK
    end

    # Derive an independent, reproducible stream for a named component.
    def self.stream(seed, name)
      h = FNV_OFFSET
      name.to_s.each_byte { |b| h = ((h ^ b) * FNV_PRIME) & MASK }
      new(seed ^ h)
    end

    def next_u64
      @state = (@state + GOLDEN) & MASK
      z = @state
      z = ((z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9) & MASK
      z = ((z ^ (z >> 27)) * 0x94D0_49BB_1331_11EB) & MASK
      z ^ (z >> 31)
    end

    # Uniform in [0.0, 1.0). Top 53 bits give an exactly-representable double.
    def float
      (next_u64 >> 11) * (1.0 / (1 << 53))
    end

    def between(low, high)
      low + (float * (high - low))
    end

    # Symmetric uniform noise in [-magnitude, +magnitude].
    #
    # Uniform rather than Gaussian on purpose: Box-Muller needs Math.log and Math.cos,
    # and transcendentals are the one place IEEE 754 results can differ across
    # platforms. For gauge jitter uniform reads identically anyway.
    def noise(magnitude)
      between(-magnitude, magnitude)
    end

    def to_h = { state: @state }

    def self.from_h(hash) = new(hash.fetch(:state))
  end
end
