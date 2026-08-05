require "digest"

# Reads the BLS Employment Situation release and says what it currently claims.
#
# The page carries no Last-Modified and no ETag, so publication cannot be
# detected from headers -- it has to come from the content. Fingerprinting the
# whole page would fire on any unrelated churn (nav, banners, session markers),
# so the primary signal is the EXTRACTED NUMBER changing. A content digest is
# recorded alongside as a backstop for the unlikely case where two consecutive
# months print the identical headline figure.
module ReleaseDetector
  # "Total nonfarm payroll employment (+57,000) and the unemployment rate ..."
  # The sign is mandatory: a bare "(57,000)" elsewhere on the page is some other
  # figure, not the headline change.
  PAYROLLS = /nonfarm payroll employment\s*\(([+-])([\d,]+)\)/i

  # "the unemployment rate (4.1 percent)"
  UNEMPLOYMENT = /unemployment rate\s*\((\d+\.\d+)\s*percent\)/i

  def self.observe(body)
    text = strip(body)

    {
      payrolls: payrolls(text),
      unemployment: unemployment(text),
      digest: Digest::SHA256.hexdigest(text.to_s)[0, 16]
    }
  end

  def self.payrolls(text)
    m = text.match(PAYROLLS)
    return nil unless m

    magnitude = m[2].delete(",").to_i
    (m[1] == "-") ? -magnitude : magnitude
  end

  def self.unemployment(text)
    text.match(UNEMPLOYMENT)&.captures&.first&.to_f
  end

  # Tags out, whitespace collapsed. Without the collapse a reflow would change
  # the digest and read as a publication.
  def self.strip(body)
    body.to_s.gsub(/<[^>]+>/, " ").gsub(/\s+/, " ").strip
  end
end
