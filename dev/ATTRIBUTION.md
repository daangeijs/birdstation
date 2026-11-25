# Test recording

The fake birdmic loops one real recording of a Common Blackbird, a garden bird
BirdNET detects reliably and that sings all over the Netherlands.

| Field | Value |
|---|---|
| Species | Common Blackbird (*Turdus merula*), song (merel) |
| Recordist | Sander Pieterse |
| Recorded | 2007-05-20 11:00, Van Boetzelaerlaan, Den Haag, Zuid-Holland, NL |
| Notes (recordist) | Male singing in tree during sunny weather, recorded from a balcony along a street with passing cars in the background |
| Source | xeno-canto XC26605, https://xeno-canto.org/26605 |
| Mirror used first | Wikimedia Commons, https://commons.wikimedia.org/wiki/File:Turdus_merula_-_Common_Blackbird_XC26605.mp3 |
| Download URLs | https://upload.wikimedia.org/wikipedia/commons/5/59/Turdus_merula_-_Common_Blackbird_XC26605.mp3 (fallback: https://xeno-canto.org/26605/download, identical bytes) |
| Licence | CC BY-SA 4.0, https://creativecommons.org/licenses/by-sa/4.0/ (same on xeno-canto and Commons) |
| File | MP3, 44.1 kHz mono, 64 kbit/s, 91.9 s, 739654 bytes |
| SHA256 | `bd3a55851b12dd0b52b377e5541e5087d50986175e6e21487c7a3092cc32a80b` |
| SHA1 (matches Commons) | `2e672e7af928bdd6e2775f7d0596664b1cf01569` |

Attribution: "Common Blackbird (Turdus merula) song, XC26605 by Sander Pieterse,
xeno-canto, CC BY-SA 4.0."

## Why this file and how it is stored

- CC BY-SA 4.0 is the most permissive licence among the Dutch blackbird
  recordings checked. A CC BY 4.0 candidate on Commons (XC1059970) was rejected
  because xeno-canto lists that same recording as CC BY-NC-SA 4.0.
- The audio is not committed. `config/fetch-audio.sh` downloads it, checks the
  SHA256 above and converts it to `bird.wav` (48 kHz, mono, 16-bit, about
  8.8 MB, too big to keep in git). The checksum covers the downloaded MP3 only,
  because decoded PCM can differ slightly between ffmpeg versions.
- Changes made: decoded and resampled to 48 kHz WAV, then streamed as L16. The
  MP3 source is lossy; that is fine for a test signal and does not affect the
  contract (the stream itself carries no lossy codec).
