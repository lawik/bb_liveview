// SPDX-FileCopyrightText: 2026 Lars Wikman
//
// SPDX-License-Identifier: Apache-2.0

/**
 * LiveView hook for a video tile of `BB.LiveView.Components.Images`: plays a
 * `BB.LiveView.VideoSource` stream over WebRTC.
 *
 * The server owns the session. `data-session` on the tile names the attach
 * it is playing: a new value means a new peer connection, and no value means
 * none. Signaling for any other session is dropped. The server's sink makes
 * the offer; this side only answers.
 */

// The dashboard is for robots on the local network, where host candidates
// are all ICE needs.
const ICE_SERVERS = [];

export const VideoTile = {
  mounted() {
    this.video = this.el.querySelector("video");
    this.stateEl = this.el.querySelector("[data-role=video-state]");
    this.fpsEl = this.el.querySelector("[data-role=video-fps]");
    // Autoplay without a user gesture needs the property, not just the attribute.
    this.video.muted = true;
    this.session = null;
    this.pc = null;

    this.handleEvent("bb_video_signal", (message) => {
      if (message.tile === this.el.id) this.receive(message);
    });

    this.startFrameRate();
    this.sync();
  },

  updated() {
    this.sync();
  },

  destroyed() {
    this.stop();
    clearInterval(this.fpsTimer);
    if (this.frameCallback != null) this.video.cancelVideoFrameCallback(this.frameCallback);
  },

  sync() {
    const value = this.el.dataset.session;
    const session = value ? Number(value) : null;
    if (session === this.session) return;

    this.stop();
    if (session === null) {
      this.setState("waiting");
    } else {
      this.start(session);
    }
  },

  start(session) {
    const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
    this.pc = pc;
    this.session = session;
    this.answered = false;
    this.pendingCandidates = [];
    // Signaling is handled strictly in order: an ICE candidate can't be
    // added before the offer it belongs to has been applied.
    this.queue = Promise.resolve();

    pc.ontrack = (event) => {
      lowerLatency(event.receiver);
      this.video.srcObject = event.streams[0] || new MediaStream([event.track]);
      this.video.play().catch(() => {});
    };

    pc.onicecandidate = ({ candidate }) => {
      // null, or an empty candidate, only marks the end of gathering.
      if (!candidate || !candidate.candidate) return;
      // The sink only accepts candidates once it has the answer.
      if (this.answered) {
        this.send("ice_candidate", candidate.toJSON());
      } else {
        this.pendingCandidates.push(candidate.toJSON());
      }
    };

    pc.onconnectionstatechange = () => {
      if (pc === this.pc) this.setState(pc.connectionState);
    };

    this.setState("connecting");
  },

  stop() {
    if (this.pc) {
      this.pc.ontrack = null;
      this.pc.onicecandidate = null;
      this.pc.onconnectionstatechange = null;
      this.pc.close();
      this.pc = null;
    }
    this.session = null;

    const stream = this.video.srcObject;
    if (stream) {
      stream.getTracks().forEach((track) => track.stop());
      this.video.srcObject = null;
    }
    this.fpsEl.textContent = "";
  },

  receive(message) {
    if (message.session !== this.session) return;
    const pc = this.pc;

    this.queue = this.queue
      .then(() => this.apply(pc, message))
      .catch((error) => console.warn(`[bb_liveview] ${this.el.id}: ${message.type} failed`, error));
  },

  async apply(pc, { type, data }) {
    if (pc !== this.pc) return;

    switch (type) {
      case "sdp_offer": {
        await pc.setRemoteDescription(data);
        await pc.setLocalDescription(await pc.createAnswer());
        if (pc !== this.pc) return;

        this.send("sdp_answer", pc.localDescription.toJSON());
        this.answered = true;
        this.pendingCandidates.forEach((candidate) => this.send("ice_candidate", candidate));
        this.pendingCandidates = [];
        break;
      }

      case "ice_candidate":
        if (data && data.candidate) await pc.addIceCandidate(data);
        break;
    }
  },

  send(type, data) {
    this.pushEventTo(this.el, "video_signal", {
      tile: this.el.id,
      session: this.session,
      type,
      data,
    });
  },

  setState(state) {
    this.stateEl.textContent = state;
  },

  // Frames shown per second, from requestVideoFrameCallback where the
  // browser has it, else from the playback quality counters.
  startFrameRate() {
    let presented = null;
    let last = { frames: 0, time: performance.now() };

    if ("requestVideoFrameCallback" in HTMLVideoElement.prototype) {
      const onFrame = (_now, metadata) => {
        presented = metadata.presentedFrames;
        this.frameCallback = this.video.requestVideoFrameCallback(onFrame);
      };
      this.frameCallback = this.video.requestVideoFrameCallback(onFrame);
    }

    const count = () => {
      if (presented !== null) return presented;
      const quality = this.video.getVideoPlaybackQuality?.();
      return quality ? quality.totalVideoFrames : null;
    };

    this.fpsTimer = setInterval(() => {
      const frames = count();
      const time = performance.now();
      if (frames === null || !this.video.srcObject) {
        this.fpsEl.textContent = "";
      } else if (frames >= last.frames) {
        const fps = ((frames - last.frames) * 1000) / (time - last.time);
        this.fpsEl.textContent = `${fps.toFixed(1)} fps`;
      }
      // A new stream starts counting from zero again.
      last = { frames: frames ?? 0, time };
    }, 1000);
  },
};

// Play frames as soon as they are decodable rather than buffering for
// smoothness. jitterBufferTarget is the standard knob (in ms);
// playoutDelayHint is Chrome's older one (in seconds).
function lowerLatency(receiver) {
  if ("jitterBufferTarget" in receiver) receiver.jitterBufferTarget = 0;
  if ("playoutDelayHint" in receiver) receiver.playoutDelayHint = 0;
}
