# frozen_string_literal: true

require "reactor_sim"
require "open3"

# The keystone spec. Everything in docs/architecture.md §6 and §8 — exact crash recovery,
# replay, spectating — rests on the simulation being a self-contained, side-effect-free
# library. This spec is what stops that from being merely an intention someone wrote down.
RSpec.describe "ReactorSim purity" do
  let(:lib_path) { File.expand_path("../../lib", __dir__) }
  let(:rig_path) { File.expand_path("../support/loop_rig", __dir__) }

  describe "loading" do
    it "loads in a bare Ruby process with no Rails present" do
      script = <<~RUBY
        require "reactor_sim"
        require "#{rig_path}"

        %w[Rails ActiveRecord ActiveJob ActiveSupport ActionCable Karafka Rdkafka].each do |const|
          if Object.const_defined?(const)
            warn "\#{const} is defined inside the simulation"
            exit 1
          end
        end

        match = ReactorSim::Match.create(
          id: "purity", seed: 1, operations: [{ id: :rig, type: :loop_rig }]
        )
        10.times { match.step! }
        exit match.tick == 10 ? 0 : 1
      RUBY

      stdout, status = Open3.capture2e(clean_env, "ruby", "-I#{lib_path}", "-e", script)

      expect(status).to be_success, "sim failed to load standalone:\n#{stdout}"
    end
  end

  describe "source" do
    # A static sweep, because the load test above only catches what a particular code path
    # happens to touch. These are the specific things that would silently destroy
    # reproducibility.
    FORBIDDEN = {
      /\bTime\.now\b/     => "Time.now — the clock is injected as `dt`",
      /\bTime\.current\b/ => "Time.current — ActiveSupport, and a clock",
      /\bDate\.today\b/   => "Date.today — the clock is injected",
      /\bSecureRandom\b/  => "SecureRandom — entropy comes from the seeded Rng",
      /\bRandom\.new\b/   => "Random.new — use ReactorSim::Rng",
      /(?<![.\w])rand\(/  => "Kernel#rand — use ReactorSim::Rng",
      /\bRails\b/         => "Rails",
      /\bENV\b/           => "ENV — configuration is passed in, not read",
      /\.hash\b/          => "String#hash is randomised per process; use Rng.stream"
    }.freeze

    it "contains none of the constructs that would break reproducibility" do
      offenders = sim_sources.flat_map do |path|
        File.readlines(path).each_with_index.flat_map do |line, index|
          next [] if line.strip.start_with?("#")

          FORBIDDEN.filter_map do |pattern, reason|
            "#{relative(path)}:#{index + 1} — #{reason}" if line.match?(pattern)
          end
        end
      end

      expect(offenders).to be_empty, "reproducibility hazards:\n  #{offenders.join("\n  ")}"
    end

    it "requires nothing outside the simulation but json and yaml" do
      requires = sim_sources.flat_map do |path|
        File.readlines(path).grep(/^\s*require\s+["']/).map { |l| l[/["']([^"']+)["']/, 1] }
      end

      expect(requires.uniq).to contain_exactly("json", "yaml")
    end

    # Content is read once at boot and never during a tick. Confining every filesystem call
    # to one file is what keeps that checkable — otherwise "no I/O on the tick path" is a
    # claim nobody can verify without reading everything.
    it "touches the filesystem only in content.rb" do
      io = %r{\b(File\.|IO\.|Dir\[|Dir\.|YAML\.)}

      offenders = sim_sources.reject { |p| relative(p) == "reactor_sim/content.rb" }
                             .flat_map do |path|
        File.readlines(path).each_with_index.filter_map do |line, index|
          next if line.strip.start_with?("#")

          "#{relative(path)}:#{index + 1} — #{line.strip}" if line.match?(io)
        end
      end

      expect(offenders).to be_empty, "I/O outside Content:\n  #{offenders.join("\n  ")}"
    end
  end

  def sim_sources
    Dir[File.join(lib_path, "reactor_sim.rb"), File.join(lib_path, "reactor_sim/**/*.rb")]
  end

  def relative(path) = path.sub("#{lib_path}/", "")

  # Strip Bundler out of the child's environment so the subprocess really is a bare Ruby
  # process rather than one already inside the app's gem context.
  def clean_env
    ENV.keys.grep(/\A(BUNDLE_|RUBYOPT|RUBYLIB|GEM_)/).to_h { |k| [ k, nil ] }
  end
end
