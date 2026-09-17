# frozen_string_literal: true

module ReactorSim
  # What a part contributes to an operation when it is fitted.
  #
  # **A part is almost never one node**, which is why this exists: the condenser is a condenser
  # *and* a hotwell return *and* two links; the feedwater set is a pump, an injector, a steam
  # pipe, five links and a lever. Keeping a part's pieces together is what makes it removable —
  # scattered across separate lists, removing one means editing all of them and hoping you found
  # them.
  #
  # Everything here is CONFIGURATION. Fragments merge once, at build, into the flat bag of nodes
  # and links `Operation` takes. No fragment, part or slot is reachable from `Tick`, `Arbiter` or
  # any node — see `operations/CLAUDE.md`.
  class Fragment
    attr_reader :nodes, :links, :thermal_links, :drive_links, :control_points, :diagnostics

    # `diagnostics:` is for parts that **are** instruments, and only those. Every other part names
    # its gauges by id (`Part#instruments`) and the operation's panel holds the definitions,
    # because the reasoning about why each gauge lies the way it does is worth keeping in one
    # readable file. A gauge that is itself the fitting has nowhere else to put its full-scale
    # reading and its lag, which are properties of that instrument rather than of the machine it
    # is screwed to.
    #
    # The definitions still live in the panel — an instrument part's builder calls a panel helper
    # and passes it figures — so the commentary stays put and only the numbers move.
    def initialize(nodes: [], links: [], thermal_links: [], drive_links: [],
                   control_points: [], diagnostics: [])
      @nodes = nodes.freeze
      @links = links.freeze
      @thermal_links = thermal_links.freeze
      @drive_links = drive_links.freeze
      @control_points = control_points.freeze
      @diagnostics = diagnostics.freeze
      freeze
    end

    def self.empty = @empty ||= new

    # Concatenation, never a hash merge: order is the whole point. The order fragments are
    # merged in decides the order levers appear on the panel, and a player learns a panel by
    # where things are. `Assembly` merges in slot-declaration order for that reason.
    def merge(other)
      Fragment.new(
        nodes: @nodes + other.nodes,
        links: @links + other.links,
        thermal_links: @thermal_links + other.thermal_links,
        drive_links: @drive_links + other.drive_links,
        control_points: @control_points + other.control_points,
        diagnostics: @diagnostics + other.diagnostics
      )
    end
  end

  # A thing you can fit into a slot.
  #
  # `provides:` is the id contract and it is load-bearing. Links, instruments and a player's
  # muscle memory all reference nodes by id, so **the id belongs to the role, not to the
  # part**: every boiler ever fitted names its drum `:boiler`, whatever else it brings. That
  # is what lets a part be swapped without rewriting the wiring around it, and it is what
  # keeps the rng stream — which is keyed by name — attached to the same role across a swap.
  #
  # `instruments:` names gauge ids rather than carrying `Diagnostic` objects. The definitions stay
  # in the operation's panel, where the reasoning about why each gauge lies can be read in one
  # sitting; the part only says which ones arrive with it. A part naming a gauge that does not
  # exist fails at build rather than reading nil forever.
  class Part
    attr_reader :id, :kind, :label, :description, :stats, :provides, :instruments, :wip

    # `wip:` is a part that is deliberately half-built — its shape is right and its cost is not
    # yet modelled. It exists as a flag rather than as a comment because the outfitting screen
    # has to be able to say so: a player choosing between two parts on their stats deserves to
    # know that one of them is currently free in a way it will not stay.
    def initialize(id:, kind:, label: nil, description: nil, stats: {},
                   provides: [], instruments: [], wip: false, &builder)
      raise Error, "part #{id.inspect} needs a builder block" unless builder

      @id = id.to_sym
      @kind = kind.to_sym
      @label = label || @id.to_s.tr("_", " ").capitalize
      @description = description
      # Presentation only. NOTHING in the simulation may read this — the moment a stat and a
      # constructor argument can disagree, they will. It exists so the outfitting screen can
      # list alternatives without instantiating every one of them.
      @stats = stats.freeze
      @provides = Array(provides).map(&:to_sym).freeze
      @instruments = Array(instruments).map(&:to_sym).freeze
      @wip = wip
      @builder = builder
      freeze
    end

    # `spec` is the chassis hash — the numbers that are still properties of the machine rather
    # than of this part. It shrinks as parts take ownership of their own figures.
    def build(spec) = @builder.call(spec)
  end
end
