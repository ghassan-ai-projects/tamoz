// Downsamples the microphone to 16 kHz mono and posts 20 ms frames (320 samples).
class Capture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = sampleRate / 16000;
    this.frame = new Float32Array(320);
    this.filled = 0;
    this.position = 0;
    this.sum = 0;
    this.count = 0;
  }

  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (!channel) return true;
    for (let i = 0; i < channel.length; i += 1) {
      this.sum += channel[i];
      this.count += 1;
      this.position += 1;
      if (this.position >= this.ratio) {
        this.position -= this.ratio;
        this.frame[this.filled] = this.sum / this.count;
        this.filled += 1;
        this.sum = 0;
        this.count = 0;
        if (this.filled === this.frame.length) {
          this.port.postMessage(this.frame.slice(0));
          this.filled = 0;
        }
      }
    }
    return true;
  }
}

registerProcessor('capture', Capture);
