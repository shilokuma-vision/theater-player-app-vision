# テスト用の音のファイル

`scripts/make-drc-test-files.sh` で作る（FFmpeg のエンコーダーに DRC の値を書かせるパッチを当てた、この Mac で動く ffmpeg を使う）。

| ファイル | 中身 |
| --- | --- |
| `dynrng-12db.ac3` | AC-3・5.1・48 kHz・448 kbps・0.64 秒（20 フレーム）。LFE 以外は振幅 0.1（-20 dBFS）の 1 kHz、LFE は 50 Hz。どのフレームも最初のブロックに DRC の値 0xC0（-12.04 dB）が入っている |
| `dynrng-12db.eac3` | 同じ音の E-AC-3 |

`drc_scale=0` でデコードすると実効値は -23.0 dBFS、`drc_scale=1` だと -35.1 dBFS（-12.04 dB）になる。
