#!/usr/bin/env ruby
# frozen_string_literal: true

# Add (or correct) `urn:` on every decision in plenary/, ballots/ and 7372ma/.
#
# URN scheme (uniform, always unique):
#
#   urn:iso:tc154:resolution:{file-stem}:{number}[{-occurrence}]
#
#   file-stem  = the YAML basename, e.g. plenary-16, ballots-2025,
#                7372ma-20020904.
#   number     = the decision's `identifier[0].number` (quotes stripped).
#   occurrence = `-2`, `-3`, … appended when the same number appears on
#                more than one decision WITHIN one file (4 known cases:
#                plenary-15 #168, plenary-21 #248, plenary-25 #279,
#                plenary-39 #2020-25 — same number, different content).
#
# Why qualified: TC 154 resolution numbers are NOT globally unique in
# this dataset — they repeat across plenary files (e.g. '172' in both
# plenary-16 and plenary-17, sometimes the same text re-adopted,
# sometimes different resolutions mis-numbered). The plain
# `urn:iso:tc154:resolution:{number}` scheme collides on 19 decisions;
# the @edoxen/browser generator keys detail pages off Decision.urn and
# its lint fails on duplicates.
#
# Text-surgical: rewrites only `  urn:` lines (or inserts one after the
# identifier block); the rest of each file is untouched.
#
# Usage:
#   ruby scripts/add-decision-urns.rb [dir ...]   # default: plenary ballots 7372ma
#
# Idempotent: re-running produces no changes once every urn matches the
# scheme. No legacy/ backup — the repo is git-tracked.

require "pathname"

URN_PREFIX = "urn:iso:tc154:resolution:"

# Rewrite/insert `urn:` for every decision in `lines`.
# Returns [new_lines, changed, errors].
def qualify_urns(path, stem, lines)
  out = []
  changed = 0
  errors = []
  seen = Hash.new(0)
  i = 0

  while i < lines.length
    line = lines[i]

    unless line.start_with?("- identifier:")
      out << line
      i += 1
      next
    end

    # Copy `- identifier:` and its array block.
    out << line
    i += 1
    block_start = i
    i += 1 while i < lines.length && lines[i].match?(/\A(  - |\s{4,}\S)/)
    block = lines[block_start...i]
    out.concat(block)

    number_line = block.find { |l| l.match?(/\A\s{4,}number:\s*/) }
    unless number_line
      errors << "#{path}: decision at line #{block_start} has no identifier number"
      next
    end
    number = number_line.strip.sub(/\Anumber:\s*/, "").sub(/\A'(.*)'\z/, '\1').sub(/\A"(.*)"\z/, '\1')

    seen[number] += 1
    suffix = seen[number] > 1 ? "-#{seen[number]}" : ""
    urn_line = "  urn: #{URN_PREFIX}#{stem}:#{number}#{suffix}"

    # Find this decision's extent (up to the next decision or EOF) and
    # replace its urn line if present, else insert ours right here.
    rest = lines[i...lines.length] || []
    extent = rest.index { |l| l.start_with?("- identifier:") } || rest.length
    urn_idx = rest.first(extent).index { |l| l.start_with?("  urn:") }

    if urn_idx
      i_urn = i + urn_idx
      if lines[i_urn].rstrip != urn_line
        lines[i_urn] = "#{urn_line}\n"
        changed += 1
      end
    else
      out << "#{urn_line}\n"
      changed += 1
    end
  end

  [out, changed, errors]
end

def process_file(path)
  stem = File.basename(path, ".yaml")
  lines = File.read(path).lines
  new_lines, changed, errors = qualify_urns(path, stem, lines)
  File.write(path, new_lines.join) if changed.positive?
  [(changed.positive? ? :ok : :skip), changed, errors]
rescue => e
  [:error, 0, ["#{path}: #{e.message}"]
]
end

if $PROGRAM_NAME == __FILE__
  dirs = ARGV.empty? ? %w[plenary ballots 7372ma] : ARGV
  root = Pathname.new(File.expand_path("..", __dir__))

  counts = Hash.new(0)
  total_changed = 0
  all_errors = []

  dirs.each do |dir|
    Dir.glob(File.join(root, dir, "*.yaml")).sort.each do |path|
      status, changed, errors = process_file(path)
      counts[status] += 1
      total_changed += changed
      all_errors.concat(errors)
      rel = path.sub("#{root}/", "")
      case status
      when :ok    then puts "  [OK] #{rel}: #{changed} urn(s) written"
      when :skip  then puts "  [SKIP] #{rel}: all urns already qualified"
      when :error then puts "  [ERROR] #{rel}: #{errors.join('; ')}"
      end
    end
  end

  puts "\nTotals: files changed=#{counts[:ok]} unchanged=#{counts[:skip]} " \
       "errors=#{counts[:error]} — urns written=#{total_changed}"
  unless all_errors.empty?
    puts "Errors found — see report above"
    exit 1
  end
end
