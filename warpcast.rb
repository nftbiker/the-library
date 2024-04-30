require 'bundler/inline'
gemfile do
  source 'https://rubygems.org'
  gem 'activesupport'
  gem 'rest-client'
  gem 'pp'
end

require "active_support/all"
require 'json'

JSON_PATH = "./_json"
MD_PATH = "./_posts"
AUTH_PATH = "./_authors"
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
    FileUtils.mkdir_p(AUTH_PATH) unless File.exist?(AUTH_PATH)
  end

  def call(options = {})
    upto = (options[:days] || 2).days.ago.beginning_of_day.to_i
    puts "Process casts older from #{options[:from] ? Time.at(options[:from]/1000).to_s : 'now'}"
    list = retrieve(options[:from])
    list.each do |item|
      next if item['pinned']
      cast = item['cast']

      images = get_images_from(cast)
      if images.blank?
        # is it a recast?
        recasts = (cast['embeds'] || {})['casts'] || []
        unless recasts.blank?
          other = recasts.detect {|e| !e['embeds']['images'].blank?}
          cast = other if other
        end
        images = get_images_from(cast)
      end
      # no image, no love
      next if images.blank?

      # what we memoize
      res = {
        id: cast['hash'],
        timestamp: cast['timestamp'],
        author: {
          username: cast['author']['username'],
          displayname: cast['author']['displayName'],
          fid: cast['author']['fid'],
          avatar: cast['author']['pfp']['url'],
          description: cast['author']['profile']['bio']['text'],
        }.stringify_keys,
        text: cast['text'],
        images: images
      }

      res.stringify_keys!
      save_json(res, options[:force])
      save_markdown(res, options[:force])
      casts[res['id']] = res
    end

    if list.size>=15
      from = list.last['timestamp']
      return call(options.merge(from: from)) if from/1000>upto
    end
    store_authors
  end

  def reprocess
    # reprocess all json entries to save new markdown version
    Dir.glob("#{JSON_PATH}/*.json").each do |f|
      puts f
      res = JSON.parse(File.read(f))
      save_markdown(res, true)
    end
    store_authors
  end

  private

  def store_authors
    list = {}
    Dir.glob("#{JSON_PATH}/*.json").each do |f|
      res = JSON.parse(File.read(f))
      author = res["author"]
      list[author['username']] = author
    end

    list.values.each do |author|
      path = File.join(AUTH_PATH, "#{author['username']}.md")
      front = []
      front << "---"
      front << "username: #{author['username']}"
      front << "displayname: #{author['displayname']}"
      front << "fid: #{author['fid']}"
      front << "profile: https://warpcast.com/#{author['username']}"
      front << "avatar: #{author['avatar']}" if author['avatar']
      front << "---"
      front << ""

      File.open(path, "wb") do |f|
        f.write(front.join("\n"))
        f.write("#{author['description'].to_s.strip.gsub("\n", "  \n")}  \n")
      end
    end
    true
  end

  def get_images_from(cast)
    ((cast['embeds'] || {})['images'] || []).collect { |e|
      next if e['type'] != 'image'
      (e['media'] || {})['staticRaster'] || e['url'] || e['sourceUrl']
    }.compact
  end

  def save_json(entry, force = false)
    path = File.join(JSON_PATH, "#{entry['id']}.json")
    return path if !force && File.exist?(path)
    File.open(path, "wb") {|f|f.write(JSON.pretty_generate(entry))}
    path
  end

  def save_markdown(entry, force = false)
    d = Time.at(entry['timestamp'].to_i/1000).getutc.strftime('%Y-%m-%d-%H%M')
    id = entry['id'][0,10]
    path = File.join(MD_PATH, "#{d}-#{id}.md")
    return path if !force && File.exist?(path)
    author = entry['author']
    img = entry['images'][0]

    front = []
    front << "---"
    front << "author: #{author['displayname']}"
    front << "date: #{Time.at(entry['timestamp']/1000).strftime(TIME_FMT)}"
    front << "username: #{author['username']}"
    front << "fid: #{author['fid']}"
    front << "cast_id: #{entry['id']}"
    front << "cast: https://warpcast.com/#{author['username']}/#{id}"
    front << "image: #{img}"
    front << "layout: post"
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

if $0 == __FILE__
  Warpcast.new.call
end