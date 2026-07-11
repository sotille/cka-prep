#!/usr/bin/env bash
# validate-course.sh — static validation of all course content.
#   1. Every fenced ```yaml block in course/, mock-exams/, notes/, drills/, labs/ must parse as YAML.
#   2. Every shell script in labs/, mock-exams/, drills/, scripts/ must pass bash -n.
# Requires only macOS built-ins (ruby, bash). Exit 0 = all good.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

echo "== YAML blocks =="
/usr/bin/ruby -ryaml <<'RUBY' || fail=1
# encoding: utf-8
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
failed = false
blocks = 0
files = Dir.glob(["course/**/*.md", "mock-exams/*.md", "notes/*.md", "drills/*.md", "labs/**/*.md", "progress/*.md"]).sort
files.each do |path|
  lines = File.readlines(path)
  in_yaml = false
  buf = []
  start_line = 0
  indent = ""
  lines.each_with_index do |line, i|
    if !in_yaml && line =~ /^(\s*)```ya?ml\s*$/
      in_yaml = true
      indent = $1
      buf = []
      start_line = i + 1
    elsif in_yaml && line =~ /^\s*```\s*$/
      in_yaml = false
      blocks += 1
      begin
        body = buf.map { |l| l.start_with?(indent) ? l[indent.length..] : l }.join
        YAML.load_stream(body)
      rescue Psych::SyntaxError => e
        puts "  FAIL #{path}:#{start_line} — #{e.message}"
        failed = true
      end
    elsif in_yaml
      buf << line
    end
  end
  if in_yaml
    puts "  FAIL #{path}:#{start_line} — unclosed yaml fence"
    failed = true
  end
end
puts "  #{blocks} yaml blocks checked in #{files.length} files"
exit(failed ? 1 : 0)
RUBY

echo "== Shell scripts =="
scripts=0
while IFS= read -r -d '' f; do
  scripts=$((scripts + 1))
  if ! err=$(bash -n "$f" 2>&1); then
    echo "  FAIL $f"
    echo "$err" | sed 's/^/    /'
    fail=1
  fi
done < <(find labs mock-exams drills scripts mock -name '*.sh' -print0 2>/dev/null)
echo "  $scripts shell scripts checked"

if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: OK"
