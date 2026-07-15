#!/usr/bin/env ruby
# frozen_string_literal: true

# Migrate pre-1.0 edoxen YAML files to the 1.0 per-field Localized format.
#
# Pre-1.0 shape:
#   metadata:
#     title: "scalar string"
#   decisions:
#   - identifier: [...]
#     localizations:
#     - language_code: eng
#       script: Latn
#       title: "scalar"
#       subject: "scalar"
#       actions:
#       - type: resolves
#         message: "scalar"
#
# 1.0 shape:
#   metadata:
#     title:
#     - spelling: eng
#       value: "scalar string"
#   decisions:
#   - identifier: [...]
#     title:
#     - spelling: eng
#       value: "scalar"
#     actions:
#     - type: resolves
#       message:
#       - spelling: eng
#         value: "scalar"

require "yaml"
require "pathname"

def localized(lang, value)
  return nil if value.nil?

  { "spelling" => lang, "value" => value }
end

def localized_array(langs_values)
  langs_values.filter_map { |lang, val| localized(lang, val) }
end

def merge_localized_strings(localizations, field)
  # For a simple scalar field (title, subject), collect from each localization.
  localizations.filter_map do |loc|
    val = loc[field]
    next if val.nil? || val.to_s.empty?

    { "spelling" => loc["language_code"], "value" => val }
  end
end

def merge_leaf_arrays(localizations, field)
  # For nested arrays (actions, approvals, considerations), index-match
  # across localizations and merge each element's translatable fields.
  # Returns the merged array.
  template_loc = localizations.first
  return nil unless template_loc
  return nil unless template_loc[field].is_a?(Array)

  template_arr = template_loc[field]
  result = template_arr.each_with_index.map do |_elem, idx|
    elem_result = {}
    template_elem = template_loc[field][idx]

    # Copy non-translatable fields from the first localization's element
    elem_result.merge!(template_elem)

    # Merge the translatable "message" field across localizations
    msgs = localizations.filter_map do |loc|
      arr = loc[field]
      next unless arr.is_a?(Array) && arr[idx]
      val = arr[idx]["message"]
      next if val.nil? || val.to_s.empty?

      { "spelling" => loc["language_code"], "value" => val }
    end
    elem_result["message"] = msgs unless msgs.empty?

    elem_result
  end

  result
end

def migrate_decision(decision)
  locs = decision.delete("localizations")
  return decision unless locs.is_a?(Array) && !locs.empty?

  # Lift translatable fields from localizations to the decision level
  %w[title subject message considering].each do |field|
    merged = merge_localized_strings(locs, field)
    decision[field] = merged unless merged.empty? || decision[field]
  end

  # Merge nested leaf arrays
  %w[actions approvals considerations].each do |field|
    merged = merge_leaf_arrays(locs, field)
    decision[field] = merged if merged && (!decision[field] || decision[field].empty?)
  end

  decision
end

def migrate_file(path)
  data = YAML.safe_load_file(path, permitted_classes: [Date, Time])
  return false unless data.is_a?(Hash)

  changed = false

  # Migrate metadata.title
  meta = data["metadata"]
  if meta && meta["title"].is_a?(String)
    meta["title"] = [{ "spelling" => "eng", "value" => meta["title"] }]
    changed = true
  end

  # Migrate metadata.date (leave as-is — it's already a date field)
  # Migrate metadata.title_localized if present
  if meta && meta["title_localized"].is_a?(Array)
    meta["title"] = meta.delete("title_localized")
    changed = true
  end

  # Migrate decisions
  decisions = data["decisions"]
  if decisions.is_a?(Array)
    decisions.each { |d| migrate_decision(d) }
    changed = true
  end

  return false unless changed

  # Write back with the schema comment preserved
  content = File.read(path)
  schema_line = content.lines.find { |l| l.match?(/\A#\s*yaml-language-server/) }

  output = +"---\n"
  output = +"# #{schema_line.sub(/^#\s*/, '')}\n---\n" if schema_line
  output << YAML.dump(data).sub(/^---\n/, "")

  File.write(path, output)
  true
end

# Process all YAML files in the given directories
dirs = ARGV.empty? ? %w[plenary ballots 7372ma] : ARGV
root = Pathname.new(File.expand_path("..", __dir__))

total = 0
migrated = 0
dirs.each do |dir|
  pattern = File.join(Dir.pwd, dir, "*.yaml")
  Dir.glob(pattern).each do |file|
    next unless File.file?(file)

    content = File.read(file)
    next unless content.include?("localizations:") || content.match?(/^metadata:\n  title: ["\']/)

    total += 1
    if migrate_file(file)
      migrated += 1
      puts "migrated: #{file}"
    end
  end
end

puts "\n#{migrated}/#{total} files migrated."
