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

# change this to backup another channel
CHANNEL_ID = ENV["CHANNEL_ID"] || "the-library"

# no need to change anything below
JSON_PATH = "./_json"
MD_PATH = "./_posts"
AUTH_PATH = "./_authors"
TIME_FMT = "%Y-%m-%dT%H:%M:%S%z"
CHANNEL_URL = "https://warpcast.com/~/channel/#{CHANNEL_ID}"
PINATA_URL = "https://hub.pinata.cloud/v1"
PINATA_ORIGIN_TS = 1609455600 # 2021-01-01 00:00:00 +0100

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
    puts "Process casts older from #{options[:from] ? Time.at(options[:from] / 1000).to_s : "now"}"
    list = retrieve(options[:from])
    list.each do |item|
      next if item["pinned"]
      cast = item["cast"]

      images = get_images_from(cast)
      if images.blank?
        # is it a recast?
        recasts = (cast["embeds"] || {})["casts"] || []
        unless recasts.blank?
          other = recasts.detect { |e| !e["embeds"].blank? && !e["embeds"]["images"].blank? }
          if other
            other["recast_by"] = get_profile_from(cast["author"])
            other["recast_hash"] = cast["hash"]
            cast = other
          end
        end
        images = get_images_from(cast)
      end
      # no image, no love
      next if images.blank?

      # what we memoize
      res = {
        id: cast["hash"],
        timestamp: cast["timestamp"],
        author: get_profile_from(cast["author"]),
        text: cast["text"],
        images: images,
      }
      if cast["recast_by"]
        res[:recast_by] = cast["recast_by"]
        res[:recast_hash] = cast["recast_hash"]
      end
      res.stringify_keys!
      save_json(res, options[:force])
      save_markdown(res, options[:force])
      casts[res["id"]] = res
    end

    if list.size >= 15
      from = list.last["timestamp"]
      if from != options[:from] && from / 1000 > upto
        return call(options.merge(from: from))
      end
    end
    store_authors
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

  # retrieve everything (or only recent casts) from Hub API
  # https://docs.farcaster.xyz/reference/hubble/httpapi/casts
  # data are not in the same format as warpcast API but are enough for our need
  # on pinata, the timestamp is weird (not true epoch)
  def archives(recent = false)
    url = File.join(PINATA_URL, "/castsByParent").to_s
    url += "?url=#{CHANNEL_URL}"
    url += "&reverse=1&pageSize=#{recent.class == Integer ? recent : 100}" if recent
    api = RestClient.get(url, { content_type: :json, accept: :json })
    body = JSON.parse(api.body)

    authors = {}
    results = []

    body["messages"].each do |data|
      cast = data["data"]
      authors[cast["fid"]] = true

      next if cast["type"] != "MESSAGE_TYPE_CAST_ADD"
      next if json_exist?(data["hash"])

      msg = cast["castAddBody"]
      embeds = msg["embeds"].map { |e| e["url"] }.compact
      images = embeds.select { |e| e.match(/imagedelivery\.net|imgur\.com|postimg\.cc|supercast\.mypinata|\.(png|jpe?g|gif)/im) }
      if images.blank? && !embeds.blank?
        puts "Ignore #{data["hash"]} - Empty image : #{embeds}"
        next
      end
      next if images.blank?

      # what we memoize
      res = {
        id: data["hash"],
        timestamp: (cast["timestamp"] + PINATA_ORIGIN_TS) * 1000,
        author: {
          fid: cast["fid"],
        }.stringify_keys,
        text: msg["text"],
        images: images,
      }
      res.stringify_keys!
      results.push(res)
    end

    fix_authors(authors.keys, results)
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

  def get_profile_from(author)
    {
      username: author["username"].to_s.strip,
      displayname: author["displayName"].to_s.strip,
      fid: author["fid"],
      avatar: author["pfp"]["url"],
      description: author["profile"]["bio"]["text"],
    }.stringify_keys
  end

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
    url = File.join(PINATA_URL, "/userDataByFid").to_s
    url += "?fid=#{fid}"
    api = RestClient.get(url, { content_type: :json, accept: :json })

    data = JSON.parse(api.body)["messages"].collect do |e|
      (e["data"] || {})["userDataBody"]
    end.inject({}) do |hsh, e|
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
      front << "profile: https://warpcast.com/#{author["username"]}"
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

  def get_images_from(cast)
    ((cast["embeds"] || {})["images"] || []).collect { |e|
      next if e["type"] != "image"
      (e["media"] || {})["staticRaster"] || e["url"] || e["sourceUrl"]
    }.compact
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
    front << "cast: https://warpcast.com/#{author["username"]}/#{id}"
    front << "image: #{img}"
    unless entry["recast_hash"].blank?
      author = entry["recast_by"]
      front << "recast_author: #{author["displayname"]}"
      front << "recast_username: #{author["username"]}"
      front << "recast_hash: https://warpcast.com/#{author["username"]}/#{entry["recast_hash"].to_s[0, 10]}"
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

  def retrieve(from = nil)
    from ||= Time.now.to_i * 1000
    api = RestClient.post("https://client.warpcast.com/v2/feed-items", {
      feedKey: CHANNEL_ID,
      feedType: "default",
      viewedCastHashes: "",
      updateState: true,
      latestMainCastTimestamp: from,
      olderThan: from,
    }.to_json, { content_type: :json, accept: :json })

    data = JSON.parse(api.body)
    (data["result"] || {})["items"] || []
  end
end

if $0 == __FILE__
  Warpcast.new.call
end
