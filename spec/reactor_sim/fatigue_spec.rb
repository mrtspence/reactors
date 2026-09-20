# frozen_string_literal: true

require "reactor_sim"

# Fatigue is the first mechanic whose whole point is that the SAME lever costs different people
# different amounts, so nearly everything here asserts a **ratio** rather than a figure. The
# `exertion:` constants are first guesses and are labelled as such in the sketch; the shape —
# subjective, superlinear, bounded — is the contract.
RSpec.describe ReactorSim::Fatigue do
  STATS = ReactorSim::Sheet::STATS

  def worker(stats: {}, fatigue: 0.0, health: 1.0, tags: {})
    base = STATS.to_h { |stat| [ stat, 1.0 ] }
    minion = ReactorSim::Minion.new(id: :hand, name: "Hand", station: :shovel,
                                    stats: base.merge(stats), tags: tags)
    [ minion, { health: health, fatigue: fatigue, spent: false, station: :shovel,
                resilience: 1.0, initial_resilience: 1.0, injury: nil } ]
  end

  # The stoker's shipped figure, so the relationship between accrual and `BASE_RECOVERY` here is
  # the one the engine actually has rather than an arbitrary pair.
  EXERTION = 3.3e-3

  def station(exertion: EXERTION, effort: { strength: 1.0 }, **rest)
    ReactorSim::ControlPoint.new(id: :shovel, node: :stoker, effort: effort,
                                 exertion: exertion, **rest)
  end

  def valve = ReactorSim::ControlPoint.new(id: :gauge, node: :drum)

  # One tick of standing there, at a lever fraction.
  def after(minion, state, control, demand:, dt: 10.0)
    described_class.advance(minion, state, control: control, demand: demand, dt: dt)
  end

  describe "the subjective claim" do
    # The whole design in one example. A lever at 80 is one number; what it costs is a different
    # number for every person who stands there, and the ratio is the SQUARE of the capability
    # ratio because accrual is superlinear.
    it "costs a weak worker more than a strong one at the same lever" do
      control = station
      strong, strong_state = worker(stats: { strength: 2.0 })
      weak, weak_state = worker(stats: { strength: 0.5 })

      strong_rate = described_class.accrual(strong, strong_state, control, 1.0)
      weak_rate = described_class.accrual(weak, weak_state, control, 1.0)

      expect(weak_rate / strong_rate).to be_within(1e-9).of((2.0 / 0.5)**2)
    end

    it "costs nothing extra to be strong at a lever a weak worker is dying at" do
      control = station
      strong, strong_state = worker(stats: { strength: 4.0 })

      # Capability 4.0 against a demand of 1.0 is a quarter-load, and a quarter squared.
      expect(described_class.accrual(strong, strong_state, control, 1.0))
        .to be_within(1e-12).of(EXERTION * (0.25**2))
    end

    it "accrues superlinearly in the lever, so half effort costs a quarter" do
      control = station
      minion, state = worker

      full = described_class.accrual(minion, state, control, 1.0)
      half = described_class.accrual(minion, state, control, 0.5)

      expect(full / half).to be_within(1e-9).of(4.0)
    end
  end

  describe "endurance" do
    it "divides the accrual, so 0.5 endurance tires twice as fast" do
      control = station
      hardy, hardy_state = worker(stats: { endurance: 1.0 })
      soft, soft_state = worker(stats: { endurance: 0.5 })

      expect(described_class.accrual(soft, soft_state, control, 1.0) /
             described_class.accrual(hardy, hardy_state, control, 1.0))
        .to be_within(1e-9).of(2.0)
    end

    # **The trap this constant exists for.** `Sheet::MIN_STAT` is 0.0 and endurance is a divisor,
    # so enough bulky kit would divide by zero and put Infinity into a minion's state.
    it "floors at MIN_ENDURANCE rather than dividing by zero" do
      control = station
      flattened, state = worker(stats: { endurance: 0.0 })

      rate = described_class.accrual(flattened, state, control, 1.0)

      expect(rate).to be_finite
      expect(rate).to be_within(1e-12).of(EXERTION / described_class::MIN_ENDURANCE)
    end

    it "is separate from strength, so a strong worker can still be short of wind" do
      control = station
      ogre, ogre_state = worker(stats: { strength: 2.0, endurance: 0.5 })
      human, human_state = worker

      # Twice the work done, and it costs them the same as an ordinary hand doing half of it.
      expect(ogre.capability(ogre_state, effort: { strength: 1.0 })).to eq(2.0)
      expect(described_class.accrual(ogre, ogre_state, control, 1.0))
        .to be_within(1e-12).of(described_class.accrual(human, human_state, control, 0.5) * 2.0)
    end
  end

  describe "the runaway, and its pole" do
    # `capability` contains `(1 - fatigue)`, so tiring raises load, which tires faster. Wanted —
    # and it has a pole at fatigue 1.0 that would otherwise put Infinity into the state.
    it "tires faster as it goes, which is the runaway" do
      control = station
      minion, fresh = worker(fatigue: 0.0)
      _, tired = worker(fatigue: 0.5)

      expect(described_class.accrual(minion, tired, control, 1.0))
        .to be > described_class.accrual(minion, fresh, control, 1.0)
    end

    it "clamps the load rather than dividing by a capability of zero" do
      control = station
      minion, spent = worker(fatigue: 1.0)

      rate = described_class.accrual(minion, spent, control, 1.0)

      expect(rate).to be_finite
      expect(rate).to be_within(1e-12).of(EXERTION * (described_class::LOAD_CEILING.end**2))
    end

    # **The runaway has a closed form, so assert against it rather than against a measured
    # figure.** With `capability = C(1-f)` the accrual is `K/(1-f)²`, and integrating
    # `(1-f)²df = K dt` gives `t = (1 - (1-f)³)/3K` — so time-to-spent is `1/3K`, **a third of
    # what a flat rate would take, at every load.** That is what makes an `exertion:` reciprocal a
    # nominal figure and the real one a third of it.
    #
    # The tolerances are forward-Euler discretisation, not model error: the accrual is convex in
    # `f`, so stepping it at a fixed `dt` lags the exact integral by a few percent and always in
    # that direction. Asserting tighter would be asserting the integrator, not the law.
    it "follows the closed form for fatigue against time" do
      control = station
      minion, state = worker
      dt = 0.25

      400.times { state = after(minion, state, control, demand: 1.0, dt: dt) }

      exact = 1.0 - ((1.0 - (3.0 * EXERTION * 400 * dt))**(1.0 / 3.0))
      expect(state.fetch(:fatigue)).to be_within(5).percent_of(exact)
      expect(state.fetch(:fatigue)).to be < exact
    end

    it "spends somebody in a third of the time a flat rate would" do
      control = station
      minion, state = worker
      dt = 0.25

      ticks = 0
      while state.fetch(:fatigue) < 1.0 && ticks < 100_000
        state = after(minion, state, control, demand: 1.0, dt: dt)
        ticks += 1
      end

      expect(ticks * dt).to be_within(5).percent_of(1.0 / (3.0 * EXERTION))
    end

    it "terminates at 1.0 with nothing infinite or NaN anywhere in the state" do
      control = station
      minion, state = worker

      200.times { state = after(minion, state, control, demand: 1.0) }

      expect(state.fetch(:fatigue)).to eq(1.0)
      expect(state.values.select { |v| v.is_a?(Float) }).to all(be_finite)
    end

    # `0.0 / 0.0` is NaN and `NaN.clamp` raises, so a lever at rest must not be able to throw.
    it "cannot throw at zero demand, even for a minion with no capability left" do
      control = station
      minion, spent = worker(fatigue: 1.0)

      expect { after(minion, spent, control, demand: 0.0) }.not_to raise_error
      expect(described_class.accrual(minion, spent, control, 0.0)).to eq(0.0)
    end
  end

  describe "recovery" do
    it "recovers at a valve, which is somewhere to stand down to" do
      minion, state = worker(fatigue: 0.9)

      rested = after(minion, state, valve, demand: 0.0)

      expect(rested.fetch(:fatigue)).to be < 0.9
    end

    it "recovers nothing at an effort station, because you are still at the fire" do
      minion, state = worker(fatigue: 0.9)

      expect(after(minion, state, station, demand: 0.0).fetch(:fatigue)).to eq(0.9)
    end

    it "recovers off post as well as at a valve" do
      minion, state = worker(fatigue: 0.9)

      expect(after(minion, state.merge(station: nil), nil, demand: 0.0).fetch(:fatigue)).to be < 0.9
    end

    it "cannot recover below zero" do
      minion, state = worker(fatigue: 0.0)

      expect(after(minion, state, valve, demand: 0.0, dt: 10_000.0).fetch(:fatigue)).to eq(0.0)
    end

    # The assertion that says §2.3 netted correctly rather than branching. A station held lightly
    # is genuinely sustainable, and that falls out of the arithmetic instead of a special case.
    it "leaves light work sustainable and hard work not" do
      control = station(recovery: described_class::BASE_RECOVERY)
      minion, light = worker
      _, hard = worker

      600.times do
        light = after(minion, light, control, demand: 0.2)
        hard = after(minion, hard, control, demand: 1.0)
      end

      expect(light.fetch(:fatigue)).to be < 0.2
      expect(hard.fetch(:fatigue)).to eq(1.0)
    end
  end

  describe "what tires somebody and what does not" do
    it "does not tire anybody at a valve, however hard it is turned" do
      minion, state = worker

      expect(described_class.accrual(minion, state, valve, 1.0)).to eq(0.0)
    end

    it "does not tire a minion who is nowhere" do
      minion, state = worker

      expect(described_class.accrual(minion, state, nil, 1.0)).to eq(0.0)
    end

    it "costs more when hurt, because a hurt fireman is a worse fireman" do
      control = station
      minion, sound = worker
      _, hurt = worker
      hurt = hurt.merge(injury: :minor)

      expect(described_class.accrual(minion, hurt, control, 1.0))
        .to be > described_class.accrual(minion, sound, control, 1.0)
    end
  end

  describe "the spent transition" do
    # Events are transitions. `ReliefValve` announced itself 20 times in 40 ticks before it had
    # hysteresis, and a minion hovering on the threshold would do exactly the same.
    it "fires once on the way up, not every tick after" do
      minion, state = worker(fatigue: 0.9)
      control = station

      fired = (1..40).count do
        state = after(minion, state, control, demand: 1.0)
        state, spent = described_class.check_spent(state)
        spent
      end

      expect(fired).to eq(1)
    end

    it "re-arms only once genuinely recovered, not at the threshold it failed at" do
      _, state = worker(fatigue: described_class::SPENT)
      state, = described_class.check_spent(state)

      # Just under SPENT but well above RECOVERED: still latched, so nothing fires.
      state = state.merge(fatigue: described_class::SPENT - 0.01)
      state, again = described_class.check_spent(state)
      expect(again).to be(false)
      expect(state.fetch(:spent)).to be(true)

      state, = described_class.check_spent(state.merge(fatigue: described_class::RECOVERED - 0.01))
      expect(state.fetch(:spent)).to be(false)

      _, refired = described_class.check_spent(state.merge(fatigue: 1.0))
      expect(refired).to be(true)
    end
  end

  describe "a station's declaration" do
    it "refuses an exertion on a control that is not somebody's work" do
      expect { ReactorSim::ControlPoint.new(id: :gauge, node: :drum, exertion: 1.0) }
        .to raise_error(ReactorSim::Error, /no effort:/)
    end

    it "refuses a negative rate in either direction" do
      expect { station(exertion: -1.0) }.to raise_error(ReactorSim::Error, /negative/)
      expect { ReactorSim::ControlPoint.new(id: :gauge, node: :drum, recovery: -1.0) }
        .to raise_error(ReactorSim::Error, /negative/)
    end

    it "reports the lever as a fraction of its own travel, whatever its units" do
      wide = ReactorSim::ControlPoint.new(id: :wide, node: :n, min: 200.0, max: 700.0)

      expect(wide.demand(wide.set_target({ target: 0.0, actual: 0.0 }, 450.0)
                             .merge(actual: 450.0))).to be_within(1e-9).of(0.5)
    end
  end
end
