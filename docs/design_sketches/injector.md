# The injector: feedwater that costs steam instead of heat

> **Status: chosen and being built, 2026-09-10.** The alternatives were weighed against a
> measurement rather than in the abstract — see §2. This sketch records why, because the
> tempting cheap version is wrong in a way that is invisible until the feed lever stops being
> a decision.

## 1. What forced it

Hydraulic lock has a proven mechanism and **no reachable operating point**. Measured across the
feed lever at throttle 60:

| feed | raw fill | boiler T | rpm | kW | peak occupancy |
|---|---|---|---|---|---|
| 40 | 56.0% | 431.7 K | 166.2 | 350.0 | 0.163 |
| 60 | 69.2% | 407.6 K | 93.3 | 75.0 | 0.154 |
| 80 | 81.0% | 388.8 K | 38.1 | 6.1 | 0.322 |
| 100 | 91.6% | 376.3 K | **0.8** | **0.0** | 0.323 |

Every route to a high glass runs the feed pump; the pump's 293 K water puts the fire out; and a
dead fire produces no pressure transient for the water to swell on. **The hazard and its
precondition are mutually exclusive**, which is the same shape of defect as the old
`lock_omega` band and needs the same kind of answer: find the physics that is missing, not a
threshold to move.

Held at 370 K instead, with nothing else changed, the boiler stays at **432 K at every feed
setting** and the engine keeps turning — and a regulator slam at feed 80 reaches occupancy
**3.346** and destroys the cylinder. So feedwater temperature is the whole of it.

## 2. Why not simply warm the tank

Because it is free, and the thing being modelled is not.

An injector is **thermally almost perfect and that is not its cost.** Every joule the live steam
carries goes into the feedwater and straight back into the boiler it came from, so as a
feedwater heater it loses essentially nothing. What it actually costs is **steam that could have
gone to the cylinder** — the working fluid is spent pumping instead of pushing, and the drum's
steam space is drawn down to do it.

Warming the supply tank reproduces the temperature and deletes the trade. The feed lever would
become a pure benefit up to the flooding point, which is exactly the "floor with no ceiling"
problem that priming was introduced to fix. So: model the machine.

## 3. The shape, and why it needs no new node class

An injector is a place where live steam and cold water meet and leave together. That is a
**holder**, and this codebase already condenses steam into water it is mixed with — the
saturation solve does it generically, driven by pressure, with latent heat exact by
construction.

```
boiler.injector_out ─[injector_steam, lever :feed]─➤ injector.steam_in
supply.out ──────────[feed_pump,      lever :feed]─➤ injector.water_in
                                       injector.out ─➤ boiler.feed_in
```

`injector` is a small `Vessel`. Nothing else is new: the steam condenses because a small vessel
full of cold water is below its saturation pressure, the latent heat lands in the water because
`h = c·T + h_f` makes that exact, and the hot mixture goes to the drum. **No new physics and no
new class** — the same test the `Obstructs` concern had to pass.

Both conduits carry the `:feed` lever, so one control opens the water and the steam together, in
the ratio the geometry fixes. That ratio is the design number: roughly **1 kg of steam to 9 of
water**, which lands the delivery near 360 K.

- Steam side rate-driven, not pressure-driven. An injector is a fixed-geometry nozzle; giving it
  a conductance would be a second number for one restriction, which this engine has already got
  wrong twice.
- Steam drawn from its **own port**, not from `steam_out`. A separate pipe from the steam space
  is what the machine has, and it keeps the drum's carryover affinity — which is keyed to
  `steam_port` — off the injector feed, so the injector is fed dry steam rather than priming
  water.

## 4. What this is expected to cost the player

Working the feed pump now draws on the steam space, so **filling the boiler and pulling hard
compete for the same steam.** That is the trade the lever has been missing: today it is free
until it drowns the fire, and the failure is thermal and abrupt. After this it should be
gradual, legible on the pressure gauge, and a decision.

**It also opens the priming envelope**, which is the point: a hot boiler at a high glass with a
driver who opens up sharply is the historical predicament and it has been unreachable.

## 5. What to check, because each has bitten already

- **Boiler pressure must not become unstable.** A new steam draw is a new coupling on the drum.
- **The injector must not become a pressure vessel.** It is small and its contents want to be
  liquid; if the steam does not condense it will pack.
- **The feed band must widen**, not merely move. If the cliff at feed ~45 simply shifts, the
  mechanic has not landed.
- **Normal running must be recognisable.** The feed sweep is the reference, and every balance
  number in the engine was measured against a cold feed.
- Mass and energy conservation, which is where a two-inlet mixing node would show a mistake.

## 6. Built, measured — and it does not open the envelope on its own

**It works as designed.** Feedwater arrives at **357 K** against the 360 K the 1:9 ratio was
sized for, the steam condenses without packing the vessel, conservation holds across the new
loop, and normal running is untouched: feed 40 gives 165.4 rpm and 345.1 kW against 166.2 and
350.0 before.

**It does not make priming reachable**, and the reason is worth keeping.

| feed | raw fill | boiler T | boiler kPa | inj T | rpm | kW |
|---|---|---|---|---|---|---|
| 0 | 40.0% | 432.3 K | 608.0 | 293.2 K | 168.0 | 357.2 |
| 40 | 56.0% | 431.4 K | 594.5 | 357.8 K | 165.4 | 345.1 |
| 80 | 81.0% | 388.6 K | 170.4 | 356.1 K | 37.4 | 5.8 |
| 100 | 87.0% | 377.7 K | 118.3 | 337.2 K | 1.0 | 0.0 |

The controlled experiment in §1 warmed the tank and gave hot water **free**, so the boiler could
be overfilled with no penalty and the fire stayed lit. This charges for it — about 0.28 kg/s of
steam at full feed against a drum making roughly 1 kg/s — so overfeeding still costs, and it
should.

And overfeeding is unavoidable if you want the glass up: **the pump moves 2.5 kg/s against about
1 kg/s of evaporation**, so raising the level from 50% to 80% means running two and a half times
over for something like 6 000 ticks, and that is paid for in both heat and steam.

So the residual blocker is **a ratio, not a mechanism** — feed capacity against evaporation rate,
and boiler volume against firing rate. That is a balance decision and it is deliberately left
open. What this change bought is real regardless: the feed lever is now a trade instead of a
free ride to a thermal cliff, and the cooling it does inflict is roughly halved.

