#!/usr/bin/env ruby
# frozen_string_literal: true

# Migrate pre-v2 Edoxen YAML fixtures to the v2.1 wire shape.
#
# Used by the TC154 and TC184 downstream repos (TODO.upgrade-downstream
# in edoxen-model). One script, two repos — parameterised by --prefix
# and --data-dir.
#
# Usage:
#   ruby scripts/migrate_to_v2.rb \
#     --prefix "ISO/TC 154" \
#     --data-dir plenary \
#     --data-dir ballots \
#     --data-dir 7372ma \
#     --legacy-dir legacy
#
# Idempotent: detects already-migrated files (presence of `decisions:`
# key) and skips them. Originals are moved to --legacy-dir, never
# deleted (per the project's source-preservation rule).

require "optparse"
require "fileutils"
require "yaml"
require "date"

class V2Migrator
  SCHEMA_URL = "https://raw.githubusercontent.com/edoxen/edoxen/refs/heads/main/schema/edoxen.yaml".freeze

  # Map v0.7.x date-kind → v2.1 DecisionDate.type.
  DATE_KIND_MAP = {
    "meeting"   => "adoption",
    "decision"  => "adoption",
    "ballot"    => "adoption",
    "effective" => "effective",
    "discussed" => "discussed",
    "adoption"  => "adoption",
    "drafted"   => "drafted",
    "published" => "published"
  }.freeze

  attr_reader :prefix, :data_dirs, :legacy_dir, :dry_run, :report

  def initialize(prefix:, data_dirs:, legacy_dir:, dry_run: false)
    @prefix = prefix
    @data_dirs = Array(data_dirs)
    @legacy_dir = legacy_dir
    @dry_run = dry_run
    @report = []
  end

  def run
    data_dirs.each { |dir| migrate_dir(dir) }
    print_report
  end

  private

  def migrate_dir(dir)
    Dir.glob(File.join(dir, "*.yaml")).sort.each do |path|
      migrate_file(path)
    end
    Dir.glob(File.join(dir, "*.yml")).sort.each do |path|
      migrate_file(path)
    end
  end

  def migrate_file(path)
    source = File.read(path)
    data = YAML.safe_load(source, permitted_classes: [Date, Time])

    if data.is_a?(Hash) && data.key?("decisions")
      report << [path, :skip, "already migrated (has decisions:)"]
      return
    end

    unless data.is_a?(Hash) && data.key?("resolutions")
      report << [path, :skip, "no resolutions: key — not a v0.7.x fixture"]
      return
    end

    migrated = migrate_payload(data)
    write_output(path, migrated, source)
    report << [path, :ok, "#{data["resolutions"].size} decision(s) migrated"]
  rescue => e
    report << [path, :error, e.message]
  end

  def migrate_payload(data)
    # Extract the meeting date from metadata as a fallback for
    # resolutions/actions/approvals that have no dates of their own.
    fallback_date = pick_first_date_start(data["metadata"]&.dig("dates"))
    fallback_decision_date = fallback_date ?
      { "date" => fallback_date, "type" => "adoption" } : nil

    {
      "metadata" => migrate_metadata(data["metadata"]),
      "decisions" => Array(data["resolutions"]).map { |r|
        migrate_resolution(r, fallback_decision_date)
      }
    }
  end

  def migrate_metadata(meta)
    return {} unless meta.is_a?(Hash)

    result = {}
    result["title"] = meta["title"] if meta["title"]
    result["date"] = pick_first_date_start(meta["dates"]) if meta["dates"]
    result["source"] = meta["source"] if meta["source"]
    result["venue"] = meta["venue"] if meta["venue"]
    result["city"] = meta["city"] if meta["city"]
    result["country_code"] = meta["country_code"] if meta["country_code"]
    result
  end

  def migrate_resolution(res, fallback_date = nil)
    identifier = res["identifier"]
    decision = {
      "identifier" => migrate_identifier(identifier),
      "kind" => "resolution",
      "status" => "decided"
    }

    decision["doi"] = res["doi"] if res["doi"]
    decision["urn"] = res["urn"] if res["urn"]
    decision["dates"] = migrate_dates(res["dates"]) if res["dates"]
    decision["categories"] = res["categories"] if res["categories"]

    # v2.1 Approval requires `date`, Action requires `date_effective`.
    # Many v0.7.x fixtures omit these — synthesize from the parent
    # decision's first date (or the meeting date fallback).
    parent_date = decision["dates"]&.first || fallback_date

    loc = migrate_localization(res, parent_date)
    decision["localizations"] = [loc] unless loc.empty?

    decision
  end

  def migrate_identifier(identifier)
    return [{ "prefix" => prefix, "number" => identifier.to_s }] unless identifier.nil?

    []
  end

  def migrate_dates(dates)
    Array(dates).map { |d| migrate_date(d) }.compact
  end

  def migrate_date(d)
    return nil unless d.is_a?(Hash)

    date = d["start"] || d["date"]
    return nil unless date

    kind = d["kind"] || "adoption"
    {
      "date" => date.respond_to?(:iso8601) ? date.iso8601 : date.to_s,
      "type" => DATE_KIND_MAP.fetch(kind.to_s, "adoption")
    }
  end

  def migrate_localization(res, parent_date = nil)
    loc = { "language_code" => "eng", "script" => "Latn" }

    loc["title"] = res["title"] if res["title"]
    loc["subject"] = res["subject"] if res["subject"]
    loc["message"] = res["message"] if res["message"]
    loc["considering"] = res["considering"] if res["considering"]
    loc["considerations"] = migrate_considerations(res["considerations"], parent_date) if res["considerations"]
    loc["approvals"] = migrate_approvals(res["approvals"], parent_date) if res["approvals"]
    loc["actions"] = migrate_actions(res["actions"], parent_date) if res["actions"]
    loc
  end

  def migrate_considerations(items, parent_date = nil)
    Array(items).map { |c| migrate_consideration(c, parent_date) }.compact
  end

  def migrate_consideration(c, parent_date = nil)
    return nil unless c.is_a?(Hash)

    out = {}
    out["type"] = c["type"] if c["type"]
    if c["dates"]
      date = migrate_date(c["dates"].first)
      out["date_effective"] = date if date
    elsif parent_date
      out["date_effective"] = parent_date.dup
    end
    out["message"] = c["message"] if c["message"]
    out
  end

  def migrate_approvals(items, parent_date = nil)
    Array(items).map { |a| migrate_approval(a, parent_date) }.compact
  end

  def migrate_approval(a, parent_date = nil)
    return nil unless a.is_a?(Hash)

    out = {}
    out["type"] = a["type"] || "affirmative"
    out["degree"] = a["degree"] || "majority"
    if a["dates"]
      date = migrate_date(a["dates"].first)
      out["date"] = date if date
    elsif parent_date
      # v2.1 requires `date` on Approval. Synthesize from parent decision.
      # Use .dup to avoid YAML aliases from Psych (shared hash references).
      out["date"] = parent_date.dup
    end
    out["message"] = a["message"] if a["message"]
    out
  end

  def migrate_actions(items, parent_date = nil)
    Array(items).map { |a| migrate_action(a, parent_date) }.compact
  end

  def migrate_action(a, parent_date = nil)
    return nil unless a.is_a?(Hash)

    out = {}
    out["type"] = a["type"] if a["type"]
    if a["dates"]
      date = migrate_date(a["dates"].first)
      out["date_effective"] = date if date
    elsif parent_date
      out["date_effective"] = parent_date.dup
    end
    out["message"] = a["message"] if a["message"]
    out
  end

  def pick_first_date_start(dates)
    return nil unless dates.is_a?(Array) && !dates.empty?

    first = dates.first
    return nil unless first.is_a?(Hash)

    date = first["start"] || first["date"]
    return nil unless date

    date.respond_to?(:iso8601) ? date.iso8601 : date.to_s
  end

  def write_output(path, payload, original_source)
    yaml_header = extract_yaml_language_server_comment(original_source)
    output = dump_yaml(payload)
    output = update_schema_url(output)
    # The yaml-language-server comment lives above the leading --- marker.
    # YAML.dump already includes the leading --- so we prepend the comment
    # (with a blank line after) to avoid a double ---. The header URL is
    # updated separately (after substitution) to catch the metanorma→edoxen
    # rename in the original comment.
    if yaml_header
      yaml_header = update_schema_url(yaml_header)
      output = output.sub(/\A---\n/, "#{yaml_header}\n---\n")
    end

    if dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, output)
    else
      backup_original(path)
      File.write(path, output)
    end
  end

  def backup_original(path)
    return unless legacy_dir

    relative = path.sub(/\A\.\//, "")
    backup_path = File.join(legacy_dir, relative)
    FileUtils.mkdir_p(File.dirname(backup_path))
    FileUtils.cp(path, backup_path) unless File.exist?(backup_path)
  end

  def extract_yaml_language_server_comment(source)
    source.lines.first(5).find { |l| l.strip.match?(/\A#\s*yaml-language-server:\s*\$schema=/) }&.rstrip
  end

  def update_schema_url(yaml)
    yaml.gsub(
      %r{metanorma/edoxen/refs/heads/main/schema/edoxen\.yaml},
      "edoxen/edoxen/refs/heads/main/schema/edoxen.yaml"
    )
  end

  # Serialize with consistent formatting that matches what `edoxen
  # normalize` would produce. v2.1 fixtures use snake_case wire names
  # (per the gem's convention).
  def dump_yaml(payload)
    YAML.dump(payload)
  end

  def print_report
    puts "\nMigration report:"
    counts = Hash.new(0)
    report.each do |path, status, message|
      counts[status] += 1
      puts "  [#{status.upcase}] #{File.basename(path)}: #{message}"
    end
    puts "\nTotals: ok=#{counts[:ok]} skipped=#{counts[:skip]} errors=#{counts[:error]}"
    puts "Errors found — see report above" if counts[:error].positive?
  end
end

if $PROGRAM_NAME == __FILE__
  options = { prefix: nil, data_dirs: [], legacy_dir: nil, dry_run: false }
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: #{File.basename($0)} --prefix PREFIX --data-dir DIR [--data-dir DIR ...] [--legacy-dir DIR] [--dry-run]"
    opts.on("--prefix PREFIX", "Identifier prefix (e.g. 'ISO/TC 154')") { |v| options[:prefix] = v }
    opts.on("--data-dir DIR", "Data directory (repeatable)") { |v| options[:data_dirs] << v }
    opts.on("--legacy-dir DIR", "Directory to back up originals in") { |v| options[:legacy_dir] = v }
    opts.on("--dry-run", "Skip backing up originals") { options[:dry_run] = true }
    opts.on("-h", "--help") { puts opts; exit }
  end
  parser.parse!

  unless options[:prefix]
    warn "Error: --prefix is required"
    warn parser.banner
    exit 1
  end
  if options[:data_dirs].empty?
    warn "Error: at least one --data-dir is required"
    warn parser.banner
    exit 1
  end

  V2Migrator.new(
    prefix: options[:prefix],
    data_dirs: options[:data_dirs],
    legacy_dir: options[:legacy_dir],
    dry_run: options[:dry_run]
  ).run
end
