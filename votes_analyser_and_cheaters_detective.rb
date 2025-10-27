require 'time'
require 'amatch'
include Amatch

FILE_PATH = 'votes_42.txt'

LEV_MAX = 2
WINDOW_SECONDS = 3600
TOP_SHOW = 5

program_start = Time.now

puts "запуск обработки..."

votes = [] # { raw_name:, time:, ip: }
File.foreach(FILE_PATH) do |line|
  # простой парсер
  if m = line.match(/time:\s*([0-9]{4}-[0-9]{2}-[0-9]{2}\s+[0-9]{2}:[0-9]{2}:[0-9]{2})/)
    t = Time.parse(m[1]) rescue nil
  else
    t = nil
  end
  ip = nil
  if m = line.match(/ip:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/)
    ip = m[1]
  elsif m = line.match(/ip:\s*([^,\s]+)/)
    ip = m[1]
  end
  candidate = ''
  if m = line.match(/candidate:\s*(.+?)\s*$/)
    candidate = m[1].strip
  elsif m = line.match(/candidate:\s*([^,]+)/)
    candidate = m[1].strip
  end
  votes << { raw_name: candidate, time: t, ip: ip }
end
puts "прочитано голосов: #{votes.size}"

# частотный подсчёт написаний
name_counts = Hash.new(0)
votes.each { |v| name_counts[v[:raw_name]] += 1 }
unique_names = name_counts.keys
puts "уникальных написаний: #{unique_names.size}"

# чтобы не создавать объект при каждой проверке, используем кэш
lev_cache = {} # строка -> amatch::levenshtein объект

def amatch_distance(a, b, lev_cache)
  sa = a.to_s.downcase
  sb = b.to_s.downcase
  return LEV_MAX + 1 if (sa.length - sb.length).abs > LEV_MAX
  lev = lev_cache[sa]
  unless lev
    lev = Amatch::Levenshtein.new(sa)
    lev_cache[sa] = lev
  end
  lev.match(sb).to_i
end

class BKNode
  attr_accessor :word, :children
  def initialize(word)
    @word = word  # слово в узле
    @children = {} # хэш { distance_integer => child_node }
  end
end

class BKTree
  def initialize(&dist_fn)
    @root = nil
    @dist_fn = dist_fn
  end

  # вставка нового слова
  # спускаемся от корня по ребрам, помеченным расстоянием
  # если на найденной дистанции нет ребёнка криейтим узел
  def insert(term)
    if @root.nil?
      @root = BKNode.new(term)
      return
    end
    node = @root
    loop do
      d = @dist_fn.call(term, node.word)
      if d == 0
        # уже есть такое слово
        return
      elsif node.children[d]
        node = node.children[d]
      else
        node.children[d] = BKNode.new(term)
        return
      end
    end
  end

  # ретёрнит массив [term, distance] для всех терминов в радиусе max_dist
  def query(term, max_dist)
    return [] if @root.nil?
    results = []
    stack = [@root]
    while node = stack.pop
      d = @dist_fn.call(term, node.word)
      results << [node.word, d] if d <= max_dist
      low = d - max_dist
      high = d + max_dist
      node.children.each do |child_dist, child_node|
        # если дочернее ребро может привести к искомому диапазону спускаемся ниже
        if child_dist >= low && child_dist <= high
          stack << child_node
        end
      end
    end
    results
  end
end

# канонические имена
# сортируем уникальные написания по убыванию частоты
# частые записи будут якорями

bkt = BKTree.new do |x,y|
  amatch_distance(x, y, lev_cache)
end

canonical_for = {}   # raw_name => canonical_name
canonical_count = {} # canonical_name => суммарная частота

unique_names.sort_by { |n| -name_counts[n] }.each do |name|
  found = bkt.query(name, LEV_MAX)
  if found.empty?
    canonical_for[name] = name
    canonical_count[name] = name_counts[name]
    bkt.insert(name)
  else
    # сначала минимальное расстояние, при одинаковости более частый канон
    best = found.min_by { |term, d| [d, - (canonical_count[term] || 0)] }
    rep_name = best[0]
    canonical_for[name] = rep_name
    canonical_count[rep_name] = (canonical_count[rep_name] || 0) + name_counts[name]
  end
end
unique_names.each { |n| canonical_for[n] ||= n }

# агрегация по канонам и поиск мошенников
canon_votes = Hash.new { |h,k| h[k] = [] }
votes.each do |v|
  can = canonical_for[v[:raw_name]]
  canon_votes[can] << { time: v[:time], ip: v[:ip], raw: v[:raw_name] }
end

results = canon_votes.map do |can, arr|
  total = arr.size
  ip_counts = Hash.new(0)
  arr.each { |e| ip_counts[e[:ip]] += 1 }
  max_ip, max_ip_count = ip_counts.max_by { |k,v| v } || [nil,0]

  times = arr.map { |e| e[:time] ? e[:time].to_i : 0 }.sort
  best_window_votes = 0
  best_window_unique_ips = 0
  left = 0
  right = 0
  n = times.length
  while left < n
    t0w = times[left]
    while right < n && times[right] <= t0w + WINDOW_SECONDS
      right += 1
    end
    window_votes = right - left
    if window_votes > best_window_votes
      t_start = t0w
      t_end = t0w + WINDOW_SECONDS
      uniq_ips = canon_votes[can].select { |e| e[:time] && e[:time].to_i >= t_start && e[:time].to_i <= t_end }.map { |e| e[:ip] }.uniq.size
      best_window_votes = window_votes
      best_window_unique_ips = uniq_ips
    end
    left += 1
  end

  {
    canonical: can,
    total: total,
    max_ip: max_ip,
    max_ip_count: max_ip_count,
    best_window_votes: best_window_votes,
    best_window_unique_ips: best_window_unique_ips
  }
end

sorted = results.sort_by { |r| -r[:total] }

puts
puts "топ #{TOP_SHOW} участников:"
sorted.first(TOP_SHOW).each_with_index do |r, i|
  puts "#{i+1}. #{r[:canonical].downcase} — #{r[:total]} голосов (макс с одного ip: #{r[:max_ip_count]}, всплеск #{r[:best_window_votes]} голосов за #{WINDOW_SECONDS}с, #{r[:best_window_unique_ips]} уник. ip в этом окне)"
end

cheat1 = sorted.max_by { |r| r[:max_ip_count] }
cheat2 = sorted.max_by { |r| r[:best_window_votes] }

puts
puts "подозреваемый 1 (много голосов с одного ip):"
if cheat1
  puts "#{cheat1[:canonical].downcase} — #{cheat1[:total]} всего, #{cheat1[:max_ip_count]} голосов с одного ip (ip: #{cheat1[:max_ip]})"
else
  puts "не найдено"
end

puts
puts "подозреваемый 2 (много голосов с разных ip в короткий промежуток):"
if cheat2
  puts "#{cheat2[:canonical].downcase} — #{cheat2[:total]} всего, голосов во временном окне #{WINDOW_SECONDS}с: #{cheat2[:best_window_votes]} голосов, #{cheat2[:best_window_unique_ips]} уник. ip"
else
  puts "не найдено"
end

program_end = Time.now
puts
puts "время выполнения программы: #{(program_end - program_start).round(3)} сек"

puts "зе енд"
