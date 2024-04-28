# About

A ruby script to download all entries from "The Library" channel and keep a copy in json and markdown format.
The script is automatically run through a github actions to update the repository with new posts, twice a day.

# Preview

An HTML site built with the data generated from this script is visible at:
https://artlibrary.netlify.app/

# How to run

in irb, to download all archives

```
require './warpcast.rb'
data = Warpcast.new.call(days:100)
```

to download last 2 days

```
require './warpcast.rb'
data = data=Warpcast.new.call
```

# Jekyll website

Theme is based on :
https://github.com/wowthemesnet/jekyll-theme-memoirs
