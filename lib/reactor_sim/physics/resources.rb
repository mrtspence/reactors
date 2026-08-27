# frozen_string_literal: true

module ReactorSim
  # Substance behaviour: phase change and chemistry.
  #
  # These are pure modules — parcels in, parcels out, nothing mutated. Taking a state and
  # returning a new one has identical power to mutating one, and keeps every invariant.
  #
  # The substance *data* lives in YAML (see Content); only the physics lives here. Adding a
  # coolant is a file. Adding a new kind of physics is a module.
  module Resources
  end
end
