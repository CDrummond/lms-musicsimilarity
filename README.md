# Music Similarity

Music Similarity plugin for LMS. Provides a mixer for `Don't Stop The Music`.

This plugin will send requests to the [Music Similarity](https://github.com/CDrummond/music-similarity)
service to get random tracks similar to seed tracks chosen from the current
play queue.

The [Music Similarity](https://github.com/CDrummond/music-similarity) backend
uses [Musly](https://github.com/CDrummond/musly) to locate similar tracks based
upon a seed track's 'timbre'. The similar tracks are then further filtered by
checking audio characteristics (BPM, danceability, aggressiveness, etc.) against
those of the seed track.

## LMS Menus

3 entries are added to LMS' 'More'/context menus:

1. `Similar tracks` returns (up to) 100 tracks that are similar to the selected track, returned in similarity order.
2. `Similar tracks by artist` returns (up to) 100 byt the same artist that are similar to the selected track, returned in similarity order.
3. `Create similarity mix` creates a mix of (up to) 50 tracks based upon the selected artist, album, or track, returned in a shuffled order.
