// Client of the local reference server. Plain JavaScript, no build step.
const token = window.POMVOX_TOKEN;
const $ = (id) => document.getElementById(id);
let status = null;

async function api(path, init = {}) {
  init.headers = Object.assign({ Authorization: `Bearer ${token}` }, init.headers || {});
  const response = await fetch(path, init);
  const text = await response.text();
  let body; try { body = JSON.parse(text); } catch { body = { error: text }; }
  if (!response.ok) throw new Error(`${response.status}: ${body.error || text}`);
  return body;
}

async function loadStatus() {
  try {
    status = await api('/v1/status');
    $('status').textContent = `cleanup: ${status.cleanupPack} ${status.cleanupPackVersion} · diarizer: ${status.diarizerPack} ${status.diarizerPackVersion} · speech recognition: ${status.speechRecognition}`;
  } catch (error) {
    $('status').innerHTML = `<span class="err">Server not reachable: ${error.message}</span>`;
  }
}

// ---- 1. cleanup through the wire protocol -------------------------------------------
$('clean').addEventListener('click', async () => {
  const raw = $('raw').value;
  const started = performance.now();
  $('clean').disabled = true; $('clean-meta').textContent = 'cleaning…';
  try {
    const requestID = crypto.randomUUID();
    const reply = await api('/v1/clean', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Idempotency-Key': requestID },
      body: JSON.stringify({ schemaVersion: 1, requestID, pack: { id: status.cleanupPack, version: status.cleanupPackVersion },
        text: raw, vocabulary: [], context: '', settings: {}, remainingMilliseconds: 30000 }),
    });
    const result = reply.result;
    const outcome = typeof result.status === 'string' ? result.status : Object.keys(result.status)[0] + (result.status.fallback ? ` (${result.status.fallback._0})` : '');
    $('cleaned').hidden = false;
    $('cleaned').textContent = result.text;
    $('clean-meta').textContent = `${outcome} · ${result.edits.length} edit${result.edits.length === 1 ? '' : 's'} · model ${Math.round(result.timings.inferenceMS ?? 0)} ms · round trip ${Math.round(performance.now() - started)} ms · ${result.provenance.runtime}`;
  } catch (error) {
    $('clean-meta').innerHTML = `<span class="err">${error.message}</span>`;
  } finally { $('clean').disabled = false; }
});

// ---- 2. speaker notes: capture 16 kHz mono PCM in the page -------------------------
let context, source, processor, stream, chunks = [], recordingStart = 0, timer;

function encodeWAV(samples, rate) {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  const write = (offset, text) => { for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i)); };
  write(0, 'RIFF'); view.setUint32(4, 36 + samples.length * 2, true); write(8, 'WAVE');
  write(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
  write(36, 'data'); view.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i++) { const s = Math.max(-1, Math.min(1, samples[i])); view.setInt16(44 + i * 2, s < 0 ? s * 32768 : s * 32767, true); }
  return new Blob([buffer], { type: 'audio/wav' });
}

async function resampleTo16k(samples, rate) {
  if (rate === 16000) return samples;
  const frames = Math.round(samples.length * 16000 / rate);
  const offline = new OfflineAudioContext(1, frames, 16000);
  const buffer = offline.createBuffer(1, samples.length, rate);
  buffer.copyToChannel(samples, 0);
  const node = offline.createBufferSource(); node.buffer = buffer; node.connect(offline.destination); node.start();
  return (await offline.startRendering()).getChannelData(0);
}

$('record').addEventListener('click', async () => {
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } });
  } catch (error) { $('rec-meta').innerHTML = `<span class="err">microphone: ${error.message}</span>`; return; }
  context = new AudioContext({ sampleRate: 16000 });
  source = context.createMediaStreamSource(stream);
  processor = context.createScriptProcessor(4096, 1, 1);
  chunks = [];
  processor.onaudioprocess = (event) => chunks.push(new Float32Array(event.inputBuffer.getChannelData(0)));
  source.connect(processor); processor.connect(context.destination);
  recordingStart = performance.now();
  $('record').disabled = true; $('record').classList.add('rec'); $('stop').disabled = false;
  timer = setInterval(() => { $('rec-meta').textContent = `recording ${((performance.now() - recordingStart) / 1000).toFixed(0)} s at ${context.sampleRate} Hz`; }, 250);
});

