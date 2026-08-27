I think it better to focus on an even simpler first operation (chemical vats will force us to figure out chemical reactions in more detail than I want to right now -- it will be next on deck)

If we can support both atmospheric and high pressure engines with the same operation just by swapping in and out different parts, then we know our architecture is going to be incredibly well-suited to the task of easily building out operations.

Would like to support Watts-style atmospheric engines and early high pressure Trevithick high pressure engines as well as a variety of fuel sources.

Going to need to model the generation of heat from burning fuel - air mixtures (probably the most common combustion reaction and one we need to get right early). This is what powers the boiler.

Going to need to likely have some sort of necessary mechanisms list for key mechanisms so that a design will always be capable of generating power (so the boiler requires you have a water supply and a fuel bunker of some kind, for example). Not something we need to plan for right now as we just need to get some prototypes up, but something to consider for when we add customization.

We are going to need to add a physics package for modelling centrifugal and/or linear kinetic forces (would need it for steam turbines etc later anyways) rather than purely thermal ones as most parts in a steam engine are based on kinetic interactions. We need to also make sure we can inflict increasing wear on a given mechanism if it exceeds some threshold (as some steam engines were known for running fast and cast iron flywheels would blow apart if their power sink was taken away or decoupled suddenly or the engine ran too fast as cast iron had weak tensile strength). Can be super simple as we need, but it's going to be a common type of mechanism (every turbine, water wheels, windmills, etc).

We are going to need special kinds of control points that act as work stations so that minions can be shovelling coal or stacking wood/stoking fires. Our control point system should be able to model this adequately. This method of transport will also need to be handled by our conduits. Should be totally fine (can just have a conduit that has solid coal/wood transit through it based on the effort of the workers on the control points attached to it), but it will be a good gut check for the system flexibility.

Going to need to add in probablistic accidents. Driven deterministically of course, but there needs to be a chance when a clumsy ogre or shifty kobold is working around fast-moving exposed machinery that they suffer an injury. Some control points may expose workers to danger even if the machinery is not degraded.

Core components:

Fuel Bunker
* Stores whatever the fuel is for the boiler (I want a range from wood to coal to fuel oil)

Water Supply
* Stores extra water that can be fed into the boiler (or onto the working vessel if we wanted to support a Newcomen-style hot-cold cycle as a more primitive predecessor to the watt condenser design)

Boiler
* Burns fuel to vaporize water

Cylinder
* Intakes steam, moves the piston to generate work
* Specifics vary based on the design

Condenser (only on the non cylinder-cooled designs)
* Intakes steam from the cylinder and cools it
* Likely sits in a vat of water that may or may not be recirculated (perhaps an inattentive player could let it get too hot and lose efficiency?)

Flywheel
* Spun by piston action via the crankshaft (crankshaft might benefit from being a mechanism or conduit or its behaviour could be modeled by the combination of cylinder / flywheel, whatever is cleanest and best)
* converts the linear piston motion into rotational energy (we dont need to model this -- just need a coefficient to represent the loss of energy in the gearing conversion or we could have things like our belts, gearing, and axles be represented as conduits where it makes sense)

Various different Governors
* used to stop the engine ripping itself apart (flywheels often exploded which is why we really need that force/strain modeling) if a sudden disconnection occurs
* different designs get mounted on different points and work different ways
* Some infamous early governors could have drive belts or pins snap and would fail-on, throttling open the steam intakes into the cylinder to maximum and basically guaranteeing a steam explosion unless the attendants save it (this is going to be some good gameplay if we get it right)

There should be other mechanisms to account for common and interesting failure modes if the above are not sufficient.
* Hot Box failures
  * Babbitt bearings for axles generated tons of friction as soon as oil cups ran dry or got dirty
  * The softer metals in the bearing would get red hot almost immediately, melting and seizing, which would inevitably propagate damage throughtout the system
* Axle and shaft failures
  * main engine crankshafts were known for getting stress fractures and eventually snapping in half catastrophically
* Hydro locking
  * if the boiler was overfilled or gets too frothy, water makes its way into the cylinder
  * water is incompressible, so the flywheel would slam the cylinder head into the pocket of water if it got too large and just obliterate the axles or blow the bottom/top off the cylinder
* Since these steam engines might just output drive shaft power as their output and end of their chain (players can easily graft on an electric-generating coupling at the end of the chain if the matchmaker/lobby demands electrical rather than kinetic output), I am not interested in modelling the most common failures in factories which were the actual tertiary belts/chains snapping (as in the ones powering the work station in a factory). I am however interested in failure modes internal to the engine system, such as belts or chains or manifolds failing that are used to control or power parts of the engine itself.
