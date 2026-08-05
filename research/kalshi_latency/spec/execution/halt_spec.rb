require "tmpdir"
require_relative "../../lib/execution/halt"

RSpec.describe Execution::Halt do
  it "is not halted when no halt file exists" do
    Dir.mktmpdir do |dir|
      expect(described_class.new(data_dir: dir).active?).to be false
    end
  end

  it "halts when the file exists and carries the reason" do
    Dir.mktmpdir do |dir|
      halt = described_class.new(data_dir: dir)
      halt.engage!("SATX settled against the model")

      expect(halt.active?).to be true
      expect(halt.reason).to eq("SATX settled against the model")
    end
  end

  it "is visible to a different process reading the same directory" do
    Dir.mktmpdir do |dir|
      described_class.new(data_dir: dir).engage!("ops")

      expect(described_class.new(data_dir: dir).active?).to be true
    end
  end

  it "resumes by removing the file" do
    Dir.mktmpdir do |dir|
      halt = described_class.new(data_dir: dir)
      halt.engage!("ops")
      halt.resume!

      expect(halt.active?).to be false
    end
  end

  it "halts on a reason-less file too — an empty file is still a halt" do
    Dir.mktmpdir do |dir|
      FileUtils.touch(File.join(dir, "HALT"))
      halt = described_class.new(data_dir: dir)

      expect(halt.active?).to be true
      expect(halt.reason).to eq("")
    end
  end
end
