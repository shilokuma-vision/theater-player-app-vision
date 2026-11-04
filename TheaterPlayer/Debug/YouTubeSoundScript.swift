//
//  YouTubeSoundScript.swift
//  TheaterPlayer
//
//  デバッグ用：YouTube のページに差し込むスクリプト（「映画館の音響に通す」。デバッグのビルドだけ。リリースには入れない）。
//  YouTube の利用規約は、音や映像を切り離したり手を加えたりすることを禁じている。これは確認用で、利用者の判断で作った。配らない。
//
//  YouTube は Media Source Extensions（MSE）で再生する。ページが音声の SourceBuffer に入れる断片（WebM・MP4）を写してアプリへ送り、
//  アプリがデコードして映画館の音響から鳴らす（YouTubeSound）。<video> の時計（currentTime）も送り、アプリはそれに合わせて鳴らす。
//  Web Audio（createMediaElementSource）で <video> の音を受ける方法は、WebKit が MSE の <video> の音を Web Audio に渡さず
//  無音になるので使えない（visionOS 26.5 の Simulator で確かめた。同じ AudioContext の OscillatorNode の音は届く）。
//
//  - MSE の入口（addSourceBuffer・appendBuffer・remove・abort と、URL.createObjectURL）を、YouTube のスクリプトより先に包む。
//    そのため、ページの世界（.page）で、読み込みの始めに動かす
//  - 音声の断片は、スイッチを切っているあいだもページの中にだけ写しておく（入れたとき、もう MSE に入った先の分も送れるように）。
//    アプリへ送るのは、入れているあいだだけ
//  - 入れているあいだは（速さが 1 倍のとき）、<video> の本当の muted を true にして、ページの元の音を消す。ページ（YouTube）からは、
//    元の muted が見えるようにする（<video> に muted の読み書きを被せる）。音量とミュートは、アプリへ送って音量に掛ける。
//    切ると、被せた物を外して元に戻す
//

#if DEBUG
import WebKit

enum YouTubeSoundScript {
    /// スクリプトを動かす content world（MSE をページのスクリプトと同じ物として包むため、ページの世界）
    static let world = WKContentWorld.page
    /// スクリプトからアプリへ送る受け口の名前（webkit.messageHandlers.theaterSound）
    static let handlerName = "theaterSound"

