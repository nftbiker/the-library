#!/usr/bin/env ruby
# encoding: utf-8

require "bundler/inline"
gemfile do
  source "https://rubygems.org"
  gem "activesupport"
  gem "rest-client"
  gem "pp"
  gem "dotenv"
end

require "active_support/all"
require "json"
require "dotenv"

Dotenv.load

# change this to backup another channel
CHANNEL_ID = ENV["CHANNEL_ID"] || "the-library"

# no need to change anything below
JSON_PATH = "./_json"
MD_PATH = "./_posts"
AUTH_PATH = "./_authors"
TIME_FMT = "%Y-%m-%dT%H:%M:%S%z"
# parent url used by casts of the channel (kept its historical warpcast.com form)
CHANNEL_URL = ENV["CHANNEL_URL"] || "https://warpcast.com/~/channel/#{CHANNEL_ID}"
# public Snapchain node (Hub HTTP API), no key needed
HUB_URL = ENV["HUB_URL"] || "https://crackle.farcaster.xyz:3381/v1"
HUB_PAGE_SIZE = 100
FARCASTER_EPOCH = 1609459200 # 2021-01-01 00:00:00 UTC
IMAGE_REGEX = /imagedelivery\.net|imgur\.com|postimg\.cc|supercast\.mypinata|\.(png|jpe?g|gif|webp)/im

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

  # fetch channel casts from the hub, newest first
  # options:
  #   days:  how many days back to process (default 7), :all for the whole channel
  #   force: rewrite json/markdown files that already exist
  def call(options = {})
    days = options[:days] || 7
    upto = days == :all ? 0 : days.days.ago.beginning_of_day.to_i
    puts "Process casts since #{upto.zero? ? "the beginning" : Time.at(upto)}"

    results = []
    each_channel_cast do |data|
      cast = data["data"]
      timestamp = cast["timestamp"] + FARCASTER_EPOCH
      break if timestamp < upto

      res = parse_cast(data, timestamp, options[:force])
      results << res if res
    end

    puts "#{results.size} new cast(s) with images"
    fix_authors(results.map { |r| r["author"]["fid"] }.uniq, results)
    casts.merge!(results.index_by { |r| r["id"] })
  end

  def reprocess
    # reprocess all json entries to save new markdown version
    Dir.glob("#{JSON_PATH}/*.json").each do |f|
      puts f.split("/").last.split(".").first
      res = JSON.parse(File.read(f))
      save_markdown(res, true)
    end
    store_authors
  end

  # iterate over every cast of the channel through the Hub HTTP API
  # https://snapchain.farcaster.xyz/reference/httpapi/casts
  def each_channel_cast
    page_token = nil
    loop do
      params = { url: CHANNEL_URL, pageSize: HUB_PAGE_SIZE, reverse: true }
      params[:pageToken] = page_token if page_token
      body = hub_get("castsByParent", params)
      (body["messages"] || []).each { |data| yield data }
      page_token = body["nextPageToken"]
      break if page_token.blank?
    end
  end

  # convert a hub message into what we memoize, nil if it must be ignored
  def parse_cast(data, timestamp, force = false)
    cast = data["data"]
    return if cast["type"] != "MESSAGE_TYPE_CAST_ADD"
    return if !force && json_exist?(data["hash"])

    msg = cast["castAddBody"]
    embeds = (msg["embeds"] || []).map { |e| e["url"] }.compact
    images = embeds.select { |e| e.match(IMAGE_REGEX) }
    # no image, no love
    if images.blank?
      puts "Ignore #{data["hash"]} - no image : #{embeds}" unless embeds.blank?
      return
    end

    {
      "id" => data["hash"],
      "timestamp" => timestamp * 1000,
      "author" => { "fid" => cast["fid"] },
      "text" => msg["text"].to_s,
      "images" => images,
    }
  end

  def fix_authors(missing_ids = [], results = [])
    if missing_ids.blank? || results.blank?
      Dir.glob("#{JSON_PATH}/*.json").each do |f|
        res = JSON.parse(File.read(f))
        if res["author"] && res["author"]["avatar"].blank?
          results << res
          missing_ids << res["author"]["fid"]
        end
      end
    end
    return if missing_ids.blank?

    authors = authors_infos(missing_ids)
    results.each do |item|
      a = authors[item["author"]["fid"]]
      if a.blank?
        puts "ERROR: missing author for #{item["author"]["fid"]}"
      else
        item["author"] = a
        puts "Save cast #{item["id"]}"
        save_json(item, true)
        save_markdown(item, true)
      end
    end
    store_authors
  end

  private

  def authors_infos(author_ids)
    list = get_authors
    author_ids.each do |fid|
      fid = fid.to_i
      next if list[fid] && !list[fid]["avatar"].blank?
      list[fid] ||= {}
      list[fid].merge!(get_author(fid))
    end
    list
  end

  def get_author(fid)
    data = (hub_get("userDataByFid", fid: fid)["messages"] || []).collect do |e|
      (e["data"] || {})["userDataBody"]
    end.compact.inject({}) do |hsh, e|
      k = e["type"].to_s.gsub(/USER_DATA_TYPE_/im, "").downcase
      hsh[k] = e["value"] unless k.blank?
      hsh
    end

    res = {
      username: data["username"].to_s.strip,
      displayname: data["display"].to_s.strip,
      fid: fid.to_i,
      avatar: data["pfp"],
      description: data["bio"],
    }
    res.stringify_keys!
    res.delete_if { |_, v| v.blank? }
    res
  end

  def get_authors
    list = {}
    Dir.glob("#{JSON_PATH}/*.json").each do |f|
      res = JSON.parse(File.read(f))
      author = res["author"]
      author.delete_if { |_, v| v.blank? }
      list[author["fid"].to_i] ||= {}
      list[author["fid"].to_i].merge!(author)
    end
    list
  end

  def store_authors
    get_authors.values.each do |author|
      path = File.join(AUTH_PATH, "#{author["username"]}.md")
      front = []
      front << "---"
      front << "username: #{author["username"]}"
      front << "displayname: #{author["displayname"]}"
      front << "fid: #{author["fid"]}"
      front << "profile: https://farcaster.xyz/#{author["username"]}"
      front << "avatar: #{author["avatar"]}" if author["avatar"]
      front << "---"
      front << ""

      File.open(path, "wb") do |f|
        f.write(front.join("\n"))
        f.write("#{author["description"].to_s.strip.gsub("\n", "  \n")}  \n")
      end
    end
    true
  end

  def json_exist?(hash)
    path = File.join(JSON_PATH, "#{hash}.json")
    File.exist?(path)
  end

  def save_json(entry, force = false)
    path = File.join(JSON_PATH, "#{entry["id"]}.json")
    return path if !force && File.exist?(path)
    File.open(path, "wb") { |f| f.write(JSON.pretty_generate(entry)) }
    path
  end

  def save_markdown(entry, force = false)
    d = Time.at(entry["timestamp"].to_i / 1000).getutc.strftime("%Y-%m-%d-%H%M")
    id = entry["id"][0, 10]
    path = File.join(MD_PATH, "#{d}-#{id}.md")
    return path if !force && File.exist?(path)
    author = entry["author"]
    img = proper_image(entry["images"][0])

    front = []
    front << "---"
    front << "author: #{author["displayname"]}"
    front << "date: #{Time.at(entry["timestamp"] / 1000).strftime(TIME_FMT)}"
    front << "username: #{author["username"]}"
    front << "fid: #{author["fid"]}"
    front << "cast_id: #{entry["id"]}"
    front << "cast: https://farcaster.xyz/#{author["username"]}/#{id}"
    front << "image: #{img}"
    unless entry["recast_hash"].blank?
      author = entry["recast_by"]
      front << "recast_author: #{author["displayname"]}"
      front << "recast_username: #{author["username"]}"
      front << "recast_hash: https://farcaster.xyz/#{author["username"]}/#{entry["recast_hash"].to_s[0, 10]}"
    end
    front << "layout: post"
    front << "---"
    front << ""

    File.open(path, "wb") { |f|
      f.write(front.join("\n"))
      f.write("#{entry["text"].gsub("\n", "  \n")}  \n")
      entry["images"].each do |i|
        f.write("\n<img src='#{proper_image(i)}' alt='' referrerpolicy='no-referrer'/>")
      end
    }
    path
  end

  def proper_image(url)
    return url unless url.match(/imgur\.com/im)
    url.gsub(/\.jpg/im, ".jpeg")
  end

  def hub_get(endpoint, params = {})
    url = "#{HUB_URL}/#{endpoint}?#{URI.encode_www_form(params)}"
    attempts = 0
    begin
      api = RestClient.get(url, { accept: :json })
      JSON.parse(api.body)
    rescue RestClient::Exception, Errno::ECONNRESET, Net::OpenTimeout, Net::ReadTimeout => e
      attempts += 1
      raise if attempts >= 3
      puts "Retry #{url} (#{e.message})"
      sleep(2 * attempts)
      retry
    end
  end
end

if $0 == __FILE__
  require "optparse"

  options = {}
  OptionParser.new do |opts|
    opts.banner = "Usage: ruby warpcast.rb [options]"
    opts.on("-d", "--days DAYS", "Number of days to fetch (default 2), or 'all' for the whole channel") do |v|
      if v == "all"
        options[:days] = :all
      elsif v.match?(/\A\d+\z/) && v.to_i > 0
        options[:days] = v.to_i
      else
        abort "Invalid --days value: #{v} (expected a positive integer or 'all')"
      end
    end
    opts.on("-f", "--force", "Rewrite json/markdown files that already exist") do
      options[:force] = true
    end
  end.parse!

  Warpcast.new.call(options)
end
