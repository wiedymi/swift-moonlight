# Optional reference sources

These repositories are used only to study protocol behavior. They are not package dependencies. Swift Package Manager does not download them.

Existing protocol notes use paths under `refs/`. To inspect a reference, clone only the needed repository into that path, then check out the recorded revision. Do not use a recursive clone unless nested sources are needed. The local `refs/` folder is ignored by Git.

| Local path | Repository | Recorded revision |
| --- | --- | --- |
| `refs/moonlight-harmonyos` | [moonlight-harmonyos](https://github.com/likuai2010/moonlight-harmonyos) | `e64392de5f00ee771140aa3f6e7d2b96db21e67a` |
| `refs/moonlight-common-c` | [moonlight-common-c](https://github.com/moonlight-stream/moonlight-common-c) | `62687809b1f7410c3db4be2527503a54ae408d70` |
| `refs/moonlight-ios` | [moonlight-ios](https://github.com/moonlight-stream/moonlight-ios) | `85af0f75622bb2636481afda8b0fc5cc33d5956e` |
| `refs/moonlight-android` | [moonlight-android](https://github.com/moonlight-stream/moonlight-android) | `f10085f552b367cf7203007693d91c322a0a2936` |
| `refs/sunshine` | [Sunshine](https://github.com/LizardByte/Sunshine) | `4bd461cf8247285d0df00e19e2bc01129cf9c5af` |
| `refs/moonlight-docs` | [moonlight-docs](https://github.com/moonlight-stream/moonlight-docs) | `eee2f08df569b2309b4e0c79e0f987559fabe0a0` |
| `refs/apollo` | [Apollo](https://github.com/ClassicOldSong/Apollo) | `003393ee1800f9ef9008557f21e54aa9245daf41` |

Do not copy, paste, or mechanically port GPL reference code into this MIT implementation.
