// Test helper: taps the received audio with WebAudio and reports, per channel,
// the dominant frequency and RMS level. Start with --eval, read with --final:
//   --eval "odysseusAudioProbe.start()"  --final "odysseusAudioProbe.read()"
window.odysseusAudioProbe = {
  start() {
    const video = document.getElementById("stream");
    const stream = video && video.srcObject;
    if (!stream || stream.getAudioTracks().length === 0) return "no audio track";
    const ctx = new AudioContext({ sampleRate: 48000 });
    const source = ctx.createMediaStreamSource(new MediaStream(stream.getAudioTracks()));
    const splitter = ctx.createChannelSplitter(2);
    source.connect(splitter);
    this.ctx = ctx;
    this.analysers = [0, 1].map((ch) => {
      const a = ctx.createAnalyser();
      a.fftSize = 8192;
      a.smoothingTimeConstant = 0;
      splitter.connect(a, ch);
      return a;
    });
    return ctx.resume().then(() => "started " + ctx.state);
  },
  read() {
    if (!this.analysers) return "not started";
    return this.analysers.map((a) => {
      const spectrum = new Float32Array(a.frequencyBinCount);
      a.getFloatFrequencyData(spectrum);
      let peak = 0;
      for (let i = 1; i < spectrum.length; i++) if (spectrum[i] > spectrum[peak]) peak = i;
      const hz = (bin) => Math.round((bin * this.ctx.sampleRate) / a.fftSize);
      const level = (f) => Math.round(spectrum[Math.round((f * a.fftSize) / this.ctx.sampleRate)]);
      const time = new Float32Array(a.fftSize);
      a.getFloatTimeDomainData(time);
      const rms = Math.sqrt(time.reduce((s, v) => s + v * v, 0) / time.length);
      return {
        peakHz: hz(peak),
        db1k: level(1000),
        db3k: level(3000),
        peakDb: Math.round(spectrum[peak]),
        rmsDb: rms > 0 ? Math.round(20 * Math.log10(rms)) : -Infinity,
      };
    });
  },
};
