"""Loopback-only contract fixture. No premium inference or content logging."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import time
import wave

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_POST(self):
        if self.headers.get('Content-Type') == 'audio/wav':
            return self.diarize()
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        if (self.headers.get('Authorization') != 'Bearer test-only-token'
                or self.headers.get('Idempotency-Key') != body['requestID']
                or body['schemaVersion'] != 1 or not 0 < body['remainingMilliseconds'] <= 60000
                or body['vocabulary'] != ['Pomvox'] or body['context'] != 'explicit test context'
                or body['settings'] != {'style': 'test'}):
            self.send_error(400)
            return
        if self.path == '/http500':
            self.send_error(500)
            return
        if self.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', 'https://example.org/never-follow')
            self.end_headers()
            return
        if self.path == '/slow':
            time.sleep(0.4)
        text = body['text']
        edits = []
        status = {'unchanged': {}}
        if self.path in ['/edit', '/invalid']:
            offset = len(text.encode('utf-8'))
            edits = [{'start': offset if self.path == '/edit' else 1, 'end': offset, 'replacement': '!'}]
            text += '!'
            status = {'cleaned': {}}
        provenance = {'packID': body['pack']['id'], 'packVersion': body['pack']['version'],
                      'artifactDigest': 'mock-digest', 'modelRevision': 'mock-revision',
                      'runtime': 'loopback-mock', 'route': 'cloud', 'settings': body['settings']}
        if self.path == '/wrongpack':
            provenance['packID'] = 'different-pack'
        timings = {'preparationMS': 0, 'queueMS': 1, 'prefillMS': 2, 'inferenceMS': 3,
                   'validationMS': 1, 'diffMS': 0, 'totalMS': 7, 'budgetMS': body['remainingMilliseconds']}
        response = {'schemaVersion': 1, 'requestID': body['requestID'],
                    'result': {'text': text, 'edits': edits, 'status': status, 'provenance': provenance,
                               'timings': timings, 'warnings': ['mock-only']}}
        result = response['result']
        if self.path == '/wrongid': response['requestID'] = '00000000-0000-0000-0000-000000000000'
        if self.path == '/wrongschema': response['schemaVersion'] = 2
        if self.path == '/wrongversion': provenance['packVersion'] = '2.0.0'
        if self.path == '/wrongroute': provenance['route'] = 'local'
        if self.path == '/emptydigest': provenance['artifactDigest'] = ''
        if self.path == '/emptyruntime': provenance['runtime'] = ''
        if self.path == '/negative': timings['inferenceMS'] = -1
        if self.path == '/unknownstatus': result['status'] = {'invented': {}}
        if self.path == '/cleanedwithoutedit': result['status'] = {'cleaned': {}}
        if self.path == '/unchangedwithchange': result['text'] += '!'
        if self.path == '/fallback': result['status'] = {'fallback': {'_0': 'rejected'}}
        if self.path == '/fallbackwithchange':
            result['status'] = {'fallback': {'_0': 'rejected'}}
            result['text'] += '!'
        if self.path == '/overlap':
            result['edits'] = [{'start': 0, 'end': 4, 'replacement': ''},
                               {'start': 0, 'end': 4, 'replacement': ''}]
        if self.path == '/manyedits': result['edits'] = [{'start': 0, 'end': 0, 'replacement': ''}] * 1025
        if self.path == '/hugeresult': result['text'] = 'x' * 65537
        if self.path == '/missingfield': del result['provenance']
        payload = json.dumps(response).encode()
        if self.path == '/truncated': payload = payload[:-1]
        if self.path == '/invalidutf8': payload = b'\xff'
        if self.path == '/overflow': payload = payload.replace(b'"inferenceMS": 3', b'"inferenceMS": 1e999')
        if self.path == '/oversized':
            payload = b' ' * 131073
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain' if self.path == '/wrongmime' else 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try:
            if self.path == '/slowbody':
                self.wfile.write(payload[:1])
                self.wfile.flush()
                time.sleep(0.4)
                self.wfile.write(payload[1:])
            else:
                self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def diarize(self):
        """Diarization protocol v1 fixture: a two-speaker split of the uploaded WAV's duration."""
        raw = self.rfile.read(int(self.headers['Content-Length']))
        try:
            with wave.open(io.BytesIO(raw)) as audio:
                params = audio.getparams()
                seconds = params.nframes / 16000
            shape_ok = (params.nchannels, params.sampwidth, params.framerate) == (1, 2, 16000)
        except (wave.Error, EOFError):
            shape_ok = False
            seconds = 0
        remaining = int(self.headers.get('X-Pomvox-Remaining-Milliseconds', '0'))
        if (not shape_ok or self.headers.get('Authorization') != 'Bearer test-only-token'
                or len(self.headers.get('Idempotency-Key', '')) != 36
                or self.headers.get('X-Pomvox-Schema') != '1'
                or self.headers.get('X-Pomvox-Pack') != 'diar-test'
                or self.headers.get('X-Pomvox-Pack-Version') != '1.0.0'
                or abs(float(self.headers.get('X-Pomvox-Audio-Seconds', '-1')) - seconds) > 0.01
                or not 0 < remaining <= 3600000
                or (self.headers.get('X-Pomvox-Speakers') not in (None, '2-2', '1-4'))):
            self.send_error(400)
            return
        path = self.path.removeprefix('/d/')
        if path == 'http500':
            self.send_error(500)
            return
        if path == 'redirect':
            self.send_response(302)
            self.send_header('Location', 'https://example.org/never-follow')
            self.end_headers()
            return
        if path == 'slow':
            time.sleep(0.4)
        half = round(seconds / 2, 3)
        segments = [{'speaker': 'B', 'span': {'start': 0.0, 'end': half}, 'confidence': 0.9},
                    {'speaker': 'A', 'span': {'start': half, 'end': round(seconds, 3)}}]
        provenance = {'packID': 'diar-test', 'packVersion': '1.0.0', 'artifactDigest': 'mock-digest',
                      'modelRevision': 'mock-revision', 'runtime': 'loopback-mock', 'route': 'cloud', 'settings': {}}
        timings = {'audioSeconds': seconds, 'totalMS': 7, 'budgetMS': remaining}
        result = {'segments': segments, 'speakerCount': 2, 'provenance': provenance, 'timings': timings, 'warnings': ['mock-only']}
        response = {'schemaVersion': 1, 'requestID': self.headers['Idempotency-Key'], 'result': result}
        if path == 'unsorted': result['segments'] = segments[::-1]
        if path == 'wrongid': response['requestID'] = '00000000-0000-0000-0000-000000000000'
        if path == 'wrongschema': response['schemaVersion'] = 2
        if path == 'wrongpack': provenance['packID'] = 'other'
        if path == 'wrongversion': provenance['packVersion'] = '2.0.0'
        if path == 'wrongroute': provenance['route'] = 'local'
        if path == 'emptyruntime': provenance['runtime'] = ''
        if path == 'overrun': segments[1]['span']['end'] = seconds + 5
        if path == 'reversed': segments[0]['span'] = {'start': half, 'end': 0.0}
        if path == 'negativestart': segments[0]['span']['start'] = -1
        if path == 'badconfidence': segments[0]['confidence'] = 1.5
        if path == 'miscount': result['speakerCount'] = 3
        if path == 'toomany': result['segments'] = [segments[0]] * 4097
        if path == 'negative': timings['totalMS'] = -1
        if path == 'nospeech':
            result['segments'] = []
            result['speakerCount'] = 0
        if path == 'missingfield': del result['provenance']
        payload = json.dumps(response).encode()
        if path == 'truncated': payload = payload[:-1]
        if path == 'oversized': payload = b' ' * (1048576 + 1)
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain' if path == 'wrongmime' else 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
