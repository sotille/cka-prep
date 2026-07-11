# encoding: utf-8
# add-nav.rb — insert an idempotent "Learning path" nav line after the H1 of each
# module masterclass, wiring the basic→advanced spine. Safe to re-run.
Encoding.default_external = Encoding::UTF_8
require "pathname"

ROOT = Pathname.new(File.expand_path("..", __dir__))
COURSE = ROOT + "course"

# study order (directory names under course/)
SPINE = %w[
  week-00-fundamentals
  week-01-architecture
  week-02-workloads-config
  week-03-scheduling
  week-04-lifecycle-observability
  week-05-cluster-maintenance
  week-06-security-rbac
  week-07-storage
  week-08-networking
  week-09-troubleshooting
  week-10-final-prep
]

def nav_for(i)
  prev_link =
    if i == 0
      "[‹ Diagnostic](../diagnostic.md)"
    else
      "[‹ #{SPINE[i - 1]}](../#{SPINE[i - 1]}/masterclass.md)"
    end
  next_link =
    if i == SPINE.length - 1
      "[Mock exams ›](../../mock-exams/)"
    else
      "[#{SPINE[i + 1]} ›](../#{SPINE[i + 1]}/masterclass.md)"
    end
  "> 🧭 **Learning path:** #{prev_link} · [Tier map](../LEARNING-PATH.md) · #{next_link}"
end

SPINE.each_with_index do |dir, i|
  file = COURSE + dir + "masterclass.md"
  unless file.exist?
    puts "skip (missing): #{dir}/masterclass.md"
    next
  end
  lines = file.readlines
  # strip any existing nav (line starting with the nav marker) to keep it current
  lines.reject! { |l| l.start_with?("> 🧭 **Learning path:**") }
  # drop a leading blank that may have been left behind right after H1
  # find the H1 line
  h1 = lines.index { |l| l.start_with?("# ") }
  if h1.nil?
    puts "skip (no H1): #{dir}/masterclass.md"
    next
  end
  insert_at = h1 + 1
  block = ["\n", nav_for(i) + "\n"]
  lines.insert(insert_at, *block)
  file.write(lines.join)
  puts "nav → #{dir}/masterclass.md"
end
