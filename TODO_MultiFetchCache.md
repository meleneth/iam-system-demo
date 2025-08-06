    MultiFetchCache.fetch_many(
      keys: [key1, key2, key3],
      ttl: 300,
      tag: "org_cachekeys:abc123", # optional
      cache: ACCOUNT_CACHE         # default redis instance
    ) do |missing_keys|

      # Block receives only the keys that missed
      # Should return a hash: { key1 => value1, key3 => value3 }
    end

is missing_keys the right api?  Want the cache part handled for us.

Tag should probably be a proc, since it will need to be paramaterized by key.
How do we mention a key that our keys should be sinserted into with a TTL refresh?

Internally it:
*Uses pipelined to issue all GETs at once
*Decodes existing JSON values
*Passes only missing keys to the block
*Stores any new values with .set(key, json, ex: ttl)
*Optionally .sadd(tag, key) for each new key
*Returns { key => value } map including both hits and fills


