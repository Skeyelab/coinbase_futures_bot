# frozen_string_literal: true

module Coinbase
  # Keeps credentials out of `inspect` (issue #596).
  #
  # The 2026-07-29 leak did not come from a config file, a log line, or a
  # commit. A diagnostic called a method on a client, the call raised, and the
  # error message embedded the receiver's default inspect — which prints every
  # instance variable, private key included. The full PEM landed in a
  # transcript.
  #
  # Moving secrets to Doppler does not help: the value is in process memory
  # either way, and inspect is what publishes it. This is the fix for that
  # specific hole.
  #
  # Included rather than copied into each client for the reason #591 gave for
  # the credential loader: four copies of a safety property is four places for
  # it to go missing.
  module RedactedInspect
    # Matched on the ivar name, so a future @private_key or @signing_secret is
    # covered without anyone remembering to add it. Deny-by-pattern beats an
    # allowlist here — the cost of redacting one field too many is a slightly
    # less useful debug line; the cost of missing one is this issue.
    SENSITIVE = /secret|private_key|password|token|credential/i

    def inspect
      redacted = instance_variables.map do |name|
        value = instance_variable_get(name)
        # Present-but-hidden, not absent. "Is the credential loaded?" is usually
        # the actual question, and a bare omission answers it wrongly.
        rendered = if SENSITIVE.match?(name.to_s)
          value.nil? ? "nil" : "[REDACTED]"
        else
          value.inspect
        end
        "#{name}=#{rendered}"
      end

      "#<#{self.class.name} #{redacted.join(", ")}>"
    end

    # No to_s override. Ruby's default already returns "#<ClassName>" with no
    # ivars, so interpolation was never the leak — inspect was. Mutation testing
    # proved an override here protects nothing, and untested weight in a
    # security module is worse than no weight.
  end
end
