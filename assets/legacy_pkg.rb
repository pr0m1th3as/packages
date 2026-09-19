
# Serve the URLs that 'pkg install -forge' in Octave 10 and earlier asks for.
#
# Those versions read the version to install from a comment on the package
# page, '/<name>/index.html', and then download exactly
# '/download/<name>-<version>.tar.gz' from the same host.  This script picks,
# for every package, the newest release that installs on Octave 10, downloads
# its tarball into 'download/' so that Jekyll publishes it, and records the
# choice in '_data/legacy.json' for the package layout to write into the
# comment.  Octave 11 and later read 'packages.json' and never see any of it.
#
# NOTE: Run during the build only.  Nothing it writes is meant to be committed.

require 'digest'
require 'fileutils'
require 'json'
require 'open-uri'
require 'yaml'

OCTAVE = ['10.3.0', '10.2.0', '10.1.0']

# Too large to mirror; legacy pkg gets no version from its page.
EXCLUDE = ['csg-dataset']

DEPENDENCY = /\A\s*([A-Za-z0-9_.+-]+)\s*(?:\(\s*(<=|>=|==|<|>)\s*([0-9.]+)\s*\))?\s*\z/

def version_key (version)
  version.to_s.scan(/\d+/).map(&:to_i)
end

def satisfies (have, operator, want)
  a = version_key(have)
  b = version_key(want)
  n = [a.length, b.length].max
  cmp = (a + [0] * (n - a.length)) <=> (b + [0] * (n - b.length))
  { '>=' => cmp >= 0, '<=' => cmp <= 0, '==' => cmp == 0,
    '<' => cmp < 0, '>' => cmp > 0 }[operator]
end

def dependencies (release)
  (release['depends'] || []).map { |d| DEPENDENCY.match(d.to_s) }
                            .compact.map { |m| m.captures }
end

$index = {}
Dir.glob('packages/*.yaml') do |filename|
  data = YAML.load(File.read(filename))
  $index[File.basename(filename, '.yaml')] = data['versions'] || []
end

# Download a release once and keep it if it is a gzip tarball that matches
# its checksum.  Legacy pkg can unpack nothing else.
$fetched = {}
def fetch (name, release)
  key = [name, release['id']]
  return $fetched[key] if $fetched.key?(key)
  file = File.join('download', "#{name}-#{release['id']}.tar.gz")
  ok = false
  begin
    body = URI.open(release['url'], read_timeout: 300).read
    sha = release['sha256'].to_s
    ok = body.byteslice(0, 2) == "\x1f\x8b".b &&
         (sha.empty? || Digest::SHA256.hexdigest(body) == sha)
    File.binwrite(file, body) if ok
    puts '  %s %s: %s' % [name, release['id'],
                          ok ? '%.2f MB' % [body.bytesize / 1e6]
                             : 'not a gzip tarball or checksum mismatch']
  rescue StandardError => e
    puts '  %s %s: %s' % [name, release['id'], e.message]
  end
  $fetched[key] = ok
end

# The newest release of 'name' that installs on Octave 'octave', resolving
# each dependency the same way, since legacy pkg only ever gets the release a
# page names.
$memo = {}
def best (name, octave, stack = [])
  key = [name, octave]
  return $memo[key] if $memo.key?(key)
  return nil if !$index.key?(name) || stack.include?(name)
  pick = $index[name].find do |release|
    deps = dependencies(release)
    next false unless deps.any? { |n, _, _| n == 'pkg' }
    next false unless deps.all? { |n, op, v| n != 'octave' || op.nil? ||
                                             satisfies(octave, op, v) }
    next false unless deps.all? do |n, op, v|
      next true if ['octave', 'pkg'].include?(n)
      dep = best(n, octave, stack + [name])
      dep && (op.nil? || satisfies(dep['id'], op, v))
    end
    fetch(name, release)
  end
  $memo[key] = pick
end

FileUtils.mkdir_p('download')
FileUtils.mkdir_p('_data')
legacy = {}
$index.keys.sort.each do |name|
  next if EXCLUDE.include?(name)
  release = nil
  OCTAVE.each { |octave| break if (release = best(name, octave)) }
  if release
    legacy[name] = { 'version' => release['id'], 'octave10' => true }
  elsif (newest = $index[name].first) && fetch(name, newest)
    # Nothing installs on Octave 10.  Serving the newest release anyway lets
    # legacy pkg fail on the Octave version it declares, a clear message,
    # instead of on a download that is not there.
    legacy[name] = { 'version' => newest['id'], 'octave10' => false }
  end
end

# Tarballs of releases tried and not chosen are not served.
kept = legacy.map { |name, entry| "#{name}-#{entry['version']}.tar.gz" }
Dir.glob('download/*.tar.gz').each do |file|
  File.delete(file) unless kept.include?(File.basename(file))
end

File.write(File.join('_data', 'legacy.json'), JSON.pretty_generate(legacy))
puts 'Legacy pkg: %d packages, %d installable on Octave 10, %.1f MB' % [
  legacy.length, legacy.count { |_, e| e['octave10'] },
  Dir.glob('download/*.tar.gz').sum { |f| File.size(f) } / 1e6]
