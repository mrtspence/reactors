# frozen_string_literal: true

module ReactorSim
  # SI everywhere inside the simulation. Conversion happens in the display layer and
  # nowhere else (docs/simulation_architecture.md §2).
  #
  # Two of these choices are load-bearing rather than stylistic:
  #
  #   * Energy is stored, temperature is derived. Mixing two parcels is then addition
  #     rather than a weighted average, so it conserves energy exactly instead of
  #     approximately, and phase change is a subtraction.
  #   * Pressure is always derived, never accumulated. A stored pressure drifts away from
  #     the state that causes it and nothing tells you.
  module Units
    ABSOLUTE_ZERO_C = -273.15
    STANDARD_TEMPERATURE_K = 293.15  # 20 °C
    STANDARD_PRESSURE_PA   = 101_325.0
    GAS_CONSTANT           = 8.314462618 # J/(mol·K)
    GRAVITY_M_PER_S2       = 9.80665     # what makes a chimney draw and a header tank feed
    # W/(m²·K⁴). What makes a bright fire worth more than a merely hot one, and what stops a
    # seized bearing climbing forever — see docs/design_sketches/radiation.md.
    STEFAN_BOLTZMANN       = 5.670374419e-8
    # kg/m³ at standard temperature and pressure. For sizing a positive-displacement intake,
    # where what matters is roughly how much air a swept volume holds rather than its exact
    # state — a node that needs the real figure derives it from its own contents.
    AIR_DENSITY_KG_PER_M3  = 1.204

    module_function

    def c_to_k(celsius) = celsius - ABSOLUTE_ZERO_C
    def k_to_c(kelvin)  = kelvin + ABSOLUTE_ZERO_C
    def kpa(pascals)    = pascals / 1000.0
    # For the derived quantities that are already fractions — a level, an occupancy, an
    # integrity — so a gauge can show them the way an operator reads them.
    def percent(fraction) = fraction * 100.0
    def kilo(value)     = value / 1000.0
  end
end
