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
  #
  # **Every entry declares `mass_kg:`, and the field is required so that it has to.** What a thing
  # weighs is half of what it costs to carry it — `Burden` reads the total as `worn_kg` and charges
  # it against pace and wind — so an item that said nothing would be a free upgrade by omission.
  # Courses pass `0.0` and mean it.
  #
  # Two consequences worth noticing in the figures below, because both are now design rather than
  # flavour: **the proper miner's tools are LIGHTER than the crude ones** (better steel, less of
  # it), so the upgrade is better twice over; and **the rescue apparatus is the heaviest thing
  # here**, which is the shape of a rescue — the one person who can reach a casualty in bad air is
  # also the slowest to carry them out.
  module Kit
    # --- tools ---------------------------------------------------------------
    #
    # What they carry and work with.

    Equipment.register(:stokers_shovel, slot: :tool, label: "Stoker's Shovel",
                       description: "A long-handled shovel with a wide blade.",
                       mass_kg: 3.5,
                       stats: { strength: 0.2 },
                       # The sketch's worked example: a shovel should be a large bonus to
                       # moving coal specifically, rather than a small bonus to everything.
                       tags: { shovelling: 0.5 })

    # The shovel's opposite number, and the reason `aided_by:` is per station rather than per
    # job: the same person is better at one of the two depending on what is in their hand.
    Equipment.register(:oil_can, slot: :tool, label: "Long-spouted Oil Can",
                       description: "A pressed-tin can with a spout long enough to reach a " \
                                    "moving journal without reaching into it.",
                       mass_kg: 1.0,
                       stats: { dexterity: 0.2 },
                       tags: { oiling: 0.5 })

    Equipment.register(:gauge_spanner, slot: :tool, label: "Gauge Spanner",
                       description: "A fitter's spanner, sized for boiler mountings.",
                       mass_kg: 0.8,
                       stats: { dexterity: 0.15 },
                       tags: { fitting: 0.3 })

    # The sketch's other worked example, and the one that shows a tag cutting both ways: the
    # candle is what lets you see down a drift, and it is what ignites the gas in one.
    Equipment.register(:crude_miners_tools, slot: :tool, label: "Crude Miner's Tools",
                       description: "A stone pick and a tallow candle.",
                       # Heavier than the proper kit as well as worse: a stone head needs more of
                       # itself to do less. The upgrade is lighter, which is now a second reason
                       # to want it.
                       mass_kg: 4.0,
                       stats: { strength: 0.05 },
                       tags: { mining_effectiveness: 0.25, darkvision: 0.1, open_flame: true })

    # **The gate is multiplied, so a crude kit is 0.25 × 0.1 and genuinely hopeless.** That is
    # the design — a hewer with a stone pick and a candle is not a slightly worse hewer — but it
    # needs somewhere to go, and this is it: a proper pick wins four times the coal and the
    # light stops being the thing holding you back.
    Equipment.register(:miners_tools, slot: :tool, label: "Miner's Tools",
                       description: "A steel pick, wedges, and a lamp worth the name.",
                       mass_kg: 3.0,
                       stats: { strength: 0.1 },
                       tags: { mining_effectiveness: 0.8, darkvision: 0.5, open_flame: true })

    # **What makes a casualty somebody else's problem rather than nobody's.** `Burden` reads
    # `stretcher` as an aid to the lift limit, so this is what lets a hand carry somebody their own
    # size and an elf carry a man at all.
    #
    # **A tool, because it occupies hands rather than a face.** It takes the pick's place, so a
    # stretcher-bearer wins no coal — which is the right cost and a better one than competing with
    # the lamp would be: a rescuer cannot give up light or air, and *can* give up working.
    Equipment.register(:stretcher, slot: :tool, label: "Stretcher",
                       description: "Canvas and two ash poles. Folds, and still catches on " \
                                    "every prop between here and the shaft.",
                       mass_kg: 6.0,
                       tags: { stretcher: 0.5 })

    # --- gear ----------------------------------------------------------------
    #
    # What they wear.

    Equipment.register(:leather_apron, slot: :gear, label: "Leather Apron",
                       description: "Heavy hide, scorched down one side.",
                       mass_kg: 2.5,
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
                       # Rigid and heavy, so it now costs pace as well as stamina — which is the
                       # third face of the same decision rather than a new one.
                       mass_kg: 9.0,
                       stats: { dexterity: -0.2, endurance: -0.25 },
                       tags: { heat_resistance: 0.7, scald_resistance: 0.5, burn_resistance: 0.6 })

    Equipment.register(:fettlers_gloves, slot: :gear, label: "Fettler's Gloves",
                       description: "Thick enough to hold hot iron, clumsy with a valve.",
                       mass_kg: 0.4,
                       stats: { dexterity: -0.1, endurance: -0.05 },
                       tags: { heat_resistance: 0.45 })

    Equipment.register(:oilskin_coat, slot: :gear, label: "Oilskin Coat",
                       description: "Sheds water, steam and most of what a boiler throws.",
                       mass_kg: 2.0,
                       tags: { heat_resistance: 0.2, scald_resistance: 0.35 })

    # --- utility -------------------------------------------------------------
    #
    # The niche thing, and the slot most likely to be left empty.

    Equipment.register(:lucky_amulet, slot: :utility, label: "Lucky Amulet",
                       description: "It has not failed yet, which is the whole argument for it.",
                       mass_kg: 0.1,
                       # A small, genuine reduction in how often things go wrong. `clumsy` is
                       # additive and signed, so a negative value is exactly "less clumsy".
                       tags: { clumsy: -0.15 })

    Equipment.register(:ear_defenders, slot: :utility, label: "Ear Defenders",
                       description: "Wax and wadding. Quieter, and harder to shout at.",
                       mass_kg: 0.3,
                       stats: { intelligence: 0.1, charisma: -0.15 })

    Equipment.register(:hand_lamp, slot: :utility, label: "Hand Lamp",
                       description: "An oil lamp on a bail. Better light, same open flame.",
                       mass_kg: 1.2,
                       tags: { darkvision: 0.35, open_flame: true })

    # **The one that does not carry `open_flame`**, which is the entire point of it and the
    # reason it was invented. A gauze lamp gives less light than the oil lamp it replaces and
    # gives it without setting the district off — and it is what makes the flame cap readable,
    # because the cap is the thing burning inside the gauze.
    Equipment.register(:davy_lamp, slot: :utility, label: "Davy Lamp",
                       description: "Flame in a wire gauze. Dimmer, and it will not fire the gas.",
                       mass_kg: 1.8,
                       tags: { darkvision: 0.25, firedamp_resistance: 0.2 })

    # **The only thing that lets anybody walk INTO bad air**, and the reason a rescue is a race
    # rather than a decision. `respirator_air` is the whole cost of it: forty minutes on the
    # clock, spent every tick the air is foul whether or not it was needed that tick, and worth
    # nothing at all once it is gone.
    Equipment.register(:rescue_apparatus, slot: :utility, label: "Rescue Apparatus",
                       description: "Compressed air on a harness. Forty minutes, then nothing.",
                       # **The heaviest thing in the catalogue, and it has to be.** A rebreather
                       # set was fifteen kilograms, and the whole shape of a rescue is that the
                       # one person who can reach the casualty is also the one slowest to carry
                       # them out. Lightening this is a real upgrade for a later tier.
                       mass_kg: 14.0,
                       stats: { strength: -0.1, dexterity: -0.15 },
                       tags: { respirator: 0.85, respirator_air: 9_600 })

    # --- training ------------------------------------------------------------
    #
    # Permanent, per individual, and never swapped.
    #
    # **Every course declares `mass_kg: 0.0`, and the field is required so that it has to.**
    # Learning weighs nothing — but that is a claim worth making once per course rather than
    # assuming across a whole layer, and a certificate that one day arrives with a brass helmet
    # then has an honest place to put it.

    Training.register(:hot_work_ticket, label: "Hot Work Ticket",
                      description: "Certified to work beside live steam and open fire.",
                      mass_kg: 0.0,
                      stats: { toughness: 0.2 },
                      tags: { heat_resistance: 0.2, licensed: true })

    Training.register(:boilermans_course, label: "Boilerman's Course",
                      description: "Reads a water glass properly, and knows why it lies.",
                      mass_kg: 0.0,
                      stats: { intelligence: 0.25 },
                      tags: { practised: true })

    # **The counterplay to a certificated post**, and the reason `requires:` is a cost rather
    # than a punishment. A winding engineman holds men's lives on a rope and the job was
    # certificated for exactly that reason; without the ticket a hand is twice as far out of
    # their depth at the lever, and the answer the player can buy is this.
    Training.register(:winding_ticket, label: "Winding Ticket",
                      description: "Certificated to work a winding engine with men on the rope.",
                      mass_kg: 0.0,
                      stats: { intelligence: 0.1 },
                      tags: { certificated: true, practised: true })

    Training.register(:steady_hands, label: "Steady Hands",
                      description: "A year of not dropping things.",
                      mass_kg: 0.0,
                      stats: { dexterity: 0.2 },
                      tags: { clumsy: -0.2 })

    # The training-layer answer to a burden, where the stretcher is the equipment one. `Burden`
    # reads both as aids to the lift limit, so a trained bearer needs no stretcher to move a man
    # his own size — and unlike the stretcher, this leaves his hands free for a pick.
    Training.register(:strong_back, label: "Strong Back",
                      description: "A year of carrying things that did not want to be carried.",
                      mass_kg: 0.0,
                      stats: { toughness: 0.1 },
                      tags: { strong_back: 0.35 })

    Training.register(:pit_sense, label: "Pit Sense",
                      description: "Knows when a working is about to go, and moves first.",
                      mass_kg: 0.0,
                      stats: { toughness: 0.1 },
                      tags: { hazard_sense: 0.3 })
  end
end
