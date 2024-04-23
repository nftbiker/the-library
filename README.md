A ruby script to download all entries from "The Library" channel and keep a copy in json and markdown format.

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
