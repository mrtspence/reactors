# frozen_string_literal: true

module ReactorSim
  # The catalogue of equipment and training. Registrations only — the machinery is in
  # `Equipment` and `Training`, and this file is the data, the way `operations/steam_engine/
  # parts.rb` is data for `Parts`.
  #
  # **Kept deliberately small at this stage.** There is one machine and one hazard model, so a
  # catalogue of forty items would be forty guesses. What is here covers the three slots, the
  # two stats anything reads today, and the tags the Danger Check and the future mine both
  # need — enough to test the mechanism without pretending to a tech tree that has not been
  # designed. See docs/design_sketches/minions.md §7.
  module Kit
    # --- tools ---------------------------------------------------------------
    #
    # What they carry and work with.

    Equipment.register(:stokers_shovel, slot: :tool, label: "Stoker's Shovel",
                       description: "A long-handled shovel with a wide blade.",
                       stats: { strength: 0.2 },
                       # The sketch's worked example: a shovel should be a large bonus to
                       # moving coal specifically, rather than a small bonus to everything.
                       tags: { shovelling: 0.5 })

    # The shovel's opposite number, and the reason `aided_by:` is per station rather than per
    # job: the same person is better at one of the two depending on what is in their hand.
    Equipment.register(:oil_can, slot: :tool, label: "Long-spouted Oil Can",
                       description: "A pressed-tin can with a spout long enough to reach a " \
                                    "moving journal without reaching into it.",
                       stats: { dexterity: 0.2 },
                       tags: { oiling: 0.5 })

    Equipment.register(:gauge_spanner, slot: :tool, label: "Gauge Spanner",
                       description: "A fitter's spanner, sized for boiler mountings.",
                       stats: { dexterity: 0.15 },
                       tags: { fitting: 0.3 })

    # The sketch's other worked example, and the one that shows a tag cutting both ways: the
    # candle is what lets you see down a drift, and it is what ignites the gas in one.
    Equipment.register(:crude_miners_tools, slot: :tool, label: "Crude Miner's Tools",
                       description: "A stone pick and a tallow candle.",
                       stats: { strength: 0.05 },
                       tags: { mining_effectiveness: 0.25, darkvision: 0.1, open_flame: true })

    # --- gear ----------------------------------------------------------------
    #
    # What they wear.

    Equipment.register(:leather_apron, slot: :gear, label: "Leather Apron",
                       description: "Heavy hide, scorched down one side.",
                       stats: { endurance: -0.05 },
                       tags: { heat_resistance: 0.3 })

    # **The first item in the catalogue with a real downside rather than a rounding error**, and
    # the reason `endurance` is worth being a stat. It is the best heat protection here and it is
    # a quarter of somebody's stamina — so it belongs on whoever is working a hot station lightly,
    # and ruins whoever is shovelling in it. That is a loadout decision rather than a strict
    # upgrade, which is what the three slots were built to express.
    Equipment.register(:asbestos_suit, slot: :gear, label: "Asbestos Suit",
                       description: "Stifling, rigid, and proof against very nearly anything " \
                                    "the firebox can do to a person.",
                       stats: { dexterity: -0.2, endurance: -0.25 },
                       tags: { heat_resistance: 0.7, scald_resistance: 0.5, burn_resistance: 0.6 })

    Equipment.register(:fettlers_gloves, slot: :gear, label: "Fettler's Gloves",
                       description: "Thick enough to hold hot iron, clumsy with a valve.",
                       stats: { dexterity: -0.1, endurance: -0.05 },
                       tags: { heat_resistance: 0.45 })

    Equipment.register(:oilskin_coat, slot: :gear, label: "Oilskin Coat",
                       description: "Sheds water, steam and most of what a boiler throws.",
                       tags: { heat_resistance: 0.2, scald_resistance: 0.35 })

    # --- utility -------------------------------------------------------------
    #
    # The niche thing, and the slot most likely to be left empty.

    Equipment.register(:lucky_amulet, slot: :utility, label: "Lucky Amulet",
                       description: "It has not failed yet, which is the whole argument for it.",
                       # A small, genuine reduction in how often things go wrong. `clumsy` is
                       # additive and signed, so a negative value is exactly "less clumsy".
                       tags: { clumsy: -0.15 })

    Equipment.register(:ear_defenders, slot: :utility, label: "Ear Defenders",
                       description: "Wax and wadding. Quieter, and harder to shout at.",
                       stats: { intelligence: 0.1, charisma: -0.15 })

    Equipment.register(:hand_lamp, slot: :utility, label: "Hand Lamp",
                       description: "An oil lamp on a bail. Better light, same open flame.",
                       tags: { darkvision: 0.35, open_flame: true })

    # --- training ------------------------------------------------------------
    #
    # Permanent, per individual, and never swapped.

    Training.register(:hot_work_ticket, label: "Hot Work Ticket",
                      description: "Certified to work beside live steam and open fire.",
                      stats: { toughness: 0.2 },
                      tags: { heat_resistance: 0.2, licensed: true })

    Training.register(:boilermans_course, label: "Boilerman's Course",
                      description: "Reads a water glass properly, and knows why it lies.",
                      stats: { intelligence: 0.25 },
                      tags: { practised: true })

    Training.register(:steady_hands, label: "Steady Hands",
                      description: "A year of not dropping things.",
                      stats: { dexterity: 0.2 },
                      tags: { clumsy: -0.2 })

    Training.register(:pit_sense, label: "Pit Sense",
                      description: "Knows when a working is about to go, and moves first.",
                      stats: { toughness: 0.1 },
                      tags: { hazard_sense: 0.3 })
  end
end
