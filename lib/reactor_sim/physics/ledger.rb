# frozen_string_literal: true

module ReactorSim
  # The environment, and the account of everything that has left the system into it.
  #
  # The policy is "lossy is fine, silent is not" (docs/simulation_architecture.md §8). The
  # old engine destroyed ten units of steam across two ticks with nothing recording it;
  # that is the failure mode this exists to make impossible. Approximations are welcome —
  # they just have to be declared.
  #
  # Because everything that leaves is counted, two real specs become writable:
  #
  #   total_mass(state)   + ledger.mass_out   == constant
  #   total_joules(state) + ledger.joules_out == constant
  # Kept as a hash of named floats with a module of functions over it, for the same reason
  # Parcel is: it lives inside match state and is snapshotted every tick, so a class would
  # add a serialisation round-trip to maintain and nothing else. There is no behaviour here
  # that needs an object — only arithmetic and a set of names.
  module Ledger
    module_function

    def initial(ambient_k: Units::STANDARD_TEMPERATURE_K)
      { ambient_k: ambient_k,
        joules_added: 0.0,        # burners, heaters, fission — energy entering the system
        # Chemical energy released by combustion and other reactions. A separate line from
        # `joules_added` because it is a different kind of claim: parcel enthalpy does not
        # carry chemical bond energy, so a fire is genuinely a source as far as this model
        # is concerned. Declaring it keeps the books checkable without pretending we track
        # the bonds themselves.
        joules_from_reactions: 0.0,
        joules_to_ambient: 0.0,   # waste heat: radiation and convection
        # Bearing drag, belt slip, and the kinetic energy of anything that comes apart —
        # everything mechanical that is dissipated rather than delivered. A flywheel at its
        # burst speed holds megajoules and they have to land somewhere on the books.
        joules_to_friction: 0.0,
        joules_to_work: 0.0,      # useful shaft work delivered out of the operation
        joules_advected_out: 0.0, # energy carried out with departing mass
        mass_added: 0.0,          # feedstock arriving from outside the operation
        mass_vented: 0.0,         # deliberate discharge through a relief path
        mass_spilled: 0.0 }       # overflow, leak, or failure
    end

    def add(ledger, **amounts)
      amounts.reduce(ledger) do |acc, (key, value)|
        acc.merge(key => acc.fetch(key) + value)
      end
    end

    def mass_out(ledger)   = ledger.fetch(:mass_vented) + ledger.fetch(:mass_spilled)
    # Friction is counted as an exit rather than folded back in as heat. Belt slip really
    # does warm the belt, but attributing it to a particular node is a modelling choice we
    # have not made yet — and an explicit line nobody can miss beats a silent one.
    def joules_out(ledger)
      ledger.fetch(:joules_to_ambient) + ledger.fetch(:joules_advected_out) +
        ledger.fetch(:joules_to_friction) + ledger.fetch(:joules_to_work)
    end
    def mass_in(ledger)    = ledger.fetch(:mass_added)
    def joules_in(ledger)  = ledger.fetch(:joules_added) + ledger.fetch(:joules_from_reactions)

    # What the conservation specs assert is constant. A burner adds energy and a feed adds
    # mass; both are declared, so "nothing appears or disappears without being written
    # down" stays a checkable statement rather than an aspiration.
    def mass_balance(held, ledger)   = held + mass_out(ledger)   - mass_in(ledger)
    def energy_balance(held, ledger) = held + joules_out(ledger) - joules_in(ledger)
  end
end
