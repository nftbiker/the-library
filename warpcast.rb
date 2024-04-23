require 'bundler/inline'
gemfile do
  source 'https://rubygems.org'
  gem 'activesupport'
  gem 'rest-client'
  gem 'pp'
end

require "active_support/all"
require 'json'

STORAGE = "./storage"
JSON_PATH = File.join(STORAGE, "/json")
MD_PATH = File.join(STORAGE, "/markdown")
TIME_FMT = "%Y-%m-%dT%H:%M:%S%z"

class Warpcast
  attr_accessor :casts

  def initialize
    self.casts = {}
    create_paths
  end

  def create_paths
    FileUtils.mkdir_p(JSON_PATH) unless File.exist?(JSON_PATH)
    FileUtils.mkdir_p(MD_PATH) unless File.exist?(MD_PATH)
  end

  def call(options = {})
    upto = (options[:days] || 2).days.ago.beginning_of_day.to_i
    puts "Process casts older from #{options[:from] ? Time.at(options[:from]/1000).to_s : 'now'}"
    list = retrieve(options[:from])
    list.each do |item|
      next if item['pinned']
      cast = item['cast']

      # is it a recast?
      recasts = (cast['embeds'] || {})['casts'] || []
      unless recasts.blank?
        other = recasts.detect {|e| !e['embeds']['images'].blank?}
        cast = other if other
      end

      # no image, no love
      images = (cast['embeds'] || {})['images'] || []
      next if images.blank? && casts.blank?

      # what we memoize
      res = {
        id: cast['hash'],
        timestamp: cast['timestamp'],
        author: {
          username: cast['author']['username'],
          displayname: cast['author']['displayName'],
          fid: cast['author']['fid'],
        }.stringify_keys,
        text: cast['text'],
        images: []
      }
      images.each do |e|
        next if e['type'] != 'image'
        val = (e['media'] || {})['staticRaster'] || e['url'] || e['sourceUrl']
        res[:images] << val
      end
      res.stringify_keys!
      save_json(res)
      save_markdown(res)
      casts[res['id']] = res
    end
    if list.size>=15
      from = list.last['timestamp']
      return call(options.merge(from: from)) if from/1000>upto
    end
    casts
  end

  private

  def save_json(entry)
    path = File.join(JSON_PATH, "#{entry['id']}.json")
    return path if File.exist?(path)
    File.open(path, "wb") {|f|f.write(JSON.pretty_generate(entry))}
    path
  end

  def save_markdown(entry)
    k = "#{entry['timestamp'].to_i/1000}_#{entry['id'][0,8]}"
    path = File.join(MD_PATH, "#{k}.md")
    return path if File.exist?(path)
    author = entry['author']
    front = []
    front << "---"
    front << "date: #{Time.at(entry['timestamp']/1000).strftime(TIME_FMT)}"
    front << "author: #{author['displayname']}"
    front << "username: #{author['username']}"
    front << "fid: #{author['fid']}"
    front << "cast_id: #{entry['id']}"
    front << "cast: https://warpcast.com/#{author['username']}/#{entry['id'].to_s[0,10]}"
    front << "---"
    front << ""

    File.open(path, "wb") {|f|
      f.write(front.join("\n"))
      f.write("#{entry['text'].gsub("\n", "  \n")}  \n")
      entry['images'].each do |i|
        f.write("\n![](#{i})")
      end
    }
    path
  end

  def retrieve(from = nil)
    from ||= Time.now.to_i * 1000
    api = RestClient.post("https://client.warpcast.com/v2/feed-items", {
      feedKey: "the-library",
      feedType: "default",
      viewedCastHashes: "",
      updateState: true,
      latestMainCastTimestamp: from,
      olderThan:from,
    }.to_json, {content_type: :json, accept: :json})
        data = JSON.parse(api.body)
    (data["result"]||{})["items"]|| []
  end
end

Warpcast.new.call