$('stop').addEventListener('click', async () => {
  clearInterval(timer);
  processor.disconnect(); source.disconnect(); stream.getTracks().forEach((t) => t.stop());
  const rate = context.sampleRate; await context.close();
  $('record').disabled = false; $('record').classList.remove('rec'); $('stop').disabled = true;
  const length = chunks.reduce((n, c) => n + c.length, 0);
  const samples = new Float32Array(length); let offset = 0;
  for (const chunk of chunks) { samples.set(chunk, offset); offset += chunk.length; }
  await process(encodeWAV(await resampleTo16k(samples, rate), 16000), length / rate);
});

$('file').addEventListener('change', async (event) => {
  const file = event.target.files[0]; if (!file) return;
  await process(file, null);
  event.target.value = '';
});

async function process(blob, seconds) {
  $('rec-meta').textContent = `processing ${seconds ? seconds.toFixed(1) + ' s' : blob.name || 'file'} (${(blob.size / 1024).toFixed(0)} KB)…`;
  $('notes').hidden = true; $('timeline').hidden = true; $('raw-json').hidden = true;
  const started = performance.now();
  try {
    const headers = { 'Content-Type': 'audio/wav' };
    const speakers = $('speakers').value.trim();
    if (speakers) headers['X-Pomvox-Speakers'] = speakers.includes('-') ? speakers : `${speakers}-${speakers}`;
    const reply = await api('/v1/speaker-notes', { method: 'POST', headers, body: blob });
    render(reply);
    const s = reply.stages;
    $('rec-meta').textContent = `${reply.words} words · ${reply.segmentation.speakerCount} speaker${reply.segmentation.speakerCount === 1 ? '' : 's'} · ${reply.transcript.turns.length} turns · STT ${Math.round(s.sttMS)} ms, diarization ${Math.round(s.diarizationMS)} ms, cleanup ${Math.round(s.cleanupMS)} ms (${reply.transcript.turns.filter(t => typeof t.result.status !== 'string' && t.result.status.fallback).length} fallback) · round trip ${Math.round(performance.now() - started)} ms`;
  } catch (error) {
    $('rec-meta').innerHTML = `<span class="err">${error.message}</span>`;
  }
}

function render(reply) {
  const segments = reply.segmentation.segments;
  const end = Math.max(...segments.map((s) => s.span.end), 0.001);
  const bar = $('timeline'); bar.innerHTML = ''; bar.hidden = false;
  let cursor = 0;
  for (const segment of segments) {
    if (segment.span.start > cursor) { const gap = document.createElement('span'); gap.style.width = `${(segment.span.start - cursor) / end * 100}%`; bar.appendChild(gap); }
    const piece = document.createElement('span');
    piece.className = segment.speaker.toLowerCase(); piece.title = `${segment.speaker} ${segment.span.start.toFixed(1)}–${segment.span.end.toFixed(1)} s`;
    piece.style.width = `${(segment.span.end - segment.span.start) / end * 100}%`;
    bar.appendChild(piece); cursor = segment.span.end;
  }
  $('notes').innerHTML = markdownToHTML(reply.markdown); $('notes').hidden = false;
  $('json').textContent = JSON.stringify(reply, null, 2); $('raw-json').hidden = false;
}

// Enough Markdown for the renderer's output: headings, bullets, bold, paragraphs. Text is escaped first.
function markdownToHTML(markdown) {
  const esc = (s) => s.replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  const inline = (s) => esc(s).replace(/\*\*(.+?)\*\*/g, (m, b) => `<span class="speaker ${b.toLowerCase().replace(/[^a-z0-9]/g, '')}">${b}</span>`);
  let html = '', list = false;
  for (const line of markdown.split('\n')) {
    if (line.startsWith('- ')) { if (!list) { html += '<ul>'; list = true; } html += `<li>${inline(line.slice(2))}</li>`; continue; }
    if (list) { html += '</ul>'; list = false; }
    if (line.startsWith('## ')) html += `<h2>${esc(line.slice(3))}</h2>`;
    else if (line.startsWith('# ')) html += `<h1>${esc(line.slice(2))}</h1>`;
    else if (line.trim()) html += `<p>${inline(line)}</p>`;
  }
  if (list) html += '</ul>';
  return html;
}

loadStatus();
