# frozen_string_literal: true

require "rails_helper"

# The contract between the panel data and the DOM Stimulus writes into.
#
# These are cheap and they guard something that fails visibly but confusingly: a gauge that
# renders and then never moves, because the attribute the client looks for is not there.
#
# Assertions go through the Nokogiri fragment `render_inline` returns rather than Capybara's
# `page`, so this needs no extra test dependency.
RSpec.describe InstrumentComponent, type: :component do
  def chrome_for(kind, **extra)
    { kind: kind, id: :boiler_pressure, label: "Boiler Pressure" }.merge(extra)
  end

  def render_chrome(kind, **extra)
    render_inline(described_class.new(chrome: chrome_for(kind, **extra)))
  end

  it "gives every instrument the identity Stimulus finds it by" do
    html = render_chrome(:digital, unit: "kPa")

    expect(html.css("[data-instrument-id='boiler_pressure'][data-instrument-kind='digital']")).not_to be_empty
    expect(html.css("[data-instrument-value]")).not_to be_empty
  end

  it "renders a placeholder rather than a number, because chrome carries no values" do
    html = render_chrome(:digital)

    expect(html.at_css("[data-instrument-value]").text.strip).to eq("—")
  end

  describe "a needle" do
    it "publishes its scale, which is what positions the needle" do
      html = render_chrome(:needle, min: 0.0, max: 1400.0)

      expect(html.css("[data-instrument-min='0.0'][data-instrument-max='1400.0']")).not_to be_empty
      expect(html.css("[data-instrument-needle]")).not_to be_empty
    end

    # A needle with no scale cannot position itself, so a chrome missing min/max is a bug in
    # the diagnostic. Failing loudly beats silently defaulting to 0..100 and drawing a lie.
    it "refuses to render without a scale" do
      expect { render_chrome(:needle) }.to raise_error(KeyError)
    end
  end

  # Digital and Prose never ask for min/max — that is what makes it safe for chrome kinds to
  # carry different fields, and it is why the dispatcher exists at all.
  it "renders a digital readout with no scale at all" do
    expect(render_chrome(:digital, unit: "kW").css("[data-instrument-min]")).to be_empty
  end

  # Displays::Prose withholds its phrase list deliberately: knowing it would tell the player
  # that "hairline cracks showing" is the worst of five, for a gauge that is twelve ticks stale
  # and misreads by design. The component must not leak or reconstruct it.
  it "renders prose with no scale, no ordering and no severity" do
    html = render_chrome(:prose)

    expect(html.css("[data-instrument-min]")).to be_empty
    expect(html.css("[data-instrument-phrases]")).to be_empty
  end

  # A gauge silently vanishing from a control panel is the worst failure this page has — the
  # player would be flying without an instrument and have no way to know.
  it "raises on a kind it does not know rather than dropping the gauge" do
    expect { render_chrome(:hologram) }.to raise_error(ArgumentError, /no instrument for :hologram/)
  end

  it "maps a lamp colour in Ruby, since Tailwind cannot build classes from runtime strings" do
    expect(render_chrome(:lamp, colour: :red).css("[data-instrument-colour='bg-red-500']")).not_to be_empty
  end

  # The panel is data-driven, so the whole console must survive whatever the operation declares.
  # The high-pressure engine has twelve instruments and the atmospheric one thirteen.
  describe "the real steam engine panel" do
    it "renders every instrument the operation declares, whichever chassis it is" do
      %i[high_pressure atmospheric].each do |chassis|
        panel = ReactorSim::Match
                .create(id: "p", seed: 1,
                        operations: [ { id: :eng, type: :steam_engine, chassis: chassis } ])
                .panel(operation_id: :eng)

        html = render_inline(PanelComponent.new(panel: panel))

        expect(html.css("[data-instrument-id]").size).to eq(panel.fetch(:instruments).size)
        expect(html.css("[data-lever-id]").size).to eq(panel.fetch(:controls).size)
      end
    end
  end
end