    /// スイッチを入れる・切る（callJavaScript に渡す関数の中身。引数は enabled）
    static let setEnabled = "return window.__theaterSound ? window.__theaterSound.setEnabled(enabled) : null;"

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world)
    }

    /// 送る物（type）：
    /// - ready：差し込んだ（読み込むたびに。アプリはスイッチの状態を渡し直す）
    /// - source：鳴らす音声の入れ物が替わった（id・mime。次の動画・広告）。続けて、写しておいた断片を送る
    /// - append：断片（id・init（初期化の断片か）・offset（timestampOffset）・data（base64））
    /// - remove：ページが MSE から消した範囲（id・start・end。秒）
    /// - abort：ページが断片の読み込みをやめた（id）
    /// - clock：<video> の時計（time・at（1970 年からのミリ秒）・rate・playing・volume（ミュートなら 0））
    /// - state：様子（enabled・buffers・active・muted）
    static let source = #"""
    (() => {
      "use strict";
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\#(handlerName);
      if (!handler || window.__theaterSound || !window.MediaSource || !window.SourceBuffer) {
        return;
      }
      // 写しておく断片の量（1 つの入れ物あたり。Opus の 160 kbps で約 5 分）
      const CACHE_BYTES = 6 * 1024 * 1024;
      const post = (message) => handler.postMessage(message);
      const now = () => performance.timeOrigin + performance.now();
      const original = {
        addSourceBuffer: MediaSource.prototype.addSourceBuffer,
        appendBuffer: SourceBuffer.prototype.appendBuffer,
        remove: SourceBuffer.prototype.remove,
        abort: SourceBuffer.prototype.abort,
        createObjectURL: URL.createObjectURL,
        muted: Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "muted")
      };
      // 音声の SourceBuffer → { id, type, source（MediaSource）, init, segments, bytes }
      const records = new Map();
      // blob の URL → MediaSource（<video> がどの MediaSource を再生しているかを見る）
      const sourcesByURL = new Map();
      let nextID = 1;
      let enabled = false;
      // アプリへ送っている入れ物
      let sent = null;
      // 本当の muted を true にしている <video> と、ページから見える muted
      let shadow = null;
      let timer = 0;

      function isInitialization(bytes) {
        // WebM：EBML のヘッダー（1A 45 DF A3）。MP4：ftyp・moov の箱
        if (bytes.length >= 4 && bytes[0] === 0x1a && bytes[1] === 0x45 && bytes[2] === 0xdf && bytes[3] === 0xa3) {
          return true;
        }
        if (bytes.length >= 8) {
          const type = String.fromCharCode(bytes[4], bytes[5], bytes[6], bytes[7]);
          return type === "ftyp" || type === "moov";
        }
        return false;
      }

      function copy(data) {
        if (data instanceof ArrayBuffer) {
          return new Uint8Array(data.slice(0));
        }
        if (ArrayBuffer.isView(data)) {
          return new Uint8Array(data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength));
        }
        return null;
      }

      function base64(bytes) {
        if (bytes.toBase64) {
          return bytes.toBase64();
        }
        let text = "";
        for (let i = 0; i < bytes.length; i += 8192) {
          text += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
        }
        return btoa(text);
      }

      function send(record, chunk) {
        post({ type: "append", id: record.id, init: chunk === record.init, offset: chunk.offset, data: base64(chunk.bytes) });
      }

      function keep(record, data, offset) {
        const bytes = copy(data);
        if (!bytes || bytes.length === 0) {
          return;
        }
        const chunk = { bytes, offset };
        if (isInitialization(bytes)) {
          record.init = chunk;
          record.segments = [];
          record.bytes = 0;
        } else {
          record.segments.push(chunk);
          record.bytes += bytes.length;
          while (record.bytes > CACHE_BYTES && record.segments.length > 1) {
            record.bytes -= record.segments.shift().bytes.length;
          }
        }
        if (enabled && record === sent) {
          send(record, chunk);
        } else if (enabled) {
          sync();
        }
      }

      function wrapAddSourceBuffer(prototype) {
        const add = prototype.addSourceBuffer;
        prototype.addSourceBuffer = function (type) {
          const buffer = add.call(this, type);
          if (/^audio\//i.test(String(type))) {
            records.set(buffer, { id: nextID++, type: String(type), source: this, init: null, segments: [], bytes: 0 });
            // 古い入れ物（前の動画・広告）は持たない
            while (records.size > 6) {
              records.delete(records.keys().next().value);
            }
            if (enabled) {
              sync();
            }
          }
          return buffer;
        };
      }
      wrapAddSourceBuffer(MediaSource.prototype);
      if (window.ManagedMediaSource && Object.prototype.hasOwnProperty.call(ManagedMediaSource.prototype, "addSourceBuffer")) {
        wrapAddSourceBuffer(ManagedMediaSource.prototype);
      }

      SourceBuffer.prototype.appendBuffer = function (data) {
        const offset = this.timestampOffset;
        const result = original.appendBuffer.call(this, data);
        const record = records.get(this);
        if (record) {
          keep(record, data, offset);
        }
        return result;
      };

      SourceBuffer.prototype.remove = function (start, end) {
        const result = original.remove.call(this, start, end);
        const record = records.get(this);
        if (record && enabled && record === sent) {
          post({ type: "remove", id: record.id, start, end });
        }
        return result;
      };

      SourceBuffer.prototype.abort = function () {
        const result = original.abort.call(this);
        const record = records.get(this);
        if (record && enabled && record === sent) {
          post({ type: "abort", id: record.id });
        }
        return result;
      };

      URL.createObjectURL = function (object) {
        const url = original.createObjectURL.call(URL, object);
        if (object instanceof MediaSource) {
          sourcesByURL.set(url, object);
        }
        return url;
      };

      function mainVideo() {
        return document.querySelector("video.html5-main-video") || document.querySelector("video");
      }

      // <video> が再生している MediaSource の、音声の入れ物
      function activeRecord(video) {
        if (!video) {
          return null;
        }
        const source = video.srcObject instanceof MediaSource ? video.srcObject : sourcesByURL.get(video.currentSrc || video.src);
        let found = null;
        records.forEach((record) => {
          if (record.source === source) {
            found = record;
          }
        });
        return found;
      }

      function mute(video) {
        if (shadow && shadow.video === video) {
          return;
        }
        unmute();
        shadow = { video, muted: original.muted.get.call(video) };
        Object.defineProperty(video, "muted", {
          configurable: true,
          get() {
            return shadow && shadow.video === video ? shadow.muted : original.muted.get.call(video);
          },
          set(value) {
            if (shadow && shadow.video === video) {
              shadow.muted = !!value;
              video.dispatchEvent(new Event("volumechange"));
            } else {
              original.muted.set.call(video, value);
            }
          }
        });
        original.muted.set.call(video, true);
      }

      function unmute() {
        if (!shadow) {
          return;
        }
        const { video, muted } = shadow;
        shadow = null;
        delete video.muted;
        original.muted.set.call(video, muted);
      }

      function reportClock(video) {
        if (!video) {
          return;
        }
        const muted = shadow && shadow.video === video ? shadow.muted : original.muted.get.call(video);
        post({
          type: "clock",
          id: sent ? sent.id : 0,
          time: video.currentTime,
          at: now(),
          rate: video.playbackRate,
          playing: !video.paused && !video.ended && !video.seeking && video.readyState >= 3,
          volume: muted ? 0 : video.volume
        });
      }

      function report() {
        post({ type: "state", enabled, buffers: records.size, active: sent ? sent.type : "", muted: !!shadow });
      }

      // 再生している入れ物を送る（替わったら、写しておいた断片から）。音声の入れ物が見つかったときだけ、元の音を消す
      function sync() {
        if (!enabled) {
          return;
        }
        const video = mainVideo();
        const record = activeRecord(video);
        if (record !== sent) {
          sent = record;
          if (record) {
            post({ type: "source", id: record.id, mime: record.type });
            if (record.init) {
              send(record, record.init);
            }
            record.segments.forEach((chunk) => send(record, chunk));
          }
          report();
        }
        // 速さが 1 倍でないあいだは、アプリは鳴らさないので、ページの音のままにする
        if (record && record.init && video.playbackRate === 1) {
          mute(video);
        } else {
          unmute();
        }
        reportClock(video);
      }

      function setEnabled(value) {
        enabled = !!value;
        clearInterval(timer);
        sent = null;
        if (enabled) {
          timer = setInterval(sync, 250);
          sync();
        } else {
          unmute();
        }
        report();
        return enabled;
      }

      for (const type of ["play", "playing", "pause", "seeking", "seeked", "ratechange", "waiting", "volumechange", "ended", "emptied"]) {
        document.addEventListener(type, () => sync(), true);
      }
      window.__theaterSound = { setEnabled };
      post({ type: "ready" });
    })();
    """#
}
#endif
