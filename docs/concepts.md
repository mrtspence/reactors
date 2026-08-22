Multiplayer game where players take on the role of an overseer for various different industrial processes.

Light hearted fantasy setting with comedic elements. Nothing serious in tone.

Players must take on different roles in the supply chain to gather and/or produce resources. They all gain a portion of all resources produced and also some reward proportional to their own performance. Will spend these resources on upgrades to their various components.

Game will focus heavily on avoiding Incidents, which will be easier said than done when you might be doing something like harnessing vengeful ghosts to drive a turbine, using demons to work in a coal mine, or trying to manage an RBMK nuclear reactor with ogres in the control room.

## Supply Chain
A match -- what all the player's different operations chain together to form. Sorted by tiers with higher tiers involving more complex and powerful operations.

## Operations:
What 'thing' a given overseer is managing.

I want these to have a ton of complexity under the hood -- I want something approaching a simulation as far as underlying complexity -- but with the player exposed to only some portion of it by limiting their agency to a few different control points and diagnostics. So the underlying machinery can be really complex, but their points of control over that underlying system will be the main game design lever to manage perceived complexity. So confident and experienced players can try and manage a nuclear reactor (which will have dozens of control points) and newer players can stick to systems with fewer.

### Generators
The first step in any given chain. All processes later in the chain require power.

* The Wheel
  * Huge hamster wheel thing powered by volunteers

* Chemical Vats
  * A series of different vats filled with different chemicals that can be combined in a central reaction vessel to creates heat and expansion that powers a turbine

* RBMK Nuclear Reactor
  * A simplified (but still super complex) version of the real life reactor



### Extractors
Things like mines

* Mines for various dangerous ores in additional to coal and others

### Processors
Things like refineries

* Pulverizer setup that uses input power to lift huge piles to smash up input resources



### End Uses
Various different final consumers of inputs

* Giant power hammer setups to make huge industrial parts


## Components
Each component represents some part of an operation.

### Mechanism
These represent the actual machinery of a given operation. Many can be swapped with alternative versions, upgraded, etc.

Each has some sort of internal state (wall health, temperature, etc).

They take inputs, perform some sort of operation on them, and then have outputs. Will need to categorize them based on inputs and outputs (probably going to need a json structure to avoid a lot of expensive joins and because we need easy serializability) -- any mechanism that can handle all the inputs and outputs at a given node should be compatible so that people can spend lots of time tinkering with their systems as they please.

Mechanisms are arranged into a chain -- basically a pipeline. When a tick is evaluated, the first mechanism resolves, then the second, then the third, and so on.

Each time a mechanism is evaluated, there is a chance of a mishap. Will vary based on the type of mechanism, its internal state, and the characteristics of the operating Minion.

### Control Points
These are the actual levers players interact with in order to control their Operation.

Each will have to be staffed by a Minion, who will have different competencies (a stone golem might be great for pushing your mine carts but might be ill-suited for managing a control panel).

A prime source for upgrades and sidegrades (trade efficiency for reliability or easy of use by certain Minions).

Attached to a mechanism and can govern one or more inputs or outputs in that given mechanism. Not all mechanisms get a control point.

### Diagnostics
These are the windows into the underlying mechanics of a player's Operation. These are visible directly to the player.

Also a great source for upgrades and sidegrades (reliability, reporting delays, wider ranges so gauges dont get maxed out).

Some are attached to mechanisms directly while some give system-wide information.



## System Architecture
Main client facing needs to be ruby on rails (ideally everything will be) for speed of development. All partials fully use viewcomponents, I18n, turbo (including morphics when we can get away with it), the unified activesupport::error reporter, tailwind -- the full most modern stack.

This game should be more-or-less realtime. I am open to being convinced on the architecture, but a lot of the fun will come from having to make decisions about complex systems while under pressure, so that part is non-negotiable.

Need to be able to spin up instances pretty quickly so that a given match doesn't affect any others -- can start out with just one engine instance but I need the ability to scale it later once prototyping is done (K8s).

May want to basically instantiate all the objects on the engine instance in memory and have it manage state as it goes. The engine may want to use a redis database to handle restoring state if it goes down for whatever reason (so that people don't lose a whole match due to a transient error).

To keep the engine super light and fast, we may want to separate the client/main layer out (the engine doesn't need to do anything but handle data -- partials, css, all that other stuff can go). To keep the data interchange easy, we want to make sure all the engine-related classes are json serializable and are a shared interface between the components to make sure they never drift.

During a match, the engine will poll the client and ask it to dispatch snapshots of current match state (such as what each control point has selected) to the engine instance every second. The engine would do the same -- sending data back to the client to inform it of current match state.

The client only needs to keep track of displaying data to the user and sending input to the engine and the engine just needs to run the many different pipelines in the match and track match state to relay back to the client for display. Let's start with just http as our protocol but maybe can move to websockets later if we need it to be faster.

Likely going to want an event queue in between the client and the engine layer. This should help smooth out the experience and prevent intermittent connection issues from ruining the game state. By having the engine be the only manager of state, and by having it initiate both the population of client-dispatched events and its consumption of those events only when it is ready (it will be probably a constantly running state machine that checks for updates when it is done computing and after our tick interval expires -- we start with once a second and see how that plays), we should be able to keep it durable and scaleable.

Going to use turbo streams to have the client receive api endpoint updates from the engine and update state accordingly.

We can dispatch end-of-match updates to the main postgres database at the end of the match (can start with just having that be the client database but if we need to split it out to a match client and general client to keep the match client super responsive, we can). Since players start with a fresh instance of their operations at the start of each match, the only permanent data that matters is resources gained and other progression mechanics (achievements for triggering certain occurrences etc) so this can just be done atomically at the end of a match.
