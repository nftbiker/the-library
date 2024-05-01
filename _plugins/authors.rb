module Author
  class Generator < Jekyll::Generator
    # add posts count to each caster
    def generate(site)
      authors = site.collections["authors"]
      posts = site.posts
      authors.each do |a|
        a.data["posts_count"] = posts.docs.select { |e| e.data["fid"] && e.data["fid"] == a.data["fid"] }.length
      end
    end
  end
end
