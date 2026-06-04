# macOS fork safety: GoodJob (and any gem that forks workers) connecting to
# Postgres can segfault via libpq's GSS/Kerberos probe in the fork child.
if RUBY_PLATFORM.include?("darwin") && ENV["PGGSSENCMODE"].to_s.empty?
  ENV["PGGSSENCMODE"] = "disable"
end
