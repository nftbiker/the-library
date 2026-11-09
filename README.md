# About

A ruby script to download all entries from ["The Library" warpcast channel](https://farcaster.xyz/~/channel/the-library) and keep a copy in json and markdown format. The script is automatically run through a github actions to update the repository with new posts, twice a day.

# How to run

from the command line

```
ruby warpcast.rb             # last 7 days
ruby warpcast.rb --days 30   # last 30 days
ruby warpcast.rb --days all  # whole channel
ruby warpcast.rb -d 30 -f    # last 30 days, rewrite existing files
```

or in irb, to download all archives

```
require './warpcast.rb'
data = Warpcast.new.call(days: :all)
```

Casts are read from a public Snapchain node (Farcaster Hub HTTP API, no API key needed).
Override it with `HUB_URL` in `.env` if that node goes down.

to download last 7 days

```
require './warpcast.rb'
data = data=Warpcast.new.call
```

# Jekyll website

Theme based on :
https://github.com/wowthemesnet/jekyll-theme-memoirs
