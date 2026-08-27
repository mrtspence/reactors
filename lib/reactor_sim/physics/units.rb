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

    module_function

    def c_to_k(celsius) = celsius - ABSOLUTE_ZERO_C
    def k_to_c(kelvin)  = kelvin + ABSOLUTE_ZERO_C
    def kpa(pascals)    = pascals / 1000.0
    def kilo(value)     = value / 1000.0
  end
end
