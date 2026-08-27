# frozen_string_literal: true

module ReactorSim
  # What a node would like to happen this tick, declared against the previous tick's state.
  #
  # Intents are requests, never actions. A node says "I would like 2.5 kg in through my
  # inlet" and returns; settlement decides what actually moves. That separation is what
  # lets every node be evaluated independently while still conserving mass exactly.
  #
  # Both ends of a link may drive flow — a pump upstream pushing, or a pump downstream
  # pulling — so a link's desired flow is the more aggressive of the two.
  Intent = Struct.new(:draws, :pushes, keyword_init: true) do
    def initialize(draws: {}, pushes: {})
      super(draws: draws.freeze, pushes: pushes.freeze)
    end

    def self.none = new

    def draw(port_id)  = draws.fetch(port_id, 0.0)
    def push(port_id)  = pushes.fetch(port_id, 0.0)
  end

  # What settlement actually granted, handed back to the node in `apply`.
  #
  # `rejected` is the interesting field and the reason this exists: material a node could
  # not push STAYS WITH THE SENDER, and the sender is told. That is back-pressure — a
  # blocked line backs up all the way to its source instead of quietly annihilating mass,
  # which is precisely what the old engine got wrong.
  Grant = Struct.new(:received, :sent, :rejected, :joules, keyword_init: true) do
    def initialize(received: {}, sent: {}, rejected: {}, joules: 0.0)
      super(received: received.freeze, sent: sent.freeze,
            rejected: rejected.freeze, joules: joules)
    end

    def self.none = new

    # Parcels that arrived through a given inlet this tick.
    def received_at(port_id) = received.fetch(port_id, [])

    def sent_kg(port_id)     = sent.fetch(port_id, 0.0)
    def rejected_kg(port_id) = rejected.fetch(port_id, 0.0)

    def total_received = received.values.flatten.sum { |p| p.fetch(:kg) }
    def total_sent     = sent.values.sum
    def total_rejected = rejected.values.sum

    def blocked? = total_rejected > Parcel::EPSILON
  end
end
