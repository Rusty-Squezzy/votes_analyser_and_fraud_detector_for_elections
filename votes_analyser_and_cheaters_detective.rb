# 1. объединение имён с <=2 опечатками (Левенштейн)
# 2. рейтинг участников
# 3. поиск двух мошенников
# 4. запись в result.txt с временем выполнения

require 'time'

FILE_PATH = "votes_42.txt"
OUTPUT_FILE = "result.txt"
WINDOW = 3600 # секунд

start_time = Time.now

# структуры для объединения
class UnionFind
  def initialize
    @parent = {}
    @rank = {}
  end
  def find(x)
    @parent[x] ||= x
    @parent[x] = find(@parent[x]) if @parent[x] != x
    @parent[x]
  end
  def union(a, b)
    ra = find(a)
    rb = find(b)
    return if ra == rb
    @rank[ra] ||= 0
    @rank[rb] ||= 0
    if @rank[ra] < @rank[rb]
      @parent[ra] = rb
    elsif @rank[rb] < @rank[ra]
      @parent[rb] = ra
    else
      @parent[rb] = ra
      @rank[ra] += 1
    end
  end
end


# расстояние Левенштейна с отсечением
def levenshtein_with_cutoff(a, b, cutoff)
  diff = (a.length - b.length).abs
  return cutoff + 1 if diff > cutoff
  n, m = a.length, b.length
  return m if n == 0
  return n if m == 0

  prev = Array.new(m + 1) { |i| i }
  curr = Array.new(m + 1, 0)

  (1..n).each do |i|
    curr[0] = i
    min_in_row = curr[0]
    ai = a.getbyte(i - 1)
    (1..m).each do |j|
      cost = (ai == b.getbyte(j - 1)) ? 0 : 1
      val = [curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost].min
      curr[j] = val
      min_in_row = val if val < min_in_row
    end
    return cutoff + 1 if min_in_row > cutoff
    prev, curr = curr, prev
  end
  prev[m]
end


# bk-tree для быстрого поиска похожих имён
class BKNode
  attr_reader :word, :children
  def initialize(word)
    @word = word
    @children = {}
  end
  def insert(word)
    d = levenshtein_with_cutoff(@word, word, 2)
    if @children[d]
      @children[d].insert(word)
    else
      @children[d] = BKNode.new(word)
    end
  end
  def search(word, threshold, result)
    d = levenshtein_with_cutoff(@word, word, threshold)
    result << [@word, d] if d <= threshold
    ((d - threshold)..(d + threshold)).each do |k|
      node = @children[k]
      node.search(word, threshold, result) if node
    end
  end
end

class BKTree
  def initialize
    @root = nil
  end
  def insert(word)
    if @root.nil?
      @root = BKNode.new(word)
    else
      @root.insert(word)
    end
  end
  def search(word, threshold)
    return [] if @root.nil?
    result = []
    @root.search(word, threshold, result)
    result
  end
end


puts "чтение файла..."
lines = File.readlines(FILE_PATH)

votes = Hash.new(0)
times = Hash.new { |h, k| h[k] = [] }
ips = Hash.new { |h, k| h[k] = Hash.new(0) }

lines.each do |line|
  if line =~ /candidate:\s*(.+)\s*$/
    name = $1.strip
    votes[name] += 1

    if line =~ /time:\s*([^,]+),\s*ip:\s*([^,]+),\s*candidate:/
      t_str = $1.strip
      ip = $2.strip
      begin
        t = Time.parse(t_str).to_i
      rescue
        t = nil
      end
      times[name] << t if t
      ips[name][ip] += 1
    end
  end
end

puts "прочитано #{lines.size} строк"
puts "уникальных имён: #{votes.keys.size}"


# точное объединение похожих имён
bk = BKTree.new
names = votes.keys
names.each { |n| bk.insert(n) }

uf = UnionFind.new
names.each do |n|
  bk.search(n, 2).each do |w, d|
    uf.union(n, w) if d <= 2
  end
end

clusters = Hash.new { |h, k| h[k] = [] }
names.each { |n| clusters[uf.find(n)] << n }

canon = {}
clusters.each do |_, group|
  best = group.max_by { |x| votes[x] }
  group.each { |x| canon[x] = best }
