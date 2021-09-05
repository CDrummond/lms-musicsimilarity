# Music Similarity

Music Similarity plugin for LMS. Currently provides a mixer for
`Don't Stop The Music` using either [Music Similarity](https://github.com/CDrummond/music-similarity),
[Essentia](https://github.com/CDrummond/essentia-api)
or [Musly](https://github.com/CDrummond/musly-server). These provide the same
HTTP API that this plugin invokes.

'Music Similarity' uses 'Musly' for similarity sorting and 'Essentia' for
filtering.

## LMS Menus

3 entries are added to LMS' 'More'/context menus:

1. `Similar tracks` returns (up to) 100 tracks that are similar to the selected track, returned in similarity order.
2. `Similar tracks by artist` returns (up to) 100 tracks by the selected track that are similar to the track, returned in similarity order.
3. `Create similarity mix` creates a mix of (up to) 50 tracks based upon the selected artist, album, or track, returned in a shuffled order.
