# frozen_string_literal: true

require "rails_helper"

# CONTEXT.md is the domain glossary agents are instructed to work from, so a
# stale entry does not merely misinform a reader — it teaches every agent that
# reads it a fact that is no longer true. Two entries drifted within five days
# of being written (Funding Rate said "not yet modeled" after Funding::Schedule
# shipped in #457; Order said "not modelled in the code" after the Order model
# landed), and nothing caught it.
#
# These examples make the glossary's factual claims executable: the ones that
# assert something does NOT exist in code, and the ones that name a model. Both
# fail loudly the moment the code moves underneath them.
module ContextClaims
  # Concepts the glossary may describe as unimplemented only while they
  # genuinely are. Add an entry when a concept ships; the first example below
  # then holds the prose to it.
  SHIPPED = {
    "Funding Rate" => "Funding::Schedule",
    "Order" => "Order"
  }.freeze

  # Prose claiming a concept has no code behind it.
  UNIMPLEMENTED = /not\s+(?:yet\s+|currently\s+)?model+ed|not\s+currently\s+a\s+model|no\s+model\s+(?:exists|yet)/i

  # "Maps to the `Position` model" — a concrete, checkable cross-reference.
  MODEL_REFERENCE = /Maps to (?:the )?`([A-Z][A-Za-z0-9:]*)`/

  # Splits "### Term\nbody..." into {term => body}, stopping each body at the
  # next heading of any level so one entry cannot absorb another.
  def self.parse(markdown)
    markdown.scan(/^### (.+?)\n(.*?)(?=^\#{1,3} |\z)/m).to_h do |term, body|
      [term.strip, body.strip]
    end
  end

  # constantize rather than const_defined? so Zeitwerk autoloading resolves the
  # name the same way application code would.
  def self.defined_constant?(name)
    name.constantize
    true
  rescue NameError
    false
  end
end

RSpec.describe "CONTEXT.md domain glossary" do
  let(:glossary) { ContextClaims.parse(Rails.root.join("CONTEXT.md").read) }

  it "does not describe shipped concepts as unimplemented" do
    stale = ContextClaims::SHIPPED.filter_map do |term, constant|
      entry = glossary.fetch(term) { raise "CONTEXT.md has no `### #{term}` entry" }
      next unless ContextClaims.defined_constant?(constant)
      next unless entry.match?(ContextClaims::UNIMPLEMENTED)

      "#{term} — glossary says it is not modelled, but #{constant} exists"
    end

    expect(stale).to be_empty, <<~MSG
      CONTEXT.md describes shipped code as unimplemented:

        #{stale.join("\n  ")}

      Update the glossary entry to match what actually ships.
    MSG
  end

  it "only references models that exist" do
    dangling = glossary.flat_map { |term, entry|
      entry.scan(ContextClaims::MODEL_REFERENCE).flatten.filter_map do |constant|
        "#{term} — references `#{constant}`, which is not defined" unless ContextClaims.defined_constant?(constant)
      end
    }

    expect(dangling).to be_empty, <<~MSG
      CONTEXT.md points at models that no longer exist:

        #{dangling.join("\n  ")}

      A rename in app/models must be reflected in the glossary.
    MSG
  end
end