end

final_votes = Hash.new(0)
final_times = Hash.new { |h, k| h[k] = [] }
final_ips = Hash.new { |h, k| h[k] = Hash.new(0) }
variant_map = Hash.new { |h, k| h[k] = [] }

names.each do |n|
  base = canon[n] || n
  final_votes[base] += votes[n]
  final_times[base].concat(times[n])
  ips[n].each { |ip, c| final_ips[base][ip] += c }
  variant_map[base] << n unless variant_map[base].include?(n)
end

ranking = final_votes.sort_by { |_, cnt| -cnt }


# поиск читеров
ip_cheater = ranking.map do |name, _|
  ip_counts = final_ips[name]
  max_ip, max_count = ip_counts.max_by { |ip, c| c } || [nil, 0]
  { name: name, max_ip: max_ip, max_ip_count: max_count, total: final_votes[name] }
end.max_by { |h| h[:max_ip_count] }

window_cheater = ranking.map do |name, _|
  arr = final_times[name].compact.sort
  l = 0
  max_window = 0
  arr.each_with_index do |cur, r|
    while arr[l] < cur - WINDOW
      l += 1
      break if l > r
    end
    window = r - l + 1
    max_window = window if window > max_window
  end
  { name: name, max_window: max_window, total: final_votes[name], unique_ips: final_ips[name].keys.size }
end.max_by { |h| h[:max_window] }




puts
puts "итоговый рейтинг (топ 50):"
ranking.first(50).each_with_index do |(name, cnt), i|
  puts "#{i + 1}. #{name.downcase} — #{cnt} голосов"
end

puts
puts "объединённые варианты имён:"
variant_map.each do |canon_name, variants|
  next if variants.size <= 1
  puts "#{canon_name.downcase} => #{variants.map(&:downcase).join(', ')}"
end

puts
puts "подозрительный №1 — накрутка с одного ip:"
if ip_cheater
  puts "имя: #{ip_cheater[:name].downcase}"
  puts "всего голосов: #{ip_cheater[:total]}"
  puts "максимум голосов с одного ip: #{ip_cheater[:max_ip_count]} (ip: #{ip_cheater[:max_ip]})"
end

puts
puts "подозрительный №2 — быстрые всплески голосов (окно #{WINDOW} секунд):"
if window_cheater
  puts "имя: #{window_cheater[:name].downcase}"
  puts "всего голосов: #{window_cheater[:total]}"
  puts "максимум голосов в окне #{WINDOW}с: #{window_cheater[:max_window]}"
  puts "число уникальных ip: #{window_cheater[:unique_ips]}"
end



end_time = Time.now
elapsed = end_time - start_time

puts
puts "время выполнения: #{'%.3f' % elapsed} секунд"



File.open(OUTPUT_FILE, "w") do |f|
  f.puts "итоговый рейтинг (топ 50):"
  ranking.first(50).each_with_index do |(name, cnt), i|
    f.puts "#{i + 1}. #{name.downcase} — #{cnt} голосов"
  end

  f.puts "\nобъединённые варианты имён:"
  variant_map.each do |canon_name, variants|
    next if variants.size <= 1
    f.puts "#{canon_name.downcase} => #{variants.map(&:downcase).join(', ')}"
  end

  f.puts "\nподозрительный №1 — накрутка с одного ip:"
  if ip_cheater
    f.puts "имя: #{ip_cheater[:name].downcase}"
    f.puts "всего голосов: #{ip_cheater[:total]}"
    f.puts "максимум голосов с одного ip: #{ip_cheater[:max_ip_count]} (ip: #{ip_cheater[:max_ip]})"
  end

  f.puts "\nподозрительный №2 — быстрые всплески голосов (окно #{WINDOW} секунд):"
  if window_cheater
    f.puts "имя: #{window_cheater[:name].downcase}"
    f.puts "всего голосов: #{window_cheater[:total]}"
    f.puts "максимум голосов в окне #{WINDOW}с: #{window_cheater[:max_window]}"
    f.puts "число уникальных ip: #{window_cheater[:unique_ips]}"
  end

  f.puts "\nвремя выполнения: #{'%.3f' % elapsed} секунд"
end

puts
puts "результат сохранён в #{OUTPUT_FILE}"
