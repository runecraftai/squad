#!/usr/bin/env bash
# Parse and validate a repository WORKFLOW.md manifest.
# Usage: sq-workflow.sh parse <path>
#        sq-workflow.sh validate <path>
#        sq-workflow.sh get <path> <key>
#
# WORKFLOW.md contains YAML front matter only. Parsing uses Ruby's standard
# Psych library and emits JSON without requiring an additional dependency.
set -eu

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

command_name=${1:-}
case "$command_name" in
  -h|--help) usage; exit 0 ;;
  parse|validate|get) ;;
  *) usage >&2; exit 2 ;;
esac
path=${2:-}
[ -n "$path" ] || { echo "error: WORKFLOW.md path is required" >&2; exit 2; }
if [ "$command_name" = get ] && [ -z "${3:-}" ]; then
  echo "error: a dotted key is required" >&2
  exit 2
fi

ruby - "$command_name" "$path" "${3:-}" <<'RUBY'
require 'json'
require 'yaml'

command, path, key = ARGV
begin
  text = File.read(path)
rescue StandardError => e
  warn "error: cannot read #{path}: #{e.message}"
  exit 1
end
unless text.lines.first&.chomp == '---'
  warn 'error: WORKFLOW.md must start with YAML front matter (---)'
  exit 1
end
lines = text.lines
closing = lines[1..].index { |line| line.chomp == '---' }
if closing.nil?
  warn 'error: WORKFLOW.md has no closing YAML front matter delimiter'
  exit 1
end
body = lines[(closing + 2)..] || []
unless body.all? { |line| line.strip.empty? }
  warn 'error: WORKFLOW.md must contain YAML front matter only; prompt body is not allowed'
  exit 1
end
begin
  value = YAML.safe_load(lines[1, closing].join, permitted_classes: [], aliases: false)
rescue Psych::Exception => e
  warn "error: malformed YAML: #{e.message.lines.first.strip}"
  exit 1
end
unless value.is_a?(Hash)
  warn 'error: YAML front matter must be a map'
  exit 1
end

TOP = %w[schema_version tracker workspace hooks execution stall axi].freeze
HOOKS = %w[after_create before_run after_run before_remove].freeze
SCHEMA = {
  'tracker' => %w[kind provider],
  'provider' => %w[repo],
  'workspace' => %w[root],
  'hooks' => HOOKS,
  'hook' => %w[command timeout_ms],
  'execution' => %w[max_retry_attempts failure_backoff_base_ms max_retry_backoff_ms],
  'stall' => %w[timeout_ms],
  'axi' => %w[provider],
}.freeze

def keys(value, allowed, prefix)
  return unless value.is_a?(Hash)
  value.each_key do |k|
    unless allowed.include?(k.to_s)
      warn "error: unknown field #{prefix}#{k}"
      exit 1
    end
  end
end

unless value.key?('schema_version') && value['schema_version'].is_a?(String) && !value['schema_version'].empty?
  warn 'error: schema_version is required and must be a non-empty string'
  exit 1
end
unless value['schema_version'] =~ /\A1\.\d+\.\d+\z/
  warn 'error: schema_version must be a supported 1.x.y version'
  exit 1
end
keys(value, TOP, '')
keys(value['tracker'], SCHEMA['tracker'], 'tracker.')
keys(value['tracker'] && value['tracker']['provider'], SCHEMA['provider'], 'tracker.provider.')
if value['tracker'].is_a?(Hash) && !value['tracker'].key?('kind')
  warn 'error: tracker.kind is required when tracker is present'
  exit 1
end
keys(value['workspace'], SCHEMA['workspace'], 'workspace.')
keys(value['hooks'], SCHEMA['hooks'], 'hooks.')
if value['hooks'].is_a?(Hash)
  value['hooks'].each { |name, hook| keys(hook, SCHEMA['hook'], "hooks.#{name}.") }
end
[['tracker', value['tracker']], ['workspace', value['workspace']], ['hooks', value['hooks']], ['execution', value['execution']], ['stall', value['stall']], ['axi', value['axi']]].each do |name, object|
  next if object.nil? || object.is_a?(Hash)
  warn "error: #{name} must be a map"
  exit 1
end
keys(value['execution'], SCHEMA['execution'], 'execution.')
keys(value['stall'], SCHEMA['stall'], 'stall.')
keys(value['axi'], SCHEMA['axi'], 'axi.')

positive = lambda do |object, field, prefix|
  next unless object.is_a?(Hash) && object.key?(field)
  n = object[field]
  unless n.is_a?(Integer) && n > 0
    warn "error: #{prefix}#{field} must be a positive integer"
    exit 1
  end
end
[['execution', value['execution']], ['stall', value['stall']]].each do |prefix, object|
  (SCHEMA[prefix] || []).each { |field| positive.call(object, field, "#{prefix}.") }
end
if value['hooks'].is_a?(Hash)
  value['hooks'].each { |name, hook| positive.call(hook, 'timeout_ms', "hooks.#{name}.") }
end
if value['tracker'].is_a?(Hash) && value['tracker'].key?('kind') && !%w[github gitlab jira linear].include?(value['tracker']['kind'])
  warn 'error: tracker.kind must be github, gitlab, jira, or linear'
  exit 1
end
if value['hooks'].is_a?(Hash)
  value['hooks'].each do |name, hook|
    unless hook.is_a?(Hash) && hook['command'].is_a?(Array) && !hook['command'].empty? && hook['command'].all? { |part| part.is_a?(String) }
      warn "error: hooks.#{name}.command must be a non-empty string array"
      exit 1
    end
  end
end

if command == 'validate'
  puts 'valid'
elsif command == 'get'
  result = value
  key.split('.').each do |part|
    result = result.is_a?(Hash) ? result[part] : nil
  end
  if result.nil?
    warn "error: key not found: #{key}"
    exit 1
  end
  puts(result.is_a?(String) ? result : JSON.generate(result))
else
  puts JSON.generate(value)
end
RUBY
